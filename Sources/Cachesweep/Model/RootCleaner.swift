import Foundation

/// Root-owned "System Data" locations, scanned and cleaned through a one-shot
/// administrator authorization (osascript `with administrator privileges`).
///
/// Security model: a strict, hardcoded ALLOWLIST. Shell commands are composed
/// only from the fixed paths below — never from user input or discovery.
/// One password prompt per action (scan or clean), nothing runs silently.
///
/// TODO: upgrade to an SMAppService XPC helper once Developer ID signing lands.
enum RootCleaner {

    /// Curated root-owned locations that are safe to reclaim.
    static let targets: [CleanTarget] = [
        CleanTarget(id: "sys-root", name: "Root Kullanıcısı Cache'leri",
                    detail: "/var/root (.gradle, .npm, Caches…)",
                    symbol: "lock.shield",
                    rawPaths: ["/private/var/root/Library/Caches",
                               "/private/var/root/.gradle",
                               "/private/var/root/.npm",
                               "/private/var/root/.cache"],
                    safety: .caution, strategy: .directory, needsAdmin: true),

        CleanTarget(id: "sys-lib-caches", name: "Sistem Cache'leri",
                    detail: "/Library/Caches",
                    symbol: "lock.shield",
                    rawPaths: ["/Library/Caches"],
                    safety: .caution, strategy: .contents, needsAdmin: true),

        CleanTarget(id: "sys-updates", name: "Bekleyen Güncelleme Dosyaları",
                    detail: "/Library/Updates",
                    symbol: "lock.shield",
                    rawPaths: ["/Library/Updates"],
                    safety: .caution, strategy: .contents, needsAdmin: true),

        CleanTarget(id: "sys-lib-logs", name: "Sistem Logları",
                    detail: "/Library/Logs",
                    symbol: "lock.shield",
                    rawPaths: ["/Library/Logs"],
                    safety: .caution, strategy: .contents, needsAdmin: true),

        CleanTarget(id: "sys-usrlocal", name: "Eski Paket Cache'leri (usr/local)",
                    detail: "/usr/local/share/Library/Caches",
                    symbol: "lock.shield",
                    rawPaths: ["/usr/local/share/Library/Caches"],
                    safety: .caution, strategy: .contents, needsAdmin: true),
    ]

    /// One admin prompt: `du` every allowlisted path, return bytes per target id.
    static func scanSizes() async throws -> [String: UInt64] {
        let paths = targets.flatMap(\.rawPaths)
        let quoted = paths.map { "'\($0)'" }.joined(separator: " ")
        let out = try await runPrivileged("/usr/bin/du -sk \(quoted) 2>/dev/null; exit 0")

        var perPath: [String: UInt64] = [:]
        for line in out.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2,
                  let kb = UInt64(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            perPath[String(parts[1])] = kb * 1024
        }
        return targets.reduce(into: [:]) { acc, t in
            acc[t.id] = t.rawPaths.reduce(0) { $0 + (perPath[$1] ?? 0) }
        }
    }

    /// One admin prompt: remove the chosen targets (allowlist paths only).
    static func clean(targets chosen: [CleanTarget]) async throws {
        // Only ever operate on our own allowlist, whatever the caller passes.
        let allowed = Set(targets.flatMap(\.rawPaths))
        var cmds: [String] = []
        for t in chosen {
            for p in t.rawPaths where allowed.contains(p) {
                switch t.strategy {
                case .directory:
                    cmds.append("/bin/rm -rf '\(p)'")
                case .contents:
                    cmds.append("/bin/rm -rf '\(p)'/* '\(p)'/.[!.]*")
                }
            }
        }
        guard !cmds.isEmpty else { return }
        _ = try await runPrivileged("{ " + cmds.joined(separator: "; ") + "; } 2>/dev/null; exit 0")
    }

    // MARK: - Privileged runner

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
