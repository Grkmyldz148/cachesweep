import Foundation

/// Everything that has to be true before a project's build artifact may be
/// offered for deletion.
///
/// A cache and a project artifact both "regenerate", and treating that as the
/// same property is what made this app list the `node_modules` of projects
/// their owner works in every day. `~/.npm/_cacache` comes back by itself and
/// nobody notices. A project's `node_modules` comes back only when its owner
/// runs a command, waits for the network, and gets the same resolution back
/// out of a registry — minutes of work, sometimes a broken tree, occasionally
/// a package that no longer publishes the version the lockfile asks for.
/// Regenerable, yes; free, no. So these never count as `.safe` and are never
/// preselected, and three questions decide whether they are offered at all:
///
///   1. **Does a manifest actually own this artifact?** `vendor/` is checked-in
///      source in most Go repos and generated output in a PHP one; the name
///      cannot tell them apart, and a sibling `composer.json` can.
///   2. **Is the project cold?** Measured on the *project*, never on the
///      artifact. `node_modules` is stamped with the date of the last install,
///      so a repo touched hourly reads as eight months idle — the old
///      staleness signal was pointing at the one file in the tree guaranteed
///      not to move while someone works.
///   3. **Does the repo itself call it disposable?** `git check-ignore` is the
///      authoritative answer, and it is the project author's own answer.
///
/// A missing lockfile doesn't hide the artifact but does mark it
/// unreproducible, because "run the install again" stops being a promise.
final class ProjectGuard {

    /// What the scanner needs to build a row once a candidate has passed.
    struct Artifact: Sendable {
        let path: String
        let project: String
        /// The outermost project this one belongs to — itself, unless it is a
        /// package inside a workspace. Everything sharing a root belongs on
        /// one row: a monorepo's packages are one decision, not thirty.
        let root: String
        /// Days since the *project* was last touched — the honest staleness.
        let idleDays: Int
        /// The command that brings this back ("pnpm install").
        let restore: String
        /// A lockfile pins this tree, so reinstalling reproduces it.
        let reproducible: Bool
    }

    // MARK: Knowledge

    /// artifact kind → the manifests that prove it is generated output.
    /// The inverse of `Discovery.manifestMap`: the scanner walks from the
    /// manifest outwards, the guard has to walk back.
    static let ownerManifests: [String: [String]] = {
        var map: [String: [String]] = [:]
        for (manifest, kinds) in Discovery.manifestMap {
            for kind in kinds {
                map[(kind as NSString).lastPathComponent.lowercased(), default: []].append(manifest)
            }
        }
        return map
    }()

    /// Kinds that hold *downloaded dependencies* rather than compiled output.
    /// Only these care about a lockfile: `.next` rebuilds from the source in
    /// the repo, `node_modules` rebuilds from whatever the registry serves
    /// today.
    static let dependencyKinds: Set<String> = [
        "node_modules", ".venv", "venv", "pods", "vendor", "bundle", "deps",
    ]

    /// manifest → the lockfiles that pin its dependency tree.
    static let lockfiles: [String: [String]] = [
        "package.json":     ["package-lock.json", "yarn.lock", "pnpm-lock.yaml",
                             "bun.lockb", "bun.lock", "npm-shrinkwrap.json"],
        "Package.swift":    ["Package.resolved"],
        "Gemfile":          ["Gemfile.lock"],
        "requirements.txt": ["requirements.txt"],
        "mix.exs":          ["mix.lock"],
        "Cargo.toml":       ["Cargo.lock"],
        "Podfile":          ["Podfile.lock"],
        "pubspec.yaml":     ["pubspec.lock"],
        "build.gradle":     ["gradle.lockfile"],
        "build.gradle.kts": ["gradle.lockfile"],
        "pyproject.toml":   ["uv.lock", "poetry.lock", "pdm.lock", "requirements.txt"],
        "composer.json":    ["composer.lock"],
    ]

    // MARK: State

    private let fm = FileManager()
    private let idleThresholdDays: Int
    private var idleCache: [String: Int] = [:]
    private var enclosingCache: [String: [String]] = [:]
    private var ignoreCache: [String: IgnoreInfo] = [:]
    /// Rejections, for the debug log — silence about a skipped folder is
    /// indistinguishable from a bug.
    private(set) var skippedActive = 0
    private(set) var skippedTracked = 0
    private(set) var skippedUnowned = 0

    private struct IgnoreInfo {
        var isRepo: Bool
        var asked: Set<String> = []
        var ignored: Set<String> = []
    }

    init(idleThresholdDays: Int) {
        self.idleThresholdDays = idleThresholdDays
    }

