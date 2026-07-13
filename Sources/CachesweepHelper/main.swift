import Foundation
import CachesweepCore

/// Root launchd daemon (registered via SMAppService.daemon). Does exactly two
/// things — size and remove the compiled-in allowlist — and nothing else:
///   * clients are verified against a code-signing requirement before the
///     connection is accepted (same team + app identifier);
///   * requests address allowlist entries by id; no paths, no shell, no
///     caller-controlled strings anywhere near the filesystem.
final class HelperService: NSObject, CachesweepHelperProtocol {

    func helperVersion(reply: @escaping (String) -> Void) {
        reply(SystemAllowlist.helperVersion)
    }

    func scanSizes(reply: @escaping (Data) -> Void) {
        var sizes: [String: UInt64] = [:]
        for entry in SystemAllowlist.entries {
            sizes[entry.id] = entry.paths.reduce(0) { $0 + Self.sizeOf($1) }
        }
        sizes[SystemAllowlist.orphanVolumesID] = OrphanVolumes.orphanDirectories()
            .reduce(0) { $0 + Self.sizeOf($1) }
        reply((try? JSONEncoder().encode(sizes)) ?? Data())
    }

    func clean(ids: [String], deleteSnapshots: Bool, reply: @escaping (String?) -> Void) {
        let wanted = Set(ids)
        let fm = FileManager.default
        var firstError: String?

        for entry in SystemAllowlist.entries where wanted.contains(entry.id) {
            for path in entry.paths {
                do {
                    switch entry.strategy {
                    case .directory:
                        if fm.fileExists(atPath: path) {
                            try fm.removeItem(atPath: path)
                        }
                    case .contents:
                        for child in (try? fm.contentsOfDirectory(atPath: path)) ?? [] {
                            try? fm.removeItem(atPath: (path as NSString).appendingPathComponent(child))
                        }
                    }
                } catch {
                    if firstError == nil { firstError = "\(path): \(error.localizedDescription)" }
                }
            }
        }

        if wanted.contains(SystemAllowlist.orphanVolumesID) {
            for dir in OrphanVolumes.orphanDirectories() {
                // The disk may have been mounted since the scan; deleting the
                // path would then hit the real volume. Re-check right before.
                guard OrphanVolumes.isStillOrphan(dir) else { continue }
                do {
                    try fm.removeItem(atPath: dir)
                } catch {
                    if firstError == nil { firstError = "\(dir): \(error.localizedDescription)" }
                }
            }
        }

        if deleteSnapshots {
            for date in Self.snapshotDates() {
                _ = Self.run("/usr/bin/tmutil", ["deletelocalsnapshots", date])
            }
        }
        reply(firstError)
    }

    // MARK: fixed-binary process helpers (argument arrays — no shell)

    private static func sizeOf(_ path: String) -> UInt64 {
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        let out = run("/usr/bin/du", ["-sk", path])
        guard let kb = UInt64(out.split(separator: "\t").first?
            .trimmingCharacters(in: .whitespaces) ?? "") else { return 0 }
        return kb * 1024
    }

    private static func snapshotDates() -> [String] {
        run("/usr/bin/tmutil", ["listlocalsnapshotdates", "/"])
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.first?.isNumber == true }
    }

    private static func run(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: CachesweepHelperProtocol.self)
        connection.exportedObject = HelperService()
        connection.resume()
        return true
    }
}

let listener = NSXPCListener(machServiceName: SystemAllowlist.machService)
// Refuse anyone who isn't our signed app — enforced by libxpc itself
// (traps at startup if the requirement string is malformed, which is the
// right failure mode for a root helper).
listener.setConnectionCodeSigningRequirement(SystemAllowlist.clientRequirement)
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()
dispatchMain()
