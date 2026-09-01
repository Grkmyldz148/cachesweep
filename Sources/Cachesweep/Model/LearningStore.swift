import Foundation
import Observation

/// What we've learned about a *kind* of cache (keyed by its signature, e.g.
/// "node_modules", "code/cache", "com.docker.docker/caches").
struct Knowledge: Codable {
    var cleaned = 0              // times the user cleaned something of this kind
    var regenerated = 0          // times it grew back afterwards (proof it's regenerable)
    var skipped = 0              // times the user deliberately left it unselected
    var freedBytes: UInt64 = 0   // how much this kind has actually returned, in total
    var boomerang = 0            // times it refilled to most of its size within days

    init() {}

    /// Hand-written so a store written before the newer fields existed still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cleaned = try c.decodeIfPresent(Int.self, forKey: .cleaned) ?? 0
        regenerated = try c.decodeIfPresent(Int.self, forKey: .regenerated) ?? 0
        skipped = try c.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
        freedBytes = try c.decodeIfPresent(UInt64.self, forKey: .freedBytes) ?? 0
        boomerang = try c.decodeIfPresent(Int.self, forKey: .boomerang) ?? 0
    }
}

/// A concrete location the user has actually cleaned. Knowledge generalises
/// to a kind; this remembers the *place*, so somewhere Spotlight never
/// indexed still gets probed directly on the next scan.
struct Place: Codable {
    var cleaned = 0
    var regenerated = 0
    var freedBytes: UInt64 = 0
    var lastCleaned = Date()
}

/// A clean waiting for its "did it come back?" answer.
struct PendingClean: Codable {
    let signature: String
    var at = Date()
}

/// A clean waiting for its "how much of it came back?" answer. Separate from
/// `PendingClean`: regeneration proof consumes its entry on the first write,
/// while this one has to survive until somebody measures the folder again.
struct SizeWatch: Codable {
    let signature: String
    let freed: UInt64
    var at = Date()
}

/// Phase 3 — the self-growing rules database.
///
/// Feedback (clean / skip), the bytes each clean actually returned, and the
/// "clean → did it come back?" signal from the live tracker are persisted and
/// turned into three things: a confidence boost that nudges classification, a
/// size expectation that decides what survives the discovery cap, and a set
/// of known places that get probed directly. The curated seed list stays a
/// prior; this learns the rest.
@MainActor
@Observable
final class LearningStore {
    static let shared = LearningStore()

    private(set) var knowledge: [String: Knowledge] = [:]
    private(set) var places: [String: Place] = [:]
    /// cleanedPath → the clean awaiting a regeneration signal (persisted, so
    /// the proof survives an app restart).
    @ObservationIgnored private var pending: [String: PendingClean] = [:]
    /// cleanedPath → the clean awaiting a refill measurement (boomerang test).
    @ObservationIgnored private var sizeWatch: [String: SizeWatch] = [:]
    private let url: URL

    /// How long a clean waits for its cache to come back before we stop
    /// listening. Without this the dictionary only ever grows.
    private static let pendingTTL: TimeInterval = 30 * 86_400
    /// A place nobody has cleaned in this long has stopped being interesting.
    private static let placeTTL: TimeInterval = 120 * 86_400
    private static let maxPlaces = 200

    /// Boomerang test: a clean under this size isn't worth second-guessing…
    nonisolated static let boomerangMinBytes: UInt64 = 50 * 1024 * 1024
    /// …and only a refill inside this window counts as "right away".
    nonisolated static let boomerangWindow: TimeInterval = 7 * 86_400
    /// The fraction of the freed bytes that has to be back.
    nonisolated static let boomerangRefillFraction = 0.6
    /// Watches that never got an answer are dropped after this long.
    private static let sizeWatchTTL: TimeInterval = 14 * 86_400

    /// On-disk layout, with migration from both older formats.
    private struct Store: Codable {
        var version = 2
        var knowledge: [String: Knowledge]
        var pending: [String: PendingClean]
        var places: [String: Place]
        var sizeWatch: [String: SizeWatch]? = nil   // absent in older stores
    }