    // MARK: Entry point

    /// Decide whether `artifact` (a directory inside `project`) may be offered.
    /// `siblings` are the other artifact kinds of the same project, so the one
    /// `git check-ignore` call can answer for all of them at once.
    func evaluate(artifact: String, project: String, siblings: [String] = []) -> Artifact? {
        // A manifest names every artifact its ecosystem *could* produce, and a
        // given project has two or three of them. Settling existence first
        // keeps the rest of this — including a process launch — off the seven
        // folders that were never there.
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: artifact, isDirectory: &isDir), isDir.boolValue else { return nil }
        let kind = (artifact as NSString).lastPathComponent.lowercased()

        // 1) Manifest proof. Without it the name is a guess, and the guess is
        //    wrong exactly where it is expensive (`vendor`, `build`, `dist`).
        guard let manifests = Self.ownerManifests[kind] else { skippedUnowned += 1; return nil }
        guard let manifest = manifests.first(where: {
            fm.fileExists(atPath: project + "/" + $0)
        }) else { skippedUnowned += 1; return nil }

        // 2) Is anyone working here — or anywhere that contains here? A
        //    monorepo's `packages/legacy` can sit untouched for a year while
        //    the repo around it ships daily, and pulling its `node_modules`
        //    out breaks the workspace's symlink graph exactly as if someone
        //    had deleted it from the root.
        let enclosing = enclosingProjects(of: project)
        let idle = ([project] + enclosing).map { idleDays(of: $0) }.min() ?? 0
        guard idle >= idleThresholdDays else { skippedActive += 1; return nil }

        // 3) The repo's own verdict. Unknown (no repo, no git) falls back to
        //    the manifest proof from step 1 rather than blocking the row.
        let siblingPaths = siblings.map { project + "/" + $0 }
        if isIgnored(artifact, in: project, siblings: siblingPaths) == false {
            skippedTracked += 1
            return nil
        }

