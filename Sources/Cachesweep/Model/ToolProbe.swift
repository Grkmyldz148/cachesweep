import Foundation

/// Ask each installed tool where *it* keeps its cache.
///
/// A hardcoded path is a guess about somebody else's machine. It is wrong for
/// a custom `CARGO_HOME`, an `npm config set cache`, a pnpm store moved to an
/// external disk, an XDG override, a Homebrew prefix that isn't
/// `/opt/homebrew` — and when it is wrong the app silently finds nothing and
/// looks broken. Every one of these tools can answer the question itself, so
/// ask instead of guessing, and only ask about tools that are actually here.
///
/// Answers are cached: they change when the user reconfigures a tool, which is
/// approximately never, and a scan should not pay for eight process launches.
enum ToolProbe {

    struct Probe: Sendable {
        let id: String
        let name: String
        let symbol: String
        let executable: String        // looked up on PATH; absent tools are skipped
        let arguments: [String]
        /// Some tools answer with several paths at once (`go env A B`).
        var strategy: CleanStrategy = .directory
        var safety: Safety = .safe
    }

    /// Each of these prints one absolute path per line and nothing else.
    static let probes: [Probe] = [
        // `npm config get cache` returns the whole cache root: _cacache,
        // _logs and _npx all live under it and are all disposable.
        Probe(id: "npm", name: "npm Cache", symbol: "shippingbox",
              executable: "npm", arguments: ["config", "get", "cache"],
              strategy: .contents),
        Probe(id: "yarn", name: "Yarn Cache", symbol: "shippingbox",
              executable: "yarn", arguments: ["cache", "dir"]),
        Probe(id: "pnpm", name: "pnpm Store", symbol: "shippingbox",
              executable: "pnpm", arguments: ["store", "path"]),
        Probe(id: "bun", name: "Bun Cache", symbol: "shippingbox",
              executable: "bun", arguments: ["pm", "cache"]),
        Probe(id: "go", name: "Go Cache", symbol: "shippingbox",
              executable: "go", arguments: ["env", "GOMODCACHE", "GOCACHE"]),
        Probe(id: "uv", name: "uv Cache", symbol: "shippingbox",
              executable: "uv", arguments: ["cache", "dir"]),
        Probe(id: "pip", name: "pip Cache", symbol: "shippingbox",
              executable: "pip3", arguments: ["cache", "dir"]),
        Probe(id: "composer", name: "Composer Cache", symbol: "shippingbox",
              executable: "composer", arguments: ["config", "--global", "cache-dir"]),
    ]

    // MARK: Entry point

    /// Cache targets for the tools installed on this machine.
    static func detect() async -> [CleanTarget] {
        if let cached = cachedAnswers() { return targets(from: cached) }
        let answers = await withTaskGroup(of: (String, [String]).self) { group in
            for probe in probes {
                group.addTask { (probe.id, ask(probe)) }
            }
            var out: [String: [String]] = [:]
            for await (id, paths) in group where !paths.isEmpty { out[id] = paths }
            return out
        }
        store(answers)
        return targets(from: answers)
    }

    // MARK: Asking

    /// Run the probe and keep the lines that are existing absolute paths.
    /// Anything else (a tool that printed a warning, an error, "undefined")
    /// is discarded — this feeds a delete button, so a wrong answer is worse
    /// than no answer.
    static func ask(_ probe: Probe) -> [String] {
        guard let tool = locate(probe.executable) else { return [] }
        // Where we ask from changes the answer, and no single directory suits
        // every tool: Yarn Berry refuses to run outside a project, Bun refuses
        // to run without a package.json, and asking from inside a project can
        // return that project's cache instead of the global one. So ask from
        // an empty scratch directory first — the honest "no project" context —
        // and only fall back to the home folder for the tools that insist on
        // having one.
        for cwd in [neutralDirectory(), NSHomeDirectory()].compactMap({ $0 }) {
            if let output = run(tool, probe.arguments, in: cwd) {
                let paths = parse(output)
                if !paths.isEmpty { return paths }
            }
        }
        return []
    }