    private init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cachesweep", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("learning.json")
        load()
    }

    // MARK: Signatures

    /// Leaves that say "cache" without saying whose. Every app has one, so on
    /// their own they name nothing — learning keyed on them just pools twenty
    /// unrelated apps into a single meaningless bucket.
    nonisolated static let ambiguousLeaves: Set<String> = [
        "cache", "caches", "cachedata", "cacheddata", "cachestorage", "code cache",
        "gpucache", "shadercache", "scriptcache", "dawngraphitecache", "dawnwebgpucache",
        "tmp", "temp", "data", "storage", "logs", "log", "default",
    ]

    /// Path furniture that never identifies an owner.
    nonisolated static let structuralComponents: Set<String> = [
        "users", "library", "application support", "containers", "group containers",
        "data", "caches", "cache", "private", "var", "folders", "service worker",
        "local", "share", "documents", "contents", "resources",
    ]

    /// Generalise a path to the kind of thing it is.
    ///
    /// A leaf like `node_modules` or `DerivedData` names a kind by itself, and
    /// that generality is the whole point: learn it once in one project, apply
    /// it in every other. A leaf like `Cache` names nothing, so it gets
    /// qualified with the app that owns it — skipping the structural pieces
    /// (`Data`, `Library`, `Application Support`, `Profile 3`) in between.
    nonisolated static func signature(forPath path: String) -> String {
        let comps = path.split(separator: "/").map { $0.lowercased() }
        guard let leaf = comps.last else { return "" }
        guard ambiguousLeaves.contains(leaf) else { return leaf }

        for i in stride(from: comps.count - 2, through: 0, by: -1) {
            let c = comps[i]
            if structuralComponents.contains(c) || ambiguousLeaves.contains(c) { continue }
            if isProfileComponent(c) { continue }
            if i > 0 && comps[i - 1] == "users" { continue }   // the home folder's name
            return "\(c)/\(leaf)"
        }
        return leaf
    }

    private nonisolated static func isProfileComponent(_ c: String) -> Bool {
        c.hasPrefix("profile ") || c == "guest profile" || c == "system profile"
    }

    // MARK: Signals out

    /// Confidence adjustment for a kind, from accumulated evidence.
    func boost(for signature: String) -> Double {
        guard let k = knowledge[signature] else { return 0 }
        var b = 0.0
        if k.regenerated >= 1 { b += 0.5 }        // confirmed regenerable → trust it
        else if k.cleaned >= 2 { b += 0.3 }       // user repeatedly cleans it
        if k.cleaned == 0 && k.skipped >= 3 { b -= 0.4 }   // user keeps avoiding it
        return b
    }

    /// Average bytes a kind has returned per clean. Deliberately *not* folded
    /// into `boost`: size says nothing about whether something is a cache, so
    /// it must never move the safety verdict. It is a priority signal — it
    /// decides who survives the discovery cap, which is exactly the judgement
    /// a confidence score cannot make.
    func expectedBytes(for signature: String) -> UInt64 {
        guard let k = knowledge[signature], k.cleaned > 0 else { return 0 }
        return k.freedBytes / UInt64(k.cleaned)
    }

    /// Snapshots handed to the background discovery pass.
    func boosts() -> [String: Double] {
        knowledge.keys.reduce(into: [:]) { $0[$1] = boost(for: $1) }
    }

    func expectations() -> [String: UInt64] {
        knowledge.keys.reduce(into: [:]) { $0[$1] = expectedBytes(for: $1) }
    }

    /// Places worth probing directly on every scan: the user cleaned real
    /// bytes there, so it is a cache *on this machine* whatever Spotlight
    /// happens to have indexed. This is the part of learning that changes
    /// where we look rather than only how we score.
    func knownPlaces(limit: Int = 40) -> [String] {
        places
            .filter { $0.value.freedBytes > 0 }
            .sorted {
                ($0.value.regenerated, $0.value.freedBytes) >
                ($1.value.regenerated, $1.value.freedBytes)
            }
            .prefix(limit)
            .map(\.key)
    }

    /// Containers where a kind of cache has been found more than once, and
    /// which kinds those were: `/Volumes/ssd → [node_modules, target]`.
    ///
    /// `knownPlaces` can only re-offer somewhere already cleaned. This
    /// generalises one step further — if two projects under a folder both
    /// turned out to have a `node_modules`, the *other* projects under it
    /// probably do too, and those have never been cleaned, may not be
    /// indexed, and no rule in the app would otherwise look at them. It is
    /// the difference between remembering and inferring.
    func hotSpots(minimumSiblings: Int = 2) -> [String: Set<String>] {
        // container → kind → the distinct project folders it was seen in
        var seen: [String: [String: Set<String>]] = [:]
        for path in places.keys {
            let kind = (path as NSString).lastPathComponent
            guard !kind.isEmpty else { continue }
            let project = (path as NSString).deletingLastPathComponent
            let container = (project as NSString).deletingLastPathComponent
            guard container.count > 1, project != container else { continue }
            seen[container, default: [:]][kind, default: []].insert(project)
        }
        return seen.reduce(into: [:]) { out, entry in
            let kinds = entry.value
                .filter { $0.value.count >= minimumSiblings }
                .keys
            if !kinds.isEmpty { out[entry.key] = Set(kinds) }
        }
    }

    // MARK: Feedback

    func recordCleaned(path: String, freed: UInt64) {
        let sig = Self.signature(forPath: path)
        var k = knowledge[sig] ?? Knowledge()
        k.cleaned += 1
        k.freedBytes += freed
        knowledge[sig] = k

        var place = places[path] ?? Place()
        place.cleaned += 1
        place.freedBytes += freed
        place.lastCleaned = Date()
        places[path] = place

        pending[path] = PendingClean(signature: sig)
        if freed >= Self.boomerangMinBytes {
            sizeWatch[path] = SizeWatch(signature: sig, freed: freed)
        }
        prune()
        save()
    }

    /// The boomerang test, as a pure decision so it can be reasoned about:
    /// nil = keep watching, true = it refilled right away (churn, not a win),
    /// false = the window closed without a refill (a real clean).
    nonisolated static func refillVerdict(freed: UInt64, measured: UInt64,
                                          cleanedAt: Date, now: Date = Date()) -> Bool? {
        if now.timeIntervalSince(cleanedAt) > boomerangWindow { return false }
        if Double(measured) >= Double(freed) * boomerangRefillFraction { return true }
        return nil
    }

    /// Fed by anything that measures a folder (scan sizing, the live
    /// tracker's resize): if a recently cleaned place is back to most of its
    /// old size within days, cleaning it again is churn — record that, so the
    /// row can say so and discovery can rank it down.
    func noticeMeasuredSize(path: String, size: UInt64) {
        guard let w = sizeWatch[path] else { return }
        switch Self.refillVerdict(freed: w.freed, measured: size, cleanedAt: w.at) {
        case nil:
            return                              // window still open — keep watching
        case true?:
            knowledge[w.signature, default: Knowledge()].boomerang += 1
            sweepDebug("🧠 bumerang: \(w.signature) temizlendi → günler içinde geri doldu")
        case false?:
            break                               // stayed clean — nothing to record
        }
        sizeWatch[path] = nil
        save()
    }

    /// Kinds proven to refill right after cleaning — still offered (they are
    /// caches), but never preselected and ranked below everything else.
    func boomerangKinds() -> Set<String> {
        Set(knowledge.filter { $0.value.boomerang >= 1 }.keys)
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
        for (cleanedPath, p) in pending where path == cleanedPath || path.hasPrefix(cleanedPath + "/") {
            knowledge[p.signature, default: Knowledge()].regenerated += 1
            places[cleanedPath]?.regenerated += 1
            pending[cleanedPath] = nil
            sweepDebug("🧠 doğrulandı: \(p.signature) temizlendi → geri geldi (regen +1)")
            save()
        }
    }

    var summary: String {
        knowledge.isEmpty ? "boş"
            : knowledge
                .sorted { $0.value.freedBytes > $1.value.freedBytes }
                .prefix(8)
                .map { "\($0.key)(c\($0.value.cleaned)/r\($0.value.regenerated)/s\($0.value.skipped)/\($0.value.freedBytes.fileSize))" }
                .joined(separator: ", ")
            + " · \(places.count) yer"
    }

    // MARK: Housekeeping

    /// Drop clean records that never came back and places nobody touches, so
    /// neither dictionary grows without bound.
    private func prune() {
        let now = Date()
        pending = pending.filter { now.timeIntervalSince($0.value.at) < Self.pendingTTL }
        sizeWatch = sizeWatch.filter { now.timeIntervalSince($0.value.at) < Self.sizeWatchTTL }
        places = places.filter {
            $0.value.regenerated > 0 || now.timeIntervalSince($0.value.lastCleaned) < Self.placeTTL
        }
        guard places.count > Self.maxPlaces else { return }
        places = Dictionary(uniqueKeysWithValues: places
            .sorted { $0.value.lastCleaned > $1.value.lastCleaned }
            .prefix(Self.maxPlaces)
            .map { ($0.key, $0.value) })
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        if let store = try? JSONDecoder().decode(Store.self, from: data) {
            knowledge = store.knowledge
            pending = store.pending
            places = store.places
            sizeWatch = store.sizeWatch ?? [:]
        } else if let old = try? JSONDecoder().decode(LegacyStore.self, from: data) {
            knowledge = old.knowledge
            pending = old.pending.mapValues { PendingClean(signature: $0) }
        } else if let oldest = try? JSONDecoder().decode([String: Knowledge].self, from: data) {
            knowledge = oldest
        }
        // Signatures used to be the bare leaf, so every app's "Cache" landed
        // in one bucket. Those keys can't be attributed to an owner after the
        // fact and would keep polluting unrelated apps — drop them and relearn.
        let ambiguous = knowledge.keys.filter { Self.ambiguousLeaves.contains($0) }
        if !ambiguous.isEmpty {
            for key in ambiguous { knowledge[key] = nil }
            sweepDebug("🧠 göç: \(ambiguous.count) belirsiz imza atıldı (\(ambiguous.joined(separator: ", ")))")
        }
        prune()
    }

    private struct LegacyStore: Codable {
        var knowledge: [String: Knowledge]
        var pending: [String: String]
    }

    private func save() {
        let store = Store(knowledge: knowledge, pending: pending, places: places,
                          sizeWatch: sizeWatch)
        if let data = try? JSONEncoder().encode(store) { try? data.write(to: url) }
    }
}
