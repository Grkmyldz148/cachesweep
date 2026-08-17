import Foundation

/// Xcode simulator runtimes.
///
/// Their disk images live in system-owned asset storage
/// (`/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime`),
/// not under the user's home — so no scan of ~/Library, and no `du` the user
/// runs on their own folders, ever sees them. Yet on a Mac with Xcode a
/// single runtime is 8–10 GB: routinely larger than every cache on the
/// machine put together, and the biggest thing a cleaner can actually offer.
///
/// `simctl` is the only supported way to remove one. Deleting the asset by
/// hand leaves CoreSimulator holding a runtime it will neither use nor
/// re-download, so this goes through the tool even though it costs a process.
enum SimulatorRuntimes {

    struct Runtime: Sendable, Identifiable {
        let id: String                  // simctl runtime UUID
        let label: String               // "iOS 18.3.1"
        let runtimeIdentifier: String   // com.apple.CoreSimulator.SimRuntime.iOS-18-3
        let size: UInt64
    }

    enum RuntimeError: LocalizedError {
        case unavailable
        case simctl(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:      return "simctl is unavailable."
            case .simctl(let msg):  return msg
            }
        }
    }

    // MARK: Listing

    /// Installed, deletable runtimes with the sizes simctl reports.
    /// Empty when Xcode isn't set up — `xcrun` is only invoked once a
    /// developer directory exists, so this never triggers the "install the
    /// command line tools" dialog on a Mac that has neither.
    static func list() async -> [Runtime] {
        await Task.detached(priority: .utility) { listSync() }.value
    }

    static func listSync() -> [Runtime] {
        guard hasDeveloperTools(),
              let out = run(["simctl", "runtime", "list", "-j"]), out.status == 0,
              let root = try? JSONSerialization.jsonObject(with: out.data) as? [String: Any]
        else { return [] }
        return parse(root)
    }

    /// Pull the deletable runtimes out of `simctl runtime list -j` output.
    static func parse(_ root: [String: Any]) -> [Runtime] {
        root.compactMap { key, value -> Runtime? in
            guard let d = value as? [String: Any],
                  d["deletable"] as? Bool == true,
                  let size = (d["sizeBytes"] as? NSNumber)?.uint64Value, size > 0
            else { return nil }
            let identifier = d["runtimeIdentifier"] as? String ?? ""
            return Runtime(id: d["identifier"] as? String ?? key,
                           label: label(version: d["version"] as? String,
                                        runtimeIdentifier: identifier),
                           runtimeIdentifier: identifier,
                           size: size)
        }
        .sorted { $0.size > $1.size }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-18-3" + "18.3.1" → "iOS 18.3.1".
    static func label(version: String?, runtimeIdentifier: String) -> String {
        let platform = runtimeIdentifier.split(separator: ".").last
            .flatMap { $0.split(separator: "-").first }
            .map(String.init) ?? "Simulator"
        guard let version, !version.isEmpty else { return platform }
        return "\(platform) \(version)"
    }

    // MARK: Presentation

    static func target(for runtime: Runtime) -> CleanTarget {
        CleanTarget(
            id: "simrt:\(runtime.id)",
            name: runtime.label,
            detail: runtime.runtimeIdentifier.isEmpty ? runtime.id : runtime.runtimeIdentifier,
            symbol: "iphone",
            rawPaths: [],               // system-owned assets; simctl owns the removal
            safety: .caution,           // re-downloadable, but it is a long download
            strategy: .simulatorRuntime(id: runtime.id),
            isDiscovered: true,
            externalScope: true,
            knownSize: runtime.size,
            category: .devCaches
        )
    }

    // MARK: Deletion

    /// Remove one runtime. Throws simctl's own message — it refuses while a
    /// simulator using the runtime is booted, and the user needs to see why.
    nonisolated static func delete(id: String) throws {
        guard let out = run(["simctl", "runtime", "delete", id], timeout: deleteTimeout) else {
            throw RuntimeError.unavailable
        }
        guard out.status == 0 else {
            let message = String(decoding: out.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RuntimeError.simctl(message.isEmpty ? "simctl exited \(out.status)" : message)
        }
    }

    // MARK: Process plumbing

    /// Cheap gate before spawning anything: CoreSimulator's shared directory
    /// exists only once Xcode has run, and `xcode-select -p` reports a
    /// developer directory without ever offering to install one.
    private static func hasDeveloperTools() -> Bool {
        guard FileManager.default.fileExists(atPath: "/Library/Developer/CoreSimulator") else {
            return false
        }
        return run(["-p"], tool: "/usr/bin/xcode-select")?.status == 0
    }

    /// Listing is a question and should be instant; deleting moves gigabytes
    /// out of asset storage and is allowed to take its time.
    static let listTimeout: TimeInterval = 20
    static let deleteTimeout: TimeInterval = 300

    private static func run(_ arguments: [String],
                            tool: String = "/usr/bin/xcrun",
                            timeout: TimeInterval = listTimeout) -> (status: Int32, data: Data)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe              // simctl explains refusals on stderr
        p.standardInput = FileHandle.nullDevice   // nothing here may wait on an answer
        guard (try? p.run()) != nil else { return nil }

        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()

        return (p.terminationStatus, data)
    }
}