    /// Keep only lines that are absolute paths to directories that exist.
    /// Anything else — a warning, an error, "undefined" — is discarded: this
    /// feeds a delete button, where a wrong answer is worse than no answer.
    static func parse(_ output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/") }
            .filter(isDirectory)
    }

    /// An empty directory with no project files in it.
    private static func neutralDirectory() -> String? {
        let path = NSTemporaryDirectory() + "cachesweep-probe"
        try? FileManager.default.createDirectory(atPath: path,
                                                 withIntermediateDirectories: true)
        return isDirectory(path) ? path : nil
    }

    /// Find an executable the way a shell would, plus the prefixes a GUI app
    /// never inherits — a menu-bar app is launched by launchd with a minimal
    /// PATH, so `npm` is invisible to it unless we look.
    static func locate(_ executable: String) -> String? {
        let fm = FileManager.default
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                     NSHomeDirectory() + "/.bun/bin",
                     NSHomeDirectory() + "/.cargo/bin",
                     NSHomeDirectory() + "/.local/bin",
                     NSHomeDirectory() + "/.volta/bin"]
        for dir in path.split(separator: ":").map(String.init) + extra {
            let candidate = dir + "/" + executable
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: Targets

    private static func targets(from answers: [String: [String]]) -> [CleanTarget] {
        probes.compactMap { probe in
            guard let paths = answers[probe.id], !paths.isEmpty else { return nil }
            return CleanTarget(
                id: "tool:" + probe.id,
                name: probe.name,
                detail: paths.map(tildeAbbreviate).joined(separator: " + "),
                symbol: probe.symbol,
                rawPaths: paths,
                safety: probe.safety,
                strategy: probe.strategy
            )
        }
    }

    // MARK: Answer cache

    private static let defaultsKey = "toolProbeAnswers"
    private static let defaultsStamp = "toolProbeAnsweredAt"
    private static let ttl: TimeInterval = 24 * 3600

    private static func cachedAnswers() -> [String: [String]]? {
        let d = UserDefaults.standard
        guard let at = d.object(forKey: defaultsStamp) as? Date,
              Date().timeIntervalSince(at) < ttl,
              let raw = d.dictionary(forKey: defaultsKey) as? [String: [String]]
        else { return nil }
        // A tool can be uninstalled between scans; never offer a path that
        // stopped existing.
        let live = raw.mapValues { $0.filter(isDirectory) }.filter { !$0.value.isEmpty }
        return live
    }

    private static func store(_ answers: [String: [String]]) {
        UserDefaults.standard.set(answers, forKey: defaultsKey)
        UserDefaults.standard.set(Date(), forKey: defaultsStamp)
    }

    /// Forget the answers so the next scan re-asks (used by the refresh button).
    static func invalidate() {
        UserDefaults.standard.removeObject(forKey: defaultsStamp)
    }

    // MARK: Process plumbing

    /// How long a tool gets to answer a question about its own configuration.
    /// Generous for a `config get`, short enough that a wedged tool cannot
    /// hold the scan open.
    static let probeTimeout: TimeInterval = 10

    /// These are other people's programs, and some of them would rather ask a
    /// question than answer one: `pnpm` here is a corepack shim that ships
    /// with `COREPACK_ENABLE_DOWNLOAD_PROMPT` on, so it can print a prompt and
    /// block on stdin waiting for a yes. Inheriting stdin and waiting forever
    /// meant one such tool wedged the whole scan — `refreshSeeds()` is awaited
    /// before anything else, and `isScanning` would never clear again.
    ///
    /// So: no stdin to read from, a hostile-to-interactivity environment, and
    /// a hard deadline after which the process is killed. Terminating also
    /// closes the pipe, which frees the read below if output ever filled it.
    private static func run(_ tool: String, _ arguments: [String], in cwd: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)

        var env = ProcessInfo.processInfo.environment
        env["COREPACK_ENABLE_DOWNLOAD_PROMPT"] = "0"
        env["CI"] = "1"                    // the conventional "do not prompt me"
        env["NO_COLOR"] = "1"
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }

        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + probeTimeout,
                                                       execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()

        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }

    private static func tildeAbbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
