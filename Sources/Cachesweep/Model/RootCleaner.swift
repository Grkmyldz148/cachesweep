import Foundation
import CachesweepCore

/// Root-owned "System Data" locations, scanned and cleaned through the
/// SMAppService XPC helper when it is registered and approved, falling back
/// to a one-shot administrator authorization (osascript `with administrator
/// privileges`) otherwise — so the feature works before approval and simply
/// stops prompting for a password afterwards.
///
/// Security model: a strict, hardcoded ALLOWLIST, shared with the helper
/// (`SystemAllowlist`). The helper only accepts entry ids — paths never cross
/// the process boundary. The osascript fallback composes its commands from
/// the same fixed table, never from user input or discovery.
enum RootCleaner {

    /// Presentation metadata per allowlist id (the paths + strategy live in
    /// `SystemAllowlist`, compiled into both the app and the helper).
    private static let meta: [String: (name: String, detail: String)] = [
        "sys-root": ("sys.root", "/var/root (.gradle, .npm, Caches…)"),
        "sys-lib-caches": ("sys.libcaches", "/Library/Caches"),
        "sys-updates": ("sys.updates", "/Library/Updates"),
        "sys-lib-logs": ("sys.syslogs", "/Library/Logs"),
        "sys-usrlocal": ("sys.usrlocal", "/usr/local/share/Library/Caches"),
    ]

    /// Curated root-owned locations that are safe to reclaim, plus the
    /// dynamic "ghost data" entry: directories under /Volumes that are not
    /// mount points but hold data (written while a disk was ejected). Its
    /// paths are computed at scan/clean time, never stored here.
    static let targets: [CleanTarget] = SystemAllowlist.entries.map { entry in
        let m = meta[entry.id] ?? (entry.id, entry.paths.first ?? "")
        return CleanTarget(id: entry.id, name: m.name,
                           detail: m.detail,
                           symbol: "lock.shield",
                           rawPaths: entry.paths,
                           safety: .caution,
                           strategy: entry.strategy == .directory ? .directory : .contents,
                           needsAdmin: true)
    } + [
        CleanTarget(id: SystemAllowlist.orphanVolumesID, name: "sys.orphans",
                    detail: "/Volumes/*",
                    symbol: "externaldrive.badge.xmark",
                    rawPaths: [],
                    safety: .caution, strategy: .directory, needsAdmin: true)
    ]

    /// Sizes per target id — via the helper when available (no prompt),
    /// otherwise one admin prompt for a `du` over the allowlist.
    @MainActor
    static func scanSizes() async throws -> [String: UInt64] {
        if let sizes = await HelperClient.shared.scanSizes() {
            sweepDebug("🔒 sistem taraması helper üzerinden")
            return sizes
        }
        let orphans = OrphanVolumes.orphanDirectories()
        let paths = targets.flatMap(\.rawPaths) + orphans
        let quoted = paths.map(shellQuote).joined(separator: " ")
        let out = try await runPrivileged("/usr/bin/du -sk \(quoted) 2>/dev/null; exit 0")

        var perPath: [String: UInt64] = [:]
        for line in out.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2,
                  let kb = UInt64(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            perPath[String(parts[1])] = kb * 1024
        }
        var sizes: [String: UInt64] = targets.reduce(into: [:]) { acc, t in
            acc[t.id] = t.rawPaths.reduce(0) { $0 + (perPath[$1] ?? 0) }
        }
        sizes[SystemAllowlist.orphanVolumesID] = orphans.reduce(0) { $0 + (perPath[$1] ?? 0) }
        return sizes
    }

    /// Remove the chosen targets (allowlist ids only), optionally deleting all
    /// local Time Machine snapshots in the same batch. Helper first; one admin
    /// prompt as fallback.
    @MainActor
    static func clean(targets chosen: [CleanTarget], deleteSnapshots: Bool = false) async throws {
        let validIDs = Set(targets.map(\.id))
        let ids = chosen.map(\.id).filter(validIDs.contains)
        guard !ids.isEmpty || deleteSnapshots else { return }

        if try await HelperClient.shared.clean(ids: ids, deleteSnapshots: deleteSnapshots) {
            sweepDebug("🔒 sistem temizliği helper üzerinden")
            return
        }

        // Fallback: same table, one osascript admin prompt.
        let byID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
        var cmds: [String] = []
        for id in ids {
            if id == SystemAllowlist.orphanVolumesID {
                for dir in OrphanVolumes.orphanDirectories() {
                    let q = shellQuote(dir)
                    // Refuse if the disk was mounted since the scan: a mount
                    // point sits on its own device, unlike /Volumes itself.
                    cmds.append("[ \"$(/usr/bin/stat -f%d \(q))\" = \"$(/usr/bin/stat -f%d /Volumes)\" ] && /bin/rm -rf \(q)")
                }
                continue
            }
            guard let t = byID[id] else { continue }
            for p in t.rawPaths {
                switch t.strategy {
                case .directory:
                    cmds.append("/bin/rm -rf '\(p)'")
                case .contents:
                    cmds.append("/bin/rm -rf '\(p)'/* '\(p)'/.[!.]*")
                }
            }
        }
        if deleteSnapshots {
            cmds.append("/usr/bin/tmutil listlocalsnapshotdates / | /usr/bin/tail -n +2 | while read d; do /usr/bin/tmutil deletelocalsnapshots \"$d\"; done")
        }
        guard !cmds.isEmpty else { return }
        _ = try await runPrivileged("{ " + cmds.joined(separator: "; ") + "; } 2>/dev/null; exit 0")
    }

    /// Count local Time Machine snapshots (listing needs no admin).
    static func snapshotCount() async -> Int {
        await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
            p.arguments = ["listlocalsnapshots", "/"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return 0 }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .filter { $0.contains("com.apple.TimeMachine") }
                .count
        }.value
    }

    /// Single-quote for /bin/sh. Allowlist paths are fixed and quote-free,
    /// but orphan volume names come from disk labels: spaces and quotes.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Privileged runner (fallback path)

    enum RootCleanerError: Error {
        case cancelled
        case failed(String)
    }

    /// Runs a shell command as root via the standard macOS authorization
    /// dialog. Throws .cancelled when the user dismisses the prompt.
    private static func runPrivileged(_ command: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let escaped = command
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let script = "do shell script \"\(escaped)\" with administrator privileges"

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let outPipe = Pipe(), errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            try p.run()
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            let err = errPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()

            if p.terminationStatus != 0 {
                let msg = String(decoding: err, as: UTF8.self)
                if msg.contains("-128") { throw RootCleanerError.cancelled }
                throw RootCleanerError.failed(msg)
            }
            return String(decoding: out, as: UTF8.self)
        }.value
    }
}
