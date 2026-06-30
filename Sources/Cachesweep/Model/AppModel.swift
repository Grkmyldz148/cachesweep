import Foundation
import Observation

/// Stderr debug, gated by SWEEP_DEBUG env var.
func sweepDebug(_ s: String) {
    if ProcessInfo.processInfo.environment["SWEEP_DEBUG"] != nil {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}

/// Per-target observable state shown in the UI.
@Observable
final class TargetState: Identifiable {
    let target: CleanTarget
    var size: UInt64 = 0
    var isSelected: Bool
    var isCleaning: Bool = false

    var id: String { target.id }

    init(target: CleanTarget) {
        self.target = target
        // Default-select the obviously-safe caches.
        self.isSelected = target.safety == .safe
    }
}

@MainActor
@Observable
final class AppModel {
    var targets: [TargetState] = CleanTarget.all.map(TargetState.init)
    var isScanning = false
    var isCleaning = false
    var lastScan: Date?
    var lastFreed: UInt64 = 0
    var freeSpace: UInt64 = 0

    // Live tracking (FSEvents)
    var activity: [ActivityEntry] = []
    var isMonitoring = false
    @ObservationIgnored private var monitor: FileActivityMonitor?
    @ObservationIgnored private var dirty: Set<String> = []
    @ObservationIgnored private var resizeTask: Task<Void, Never>?

    /// Sum of the selected targets — the headline "reclaimable" number.
    var selectedReclaimable: UInt64 {
        targets.filter { $0.isSelected && $0.size > 0 }.reduce(0) { $0 + $1.size }
    }

    /// Everything we found, selected or not.
    var grandTotal: UInt64 {
        targets.reduce(0) { $0 + $1.size }
    }

    var selectedCount: Int {
        targets.filter { $0.isSelected && $0.size > 0 }.count
    }

    // MARK: - Scanning

    func scan() async {
        guard !isScanning, !isCleaning else { return }
        isScanning = true
        defer { isScanning = false }

        refreshFreeSpace()

        await withTaskGroup(of: (String, UInt64).self) { group in
            for state in targets {
                let t = state.target
                group.addTask { (t.id, await Scanner.size(of: t.expandedPaths)) }
            }
            for await (id, size) in group {
                if let idx = targets.firstIndex(where: { $0.id == id }) {
                    targets[idx].size = size
                }
            }
        }
        lastScan = Date()
        refreshFreeSpace()
    }

    // MARK: - Cleaning

    func cleanSelected() async {
        await clean(ids: targets.filter { $0.isSelected && $0.size > 0 }.map(\.id))
    }

    func clean(ids: [String]) async {
        guard !isCleaning, !isScanning, !ids.isEmpty else { return }
        isCleaning = true
        defer { isCleaning = false }

        let chosen = targets.filter { ids.contains($0.id) }
        for state in chosen { state.isCleaning = true }
        let payload = chosen.map(\.target)

        let freed = await withTaskGroup(of: UInt64.self) { group -> UInt64 in
            for t in payload { group.addTask { Cleaner.clean(t) } }
            var total: UInt64 = 0
            for await f in group { total += f }
            return total
        }

        for state in chosen { state.isCleaning = false }
        lastFreed = freed
        await scan()
    }

    // MARK: - Live tracking

    func startMonitoring() {
        guard monitor == nil else { return }
        let m = FileActivityMonitor(paths: [NSHomeDirectory()]) { [weak self] changed in
            Task { @MainActor in self?.ingest(changed) }
        }
        m.start()
        monitor = m
        isMonitoring = true
    }

    private func knownRoots() -> [(path: String, name: String, symbol: String)] {
        targets.flatMap { st in
            st.target.expandedPaths.map { ($0, st.target.name, st.target.symbol) }
        }
    }

    func ingest(_ changed: Set<String>) {
        let now = Date()
        let roots = knownRoots()
        var touched = false
        for path in changed {
            guard let b = Buckets.classify(path, knownRoots: roots) else { continue }
            touched = true
            if let e = activity.first(where: { $0.id == b.path }) {
                e.lastChange = now
                e.changeCount += 1
            } else {
                let e = ActivityEntry(id: b.path, label: b.label, symbol: b.symbol,
                                      isKnown: b.isKnown, lastChange: now)
                e.changeCount = 1
                activity.append(e)
            }
            dirty.insert(b.path)
        }
        if touched {
            sweepDebug("👀 aktivite → " + activity.prefix(6).map { ($0.isKnown ? "✓" : "?") + $0.label }.joined(separator: ", "))
            scheduleResize()
        }
    }

    private func scheduleResize() {
        resizeTask?.cancel()
        resizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            let buckets = self.dirty
            self.dirty.removeAll()
            for path in buckets {
                let size = await Scanner.size(of: [path])
                if let e = self.activity.first(where: { $0.id == path }) {
                    if !e.hasBaseline { e.baseline = size; e.hasBaseline = true }
                    e.size = size
                }
            }
            // Drop stale empties, keep the most recent dozen.
            self.activity.removeAll { $0.size == 0 && Date().timeIntervalSince($0.lastChange) > 90 }
            self.activity.sort { $0.lastChange > $1.lastChange }
            if self.activity.count > 12 { self.activity = Array(self.activity.prefix(12)) }
            self.refreshFreeSpace()
            for e in self.activity.prefix(6) {
                self.sweepDebugEntry(e)
            }
        }
    }

    private func sweepDebugEntry(_ e: ActivityEntry) {
        sweepDebug("   📦 \(e.label) = \(e.size.fileSize)" + (e.delta > 0 ? " ▲\(UInt64(e.delta).fileSize)" : ""))
    }

    /// Clean an auto-discovered location (contents only — keep the folder).
    func cleanDiscovered(_ entry: ActivityEntry) async {
        let t = CleanTarget(id: "disc-\(entry.id)", name: entry.label, detail: entry.id,
                            symbol: entry.symbol, rawPaths: [entry.id],
                            safety: .caution, strategy: .contents)
        let freed = await withTaskGroup(of: UInt64.self) { group -> UInt64 in
            group.addTask { Cleaner.clean(t) }
            var total: UInt64 = 0
            for await f in group { total += f }
            return total
        }
        lastFreed = freed
        let newSize = await Scanner.size(of: [entry.id])
        entry.size = newSize
        entry.baseline = newSize
        refreshFreeSpace()
    }

    // MARK: - Disk

    func refreshFreeSpace() {
        let url = URL(fileURLWithPath: "/")
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let avail = v.volumeAvailableCapacityForImportantUsage {
            freeSpace = UInt64(max(0, avail))
        }
    }
}

// MARK: - Byte formatting

extension UInt64 {
    var fileSize: String {
        Int64(self).formatted(.byteCount(style: .file))
    }
}
