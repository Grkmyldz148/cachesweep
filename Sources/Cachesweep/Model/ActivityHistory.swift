import Foundation
import Observation

extension Notification.Name {
    static let showHistory = Notification.Name("cachesweep.showHistory")
}

/// A time series of a folder's size, persisted across sessions.
struct GrowthRecord: Codable, Identifiable {
    var path: String
    var label: String
    var firstSeen: Date
    var lastSeen: Date
    var lastSize: UInt64
    var totalGrowth: UInt64            // sum of all positive deltas ever seen
    var samples: [Sample]

    var id: String { path }
    struct Sample: Codable { var t: Date; var size: UInt64 }
}

/// Phase: growth history. Records how tracked folders change over time so we
/// can answer "what grew this week?" across app restarts.
@MainActor
@Observable
final class ActivityHistory {
    static let shared = ActivityHistory()

    private(set) var records: [String: GrowthRecord] = [:]
    private let url: URL
    @ObservationIgnored private var lastSave = Date.distantPast

    private init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cachesweep", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("history.json")
        load()
    }

    /// Log a fresh size observation for a folder.
    func record(path: String, label: String, size: UInt64) {
        let now = Date()
        var r = records[path] ?? GrowthRecord(path: path, label: label, firstSeen: now,
                                              lastSeen: now, lastSize: size,
                                              totalGrowth: 0, samples: [])
        if size > r.lastSize { r.totalGrowth += (size - r.lastSize) }
        r.lastSize = size
        r.label = label
        r.lastSeen = now
        r.samples.append(.init(t: now, size: size))
        if r.samples.count > 60 { r.samples.removeFirst(r.samples.count - 60) }
        records[path] = r
        prune(now)
        saveThrottled(now)
    }

    /// Net growth of a record since a point in time (uses the nearest earlier sample).
    func growth(_ r: GrowthRecord, since: Date) -> Int64 {
        let base = r.samples.last(where: { $0.t <= since })?.size
            ?? r.samples.first?.size ?? r.lastSize
        return Int64(r.lastSize) - Int64(base)
    }

    /// Biggest movers within a window, largest change first.
    func topGrowers(since: Date, limit: Int = 20) -> [(record: GrowthRecord, growth: Int64)] {
        records.values
            .map { ($0, growth($0, since: since)) }
            .filter { $0.1 != 0 }
            .sorted { abs($0.1) > abs($1.1) }
            .prefix(limit)
            .map { (record: $0.0, growth: $0.1) }
    }

    /// Force-write pending records — saves are throttled, so call this at app
    /// termination to avoid losing the last few samples.
    func flush() { save() }

    // MARK: Housekeeping

    private func prune(_ now: Date) {
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        records = records.filter { $0.value.lastSeen >= cutoff }
        if records.count > 120 {
            let keep = records.sorted { $0.value.lastSeen > $1.value.lastSeen }.prefix(120)
            records = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: GrowthRecord].self, from: data) else { return }
        records = decoded
    }

    private func saveThrottled(_ now: Date) {
        guard now.timeIntervalSince(lastSave) > 5 else { return }
        lastSave = now
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: url) }
    }
}
