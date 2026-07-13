import Foundation

/// The ONLY paths the privileged helper will ever touch, compiled into both
/// the app and the helper. Clients address entries by id; paths never cross
/// the XPC boundary, so a compromised caller can't steer the helper anywhere
/// outside this table.
public enum SystemAllowlist {

    public static let machService = "io.cachesweep.Helper"
    public static let helperVersion = "2"

    /// Dynamic entry: ghost data under /Volumes (see `OrphanVolumes`). Only
    /// the id crosses the XPC boundary; the helper recomputes the paths
    /// itself, so the "no caller-supplied paths" guarantee still holds.
    public static let orphanVolumesID = "sys-orphan-volumes"

    /// Code-signing requirement the helper enforces on connecting clients.
    public static let clientRequirement =
        #"anchor apple generic and identifier "io.cachesweep.Cachesweep" and certificate leaf[subject.OU] = "R9WY247JU6""#

    public enum Strategy: String, Codable, Sendable {
        case directory   // remove the path itself
        case contents    // remove children, keep the folder
    }

    public struct Entry: Sendable {
        public let id: String
        public let strategy: Strategy
        public let paths: [String]
        public init(id: String, strategy: Strategy, paths: [String]) {
            self.id = id
            self.strategy = strategy
            self.paths = paths
        }
    }

    public static let entries: [Entry] = [
        Entry(id: "sys-root", strategy: .directory,
              paths: ["/private/var/root/Library/Caches",
                      "/private/var/root/.gradle",
                      "/private/var/root/.npm",
                      "/private/var/root/.cache"]),
        Entry(id: "sys-lib-caches", strategy: .contents, paths: ["/Library/Caches"]),
        Entry(id: "sys-updates", strategy: .contents, paths: ["/Library/Updates"]),
        Entry(id: "sys-lib-logs", strategy: .contents, paths: ["/Library/Logs"]),
        Entry(id: "sys-usrlocal", strategy: .contents, paths: ["/usr/local/share/Library/Caches"]),
    ]
}

/// XPC surface between the app and the root helper. Entries are addressed by
/// allowlist id only; sizes travel back as JSON-encoded `[String: UInt64]`.
@objc public protocol CachesweepHelperProtocol {
    func helperVersion(reply: @escaping (String) -> Void)
    func scanSizes(reply: @escaping (Data) -> Void)
    func clean(ids: [String], deleteSnapshots: Bool, reply: @escaping (String?) -> Void)
}
