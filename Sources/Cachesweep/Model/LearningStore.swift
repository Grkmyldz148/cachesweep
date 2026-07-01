import Foundation
import Observation

/// What we've learned about a kind of cache (keyed by its leaf name, e.g.
/// "node_modules", "target", "com.apple.Safari").
struct Knowledge: Codable {
    var cleaned = 0       // times the user cleaned something of this kind
    var regenerated = 0   // times it grew back afterwards (proof it's regenerable)
    var skipped = 0       // times the user deliberately left it unselected
}

/// Phase 3 — the self-growing rules database.
///
/// Feedback (clean / skip) and the "clean → did it come back?" signal from the
/// live tracker are persisted and turned into confidence boosts that nudge
/// future classification. The curated seed list stays a prior; this learns the rest.
@MainActor
@Observable
final class LearningStore {
    static let shared = LearningStore()

    private(set) var knowledge: [String: Knowledge] = [:]
    /// cleanedPath → signature, awaiting a regeneration signal (this session).
    @ObservationIgnored private var pending: [String: String] = [:]
    private let url: URL

    private init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cachesweep", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("learning.json")
        load()
    }

    /// Generalize a path to its "kind".
    static func signature(forPath path: String) -> String {
        (path as NSString).lastPathComponent.lowercased()
    }

    /// Confidence adjustment for a kind, from accumulated evidence.
    func boost(for signature: String) -> Double {
        guard let k = knowledge[signature] else { return 0 }
        var b = 0.0
        if k.regenerated >= 1 { b += 0.5 }        // confirmed regenerable → trust it
        else if k.cleaned >= 2 { b += 0.3 }       // user repeatedly cleans it
        if k.cleaned == 0 && k.skipped >= 3 { b -= 0.4 }   // user keeps avoiding it
        return b
    }

    /// Snapshot of all known boosts — handed to the background discovery pass.
    func boosts() -> [String: Double] {
        knowledge.keys.reduce(into: [:]) { $0[$1] = boost(for: $1) }
    }

    // MARK: Feedback

    func recordCleaned(path: String) {
        let sig = Self.signature(forPath: path)
        knowledge[sig, default: Knowledge()].cleaned += 1
        pending[path] = sig
        save()
    }

    /// One skip per kind per clean action (callers dedupe by signature) —
    /// otherwise five unselected node_modules folders would count as five skips.
    func recordSkipped(signature sig: String) {
        knowledge[sig, default: Knowledge()].skipped += 1
        save()
    }

    /// Called by the live tracker on every write. If it lands in a path we
    /// recently cleaned, the cache regenerated — strong proof it's safe to clean.
    func noticeActivity(at path: String) {
        for (cleanedPath, sig) in pending where path == cleanedPath || path.hasPrefix(cleanedPath + "/") {
            knowledge[sig, default: Knowledge()].regenerated += 1
            pending[cleanedPath] = nil
            sweepDebug("🧠 doğrulandı: \(sig) temizlendi → geri geldi (regen +1)")
            save()
        }
    }

    var summary: String {
        knowledge.isEmpty ? "boş"
            : knowledge.map { "\($0.key)(c\($0.value.cleaned)/r\($0.value.regenerated)/s\($0.value.skipped))" }
                       .joined(separator: ", ")
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Knowledge].self, from: data) else { return }
        knowledge = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(knowledge) { try? data.write(to: url) }
    }
}
