import Foundation

/// Where the caches actually are, when that isn't where we are looking.
///
/// The scan roots default to the home folder, and on plenty of Macs that is
/// simply the wrong place. This app was written on a machine whose projects —
/// and whose pnpm store, according to pnpm itself — live on an external SSD,
/// so the entire Spotlight sweep ran over a home folder with no projects in
/// it. Nothing in the result could say so: an empty scan looks identical
/// whether there was nothing to clean or nobody looked in the right place.
///
/// So gather the evidence that points outside the enabled roots and say it
/// out loud. This is the half of learning that changes *where* we look at the
/// coarsest level — no amount of rescoring inside the home folder can find a
/// cache that lives on another disk.
enum RootAdvisor {

    struct Suggestion: Identifiable, Sendable, Equatable {
        let path: String
        let name: String
        /// Indexed cache/project markers found there — the case for looking.
        let hits: Int
        /// True when a tool or the user's own history named this disk
        /// directly, rather than it merely being indexed.
        let named: Bool
        var id: String { path }
    }

    /// Markers that mean "a developer works here". One Spotlight query per
    /// volume, counted rather than listed — this has to be cheap enough to
    /// run on every scan.
    private static let markerQuery = [
        "package.json", "Cargo.toml", "Package.swift", "go.mod",
        "pyproject.toml", "Podfile", "CACHEDIR.TAG",
    ].map { "kMDItemFSName == '\($0)'" }.joined(separator: " || ")

    /// Below this a volume is somebody's photo archive, not a workspace.
    private static let minimumHits = 5

    static func suggestions(roots: [String], excludes: [String], dismissed: [String],
                            probed: [String], places: [String]) async -> [Suggestion] {
        await Task.detached(priority: .utility) {
            let volumes = AppSettings.mountedVolumes()
                .filter { $0.path != "/" }
                .filter { v in !covered(v.path, by: roots) }
                .filter { v in !covered(v.path, by: excludes) && !dismissed.contains(v.path) }

            // A path a tool reported about itself, or one the user has
            // actually cleaned, is direct evidence — no indexing required.
            let namedOutside = Set((probed + places)
                .filter { !covered($0, by: roots) }
                .compactMap { volume(of: $0, among: volumes.map(\.path)) })

            return volumes.compactMap { v -> Suggestion? in
                let named = namedOutside.contains(v.path)
                let hits = markerCount(in: v.path)
                guard named || hits >= minimumHits else { return nil }
                return Suggestion(path: v.path, name: v.name, hits: hits, named: named)
            }
            .sorted { a, b in
                a.named == b.named ? a.hits > b.hits : a.named
            }
        }.value
    }

    // MARK: Helpers

    static func covered(_ path: String, by roots: [String]) -> Bool {
        roots.contains { contains($0, path) }
    }

    /// Whole-component containment. `/` needs its own case: appending a
    /// separator to it gives `//`, which nothing has as a prefix.
    static func contains(_ root: String, _ path: String) -> Bool {
        if root == "/" { return path.hasPrefix("/") }
        return path == root || path.hasPrefix(root + "/")
    }

    /// Which of `volumes` contains `path` (longest mount point wins, so a
    /// disk mounted inside another disk still resolves correctly).
    static func volume(of path: String, among volumes: [String]) -> String? {
        volumes
            .filter { contains($0, path) }
            .max(by: { $0.count < $1.count })
    }

    private static let markerNames: Set<String> = [
        "package.json", "Cargo.toml", "Package.swift", "go.mod",
        "pyproject.toml", "Podfile", "CACHEDIR.TAG",
    ]

    /// Spotlight first; walk when it has nothing to say. A zero from an
    /// unindexed disk is not evidence of an empty disk, and the disks that go
    /// unindexed are precisely the external ones this is meant to find.
    ///
    /// The walk costs seconds, and the answer to "does this disk hold
    /// projects" does not change between scans, so it is remembered per
    /// volume. A disk that appears later has no entry and gets counted then.
    private static func markerCount(in volume: String) -> Int {
        if let cached = cachedCount(for: volume) { return cached }
        let indexed = spotlightCount(in: volume)
        let count = indexed > 0 ? indexed : ManifestWalk.count(markerNames, under: volume)
        cache(count, for: volume)
        return count
    }

    private static let countsKey = "rootAdvisorCounts"
    private static let countsStamp = "rootAdvisorCountedAt"
    private static let countsTTL: TimeInterval = 24 * 3600

    private static func cachedCount(for volume: String) -> Int? {
        let d = UserDefaults.standard
        guard let at = d.object(forKey: countsStamp) as? Date,
              Date().timeIntervalSince(at) < countsTTL else { return nil }
        return (d.dictionary(forKey: countsKey) as? [String: Int])?[volume]
    }

    private static func cache(_ count: Int, for volume: String) {
        let d = UserDefaults.standard
        var counts = (d.dictionary(forKey: countsKey) as? [String: Int]) ?? [:]
        if d.object(forKey: countsStamp) == nil
            || Date().timeIntervalSince(d.object(forKey: countsStamp) as? Date ?? .distantPast) >= countsTTL {
            counts = [:]                       // stale round — start clean
        }
        counts[volume] = count
        d.set(counts, forKey: countsKey)
        d.set(Date(), forKey: countsStamp)
    }

    /// Forget the counts so the next scan re-checks (the refresh button).
    static func invalidate() {
        UserDefaults.standard.removeObject(forKey: countsStamp)
    }

    private static func spotlightCount(in volume: String) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-count", "-onlyin", volume, markerQuery]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Int(String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}
