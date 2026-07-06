import Foundation
import ServiceManagement
import CachesweepCore

/// Client for the root XPC helper (SMAppService daemon). Registration is
/// attempted lazily; until the user approves the background item in System
/// Settings, callers get nil/false and RootCleaner falls back to the
/// osascript admin prompt — so system cleaning always works, and silently
/// stops asking for a password once the helper is approved.
@MainActor
final class HelperClient {
    static let shared = HelperClient()
    private init() {}

    private static let plistName = "io.cachesweep.Helper.plist"
    private var connection: NSXPCConnection?

    private var service: SMAppService { SMAppService.daemon(plistName: Self.plistName) }

    /// True when the daemon is registered and approved. Attempts registration
    /// when possible; never blocks or prompts by itself (approval lives in
    /// System Settings → Login Items).
    func ensureRegistered() -> Bool {
        let s = service
        switch s.status {
        case .enabled:
            return true
        case .notRegistered, .notFound:
            try? s.register()
            sweepDebug("🔒 helper register denendi → status \(s.status.rawValue)")
            return s.status == .enabled
        case .requiresApproval:
            return false
        @unknown default:
            return false
        }
    }

    private func ensureConnection() -> NSXPCConnection {
        if let connection { return connection }
        let c = NSXPCConnection(machServiceName: SystemAllowlist.machService,
                                options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: CachesweepHelperProtocol.self)
        c.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        c.resume()
        connection = c
        return c
    }

    /// Sizes per allowlist id, or nil when the helper isn't usable.
    func scanSizes() async -> [String: UInt64]? {
        guard ensureRegistered() else { return nil }
        let c = ensureConnection()
        return await withCheckedContinuation { cont in
            let finished = Atomic(false)
            let finish: (@Sendable ([String: UInt64]?) -> Void) = { value in
                guard finished.take() else { return }
                cont.resume(returning: value)
            }
            guard let p = c.remoteObjectProxyWithErrorHandler({ _ in finish(nil) })
                    as? CachesweepHelperProtocol else { finish(nil); return }
            p.scanSizes { data in
                finish(try? JSONDecoder().decode([String: UInt64].self, from: data))
            }
        }
    }

    /// Cleans the given allowlist ids; returns false when the helper isn't
    /// usable (caller should fall back), throws on a real helper-side error.
    func clean(ids: [String], deleteSnapshots: Bool) async throws -> Bool {
        guard ensureRegistered() else { return false }
        let c = ensureConnection()
        return try await withCheckedThrowingContinuation { cont in
            let finished = Atomic(false)
            guard let p = c.remoteObjectProxyWithErrorHandler({ _ in
                guard finished.take() else { return }
                cont.resume(returning: false)
            }) as? CachesweepHelperProtocol else {
                if finished.take() { cont.resume(returning: false) }
                return
            }
            p.clean(ids: ids, deleteSnapshots: deleteSnapshots) { error in
                guard finished.take() else { return }
                if let error {
                    cont.resume(throwing: RootCleaner.RootCleanerError.failed(error))
                } else {
                    cont.resume(returning: true)
                }
            }
        }
    }
}

/// Tiny lock-guarded flag so an XPC error handler and a reply can't both
/// resume the same continuation.
private final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var fired: Bool
    init(_ value: Bool) { fired = value }
    /// Returns true exactly once.
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