        // A workspace pins its whole tree from one lockfile at the root, so
        // looking only beside the manifest marked every single package as
        // unreproducible and dropped it a tier.
        let locks = Self.lockfiles[manifest] ?? []
        let hasLock = ([project] + enclosing).contains { dir in
            locks.contains { fm.fileExists(atPath: dir + "/" + $0) }
        }
        let root = enclosing.last ?? project
        return Artifact(path: artifact, project: project, root: root, idleDays: idle,
                        restore: Self.restoreCommand(manifest: manifest, project: root, fm: fm),
                        reproducible: !Self.dependencyKinds.contains(kind) || hasLock)
    }

    /// Manifest-bearing ancestors, nearest first. A package inside a workspace
    /// has at least one; a standalone project has none.
    private func enclosingProjects(of project: String, maxHops: Int = 8) -> [String] {
        if let cached = enclosingCache[project] { return cached }
        var found: [String] = []
        var dir = project
        for _ in 0..<maxHops {
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty || parent == "/" { break }
            dir = parent
            // A home folder full of loose files is not somebody's workspace.
            if dir == NSHomeDirectory() { break }
            if Discovery.manifestMap.keys.contains(where: { fm.fileExists(atPath: dir + "/" + $0) }) {
                found.append(dir)
            }
        }
        enclosingCache[project] = found
        return found
    }

    var debugSummary: String {
        "atlandı: \(skippedActive) aktif proje, \(skippedTracked) sürüm kontrolünde izlenen, \(skippedUnowned) sahipsiz"
    }

    // MARK: Project liveness

    /// Days since anything in the project was last touched, with the artifact
    /// directories deliberately excluded.
    ///
    /// Signals, cheapest first: the project folder itself, git's own working
    /// files (`.git/index` moves on every `add`, `checkout`, `status` that
    /// refreshes stat data — the best single proxy for "I am in here"), and
    /// the newest source file within two levels. Bounded: a monorepo must not
    /// turn one candidate into a full-tree walk.
    func idleDays(of project: String) -> Int {
        if let cached = idleCache[project] { return cached }
        let days = Self.computeIdleDays(project, fm: fm)
        idleCache[project] = days
        return days
    }

    static func computeIdleDays(_ project: String, fm: FileManager,
                                now: Date = Date(), visitBudget: Int = 800) -> Int {
        var newest = mtime(project, fm) ?? .distantPast
        for probe in [".git/index", ".git/HEAD", ".git/FETCH_HEAD", ".git/ORIG_HEAD",
                      ".git/COMMIT_EDITMSG"] {
            if let m = mtime(project + "/" + probe, fm), m > newest { newest = m }
        }

        var visits = 0
        func walk(_ dir: String, depth: Int) {
            guard depth <= 2, visits < visitBudget else { return }
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for name in names {
                if visits >= visitBudget { return }
                visits += 1
                // Hidden entries are tool state, not work; artifact folders
                // are the very thing whose timestamp must not count.
                if name.hasPrefix(".") { continue }
                let lower = name.lowercased()
                if ownerManifests[lower] != nil || Discovery.cacheNameTokens.contains(lower) { continue }
                let path = dir + "/" + name
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    walk(path, depth: depth + 1)
                } else if let m = mtime(path, fm), m > newest {
                    newest = m
                }
            }
        }
        walk(project, depth: 1)
        return max(0, Int(now.timeIntervalSince(newest) / 86_400))
    }

    private static func mtime(_ path: String, _ fm: FileManager) -> Date? {
        (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: git check-ignore

    /// Is this path ignored by the project's own repo? `nil` when there is no
    /// repo or no usable `git` — an unknown answer, not a "no".
    private func isIgnored(_ path: String, in project: String, siblings: [String]) -> Bool? {
        var info = ignoreCache[project] ?? IgnoreInfo(isRepo: Self.repoRoot(of: project, fm: fm) != nil)
        defer { ignoreCache[project] = info }
        guard info.isRepo, Self.git != nil else { return nil }
        if !info.asked.contains(path) {
            let batch = Array(Set(siblings + [path]).subtracting(info.asked))
            guard let ignored = Self.checkIgnore(project: project, paths: batch) else {
                info.isRepo = false          // git refused; stop asking this project
                return nil
            }
            info.ignored.formUnion(ignored)
            info.asked.formUnion(batch)
        }
        return info.ignored.contains(path)
    }

    /// Nearest ancestor holding a `.git` (a worktree's `.git` is a file).
    static func repoRoot(of path: String, fm: FileManager, maxHops: Int = 12) -> String? {
        var dir = path
        for _ in 0..<maxHops {
            if fm.fileExists(atPath: dir + "/.git") { return dir }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty || parent == "/" { return nil }
            dir = parent
        }
        return nil
    }

    /// `git` as installed, never the bare `/usr/bin/git` shim: on a Mac with
    /// no developer tools that stub pops a GUI installer dialog and the scan
    /// waits behind it forever.
    static let git: String? = {
        let fm = FileManager.default
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git",
                          "/Library/Developer/CommandLineTools/usr/bin/git",
                          "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }()

    /// Ask the repo about every candidate at once. `git check-ignore --stdin`
    /// echoes back only the paths it ignores, exactly as they were given.
    /// Returns nil when git could not answer at all.
    static func checkIgnore(project: String, paths: [String],
                            timeout: TimeInterval = 5) -> Set<String>? {
        guard let git, !paths.isEmpty else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-C", project, "check-ignore", "--stdin"]
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"      // never write to someone's index
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["NO_COLOR"] = "1"
        p.environment = env

        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }

        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        try? stdin.fileHandleForWriting.write(contentsOf: Data(
            (paths.joined(separator: "\n") + "\n").utf8))
        try? stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()

        // 0 = some paths ignored, 1 = none of them, 128 = not a repo/failure.
        guard p.terminationStatus == 0 || p.terminationStatus == 1 else { return nil }
        return Set(String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init))
    }

    // MARK: Restore recipes

    /// What the user would type to get this back. Shown on the row and kept
    /// with the deletion: "regenerable" is only reassuring if the app can say
    /// how.
    static func restoreCommand(manifest: String, project: String, fm: FileManager) -> String {
        func has(_ file: String) -> Bool { fm.fileExists(atPath: project + "/" + file) }
        switch manifest {
        case "package.json":
            if has("pnpm-lock.yaml")                 { return "pnpm install" }
            if has("yarn.lock")                      { return "yarn install" }
            if has("bun.lockb") || has("bun.lock")   { return "bun install" }
            return "npm install"
        case "Package.swift":                        return "swift build"
        case "Gemfile":                              return "bundle install"
        case "requirements.txt":
            return "python3 -m venv .venv && pip install -r requirements.txt"
        case "mix.exs":                              return "mix deps.get"
        case "Cargo.toml":                           return "cargo build"
        case "Podfile":                              return "pod install"
        case "pubspec.yaml":                         return "flutter pub get"
        case "build.gradle", "build.gradle.kts":     return "./gradlew build"
        case "pyproject.toml":
            if has("uv.lock")                        { return "uv sync" }
            if has("poetry.lock")                    { return "poetry install" }
            return "pip install -e ."
        case "composer.json":                        return "composer install"
        default:                                     return ""
        }
    }
}
