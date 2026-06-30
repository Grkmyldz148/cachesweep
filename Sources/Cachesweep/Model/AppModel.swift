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
        // Pre-select clearly-safe caches, but never something in active use.
        self.isSelected = target.safety == .safe && !target.inUse
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

    // Smart discovery (Phase 1)
    var discovered: [TargetState] = []

    // Live tracking (FSEvents)
    var activity: [ActivityEntry] = []
    var isMonitoring = false
    @ObservationIgnored private var monitor: FileActivityMonitor?
    @ObservationIgnored private var dirty: Set<String> = []
    @ObservationIgnored private var resizeTask: Task<Void, Never>?

    /// Seeds (curated) + discovered (smart), together.
    var allStates: [TargetState] { targets + discovered }

    /// Sum of the selected targets — the headline "reclaimable" number.
    var selectedReclaimable: UInt64 {
        allStates.filter { $0.isSelected && $0.size > 0 }.reduce(0) { $0 + $1.size }
    }

    /// Everything we found, selected or not.
    var grandTotal: UInt64 {
        allStates.reduce(0) { $0 + $1.size }
    }

    var selectedCount: Int {
        allStates.filter { $0.isSelected && $0.size > 0 }.count
    }

    // MARK: - Scanning

    func scan() async {
        guard !isScanning, !isCleaning else { return }
        isScanning = true
        defer { isScanning = false }

        refreshFreeSpace()

        // Smart discovery: find cache-like dirs beyond the curated seed list,
        // across the user's chosen scan roots and respecting their exclusions.
        let seedPaths = Set(targets.flatMap { $0.target.expandedPaths })
        let activePaths = Set(activity
            .filter { Date().timeIntervalSince($0.lastChange) < 120 }
            .map(\.id))
        let found = await Discovery.discover(roots: AppSettings.shared.scanRoots,
                                             excluding: seedPaths,
                                             excludes: AppSettings.shared.excludedPaths,
                                             activePaths: activePaths,
                                             learn: LearningStore.shared.boosts())
        let prevSel = Dictionary(discovered.map { ($0.id, $0.isSelected) },
                                 uniquingKeysWith: { a, _ in a })
        discovered = found.map { t in
            let s = TargetState(target: t)
            if let was = prevSel[t.id] { s.isSelected = was }
            return s
        }
        sweepDebug("🔭 keşif: \(found.count) aday — " + found.prefix(12).map { t in
            let flag = t.safety == .safe ? "🟢" : "🟠"
            let age = t.ageDays.map { "\($0)g" } ?? "?"
            return "\(t.name)[\(flag) \(age)\(t.inUse ? " 🔴kullanımda" : "")\(t.learned ? " 🧠öğrenildi" : "")]"
        }.joined(separator: ", "))
        sweepDebug("🧠 öğrenilen bilgi: \(LearningStore.shared.summary)")

        // Size seeds + discovered concurrently.
        let states = targets + discovered
        await withTaskGroup(of: (String, UInt64).self) { group in
            for st in states {
                let t = st.target
                group.addTask { (t.id, await Scanner.size(of: t.expandedPaths)) }
            }
            for await (id, size) in group {
                if let s = states.first(where: { $0.id == id }) { s.size = size }
            }
        }
        lastScan = Date()
        refreshFreeSpace()
    }

    // MARK: - Cleaning

    func cleanSelected() async {
        await clean(ids: allStates.filter { $0.isSelected && $0.size > 0 }.map(\.id))
    }

    func clean(ids: [String]) async {
        guard !isCleaning, !isScanning, !ids.isEmpty else { return }
        isCleaning = true
        defer { isCleaning = false }

        // Phase 3 — learning feedback from this round's discovered targets.
        for st in discovered where st.size > 0 {
            let path = st.target.expandedPaths.first ?? ""
            if ids.contains(st.id) {
                LearningStore.shared.recordCleaned(path: path)
            } else if !st.isSelected {
                LearningStore.shared.recordSkipped(path: path)
            }
        }

        let chosen = allStates.filter { ids.contains($0.id) }
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
            LearningStore.shared.noticeActivity(at: path)   // "did a cleaned cache come back?"
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
