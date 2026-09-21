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
        // Pre-select clearly-safe caches, but never something in active use,
        // and never a proven boomerang (it refills right away — cleaning it
        // by default is churn). Learned caution places earn preselection:
        // the user has cleaned them before and they grew back — their own
        // judgement, recorded. Everything else cautious (leftovers, AI data,
        // runtimes) stays strictly opt-in.
        //
        // `.rebuildable` is excluded even when learned. Cleaning a project's
        // artifacts twice says the user is willing to do it, not that they
        // want it done for them — and the one thing this box must never do is
        // tick itself in front of a folder that costs a reinstall.
        self.isSelected = !target.inUse && !target.boomerang
            && target.safety != .rebuildable
            && (target.safety == .safe || (target.learned && !target.isLeftover))
    }
}

@MainActor
@Observable
final class AppModel {
    /// Seeds for *this* machine, rebuilt on every scan: what is installed
    /// here, plus what the user's own cleaning history says to check.
    var targets: [TargetState] = DeviceProfile.seeds().map(TargetState.init)
    var isScanning = false
    var isCleaning = false
    var lastScan: Date?
    var lastFreed: UInt64 = 0
    var freeSpace: UInt64 = 0

    /// Set when a clean action freed nothing because deletions failed —
    /// drives the error alert (silent failure looks like a dead button).
    var cleanError: String?

    // Smart discovery (Phase 1)
    var discovered: [TargetState] = []

    // Xcode simulator runtimes — system-owned assets no file scan can reach,
    // and usually the largest single reclaimable item on a developer's Mac.
    var runtimes: [TargetState] = []

    // System areas (root-owned, admin-gated)
    var systemStates: [TargetState] = RootCleaner.targets.map(TargetState.init)
    var systemScanned = false
    var isSystemWorking = false
    var snapshotCount = 0
    var snapshotsSelected = false

    // Invisible space (informational): swap, update staging, sealed system —
    // the part of a full disk no file scan can account for.
    var invisible: InvisibleSpaceReport?

    // Disks that hold caches but aren't being scanned. An empty result looks
    // the same whether there was nothing to clean or nobody looked there.
    var rootSuggestions: [RootAdvisor.Suggestion] = []

    // Full Disk Access — without it ~/Library scans silently return zeros.
    var fdaGranted = true

    /// Fired whenever totals change (scan/clean) — drives the menu-bar badge.
    @ObservationIgnored var onTotalsChanged: (() -> Void)?

    // Live tracking (FSEvents)
    var activity: [ActivityEntry] = []
    var isMonitoring = false
    @ObservationIgnored private var monitor: FileActivityMonitor?
    @ObservationIgnored private var monitoredPaths: [String] = []
    @ObservationIgnored private var dirty: Set<String> = []
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var resizePendingSince: Date?

    // Discovery result cache — Spotlight sweeps are not free, so reuse recent
    // results unless forced (refresh button) or invalidated (after cleaning).
    @ObservationIgnored private var discoveryCache: (key: String, at: Date, found: [CleanTarget])?

    /// Seeds (curated) + discovered (smart) + simulator runtimes — minus
    /// anything whose scan root is disabled or that the user excluded.
    var allStates: [TargetState] {
        // A target with no paths of its own (system-managed storage the owning
        // tool reports and removes) can't be filtered by path — keep it.
        (targets + discovered + runtimes).filter {
            $0.target.rawPaths.isEmpty || !allowedPaths($0.target).isEmpty
        }
    }

    /// A target's paths restricted to enabled scan roots and user exclusions.
    /// `externalScope` targets sit outside the home folder by definition
    /// (/var/folders, system asset storage), so the root filter would always
    /// reject them; only the user's exclusions apply there.
    private func allowedPaths(_ t: CleanTarget) -> [String] {
        let roots = AppSettings.shared.scanRoots
        let ex = AppSettings.shared.excludedPaths
        return t.expandedPaths.filter { p in
            (t.externalScope || roots.contains(where: { p == $0 || p.hasPrefix($0 + "/") }))
                && !ex.contains(where: { p == $0 || p.hasPrefix($0 + "/") })
        }
    }

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

    /// Selected rows that are not pure caches — project artifacts, leftovers,
    /// AI models, installers. The confirm sheet needs this: "18 items, 14.2
    /// GB" tells nobody whether pressing the button is free, and that is the
    /// only question being asked.
    var selectedNonCache: [TargetState] {
        allStates.filter { $0.isSelected && $0.size > 0 && !$0.target.safety.isPureCache }
    }

    var selectedNonCacheBytes: UInt64 {
        selectedNonCache.reduce(0) { $0 + $1.size }
    }

    /// Selected dormant-project rows — one per project, so this is a count of
    /// projects, not of folders.
    var selectedProjects: [TargetState] {
        allStates.filter { $0.isSelected && $0.size > 0 && $0.target.category == .projects }
    }

    /// Drop everything from the selection that is not a pure cache — the
    /// escape hatch on the confirm sheet, for when the breakdown turns out
    /// to be a surprise.
    func keepOnlySafeSelection() {
        for st in allStates where !st.target.safety.isPureCache { st.isSelected = false }
    }

    // MARK: - Scanning

    func scan(force: Bool = false) async {
        guard !isScanning, !isCleaning else { return }
        isScanning = true
        defer { isScanning = false }

        refreshFreeSpace()
        syncMonitoredRoots()
        probeFullDiskAccess()

        // Concurrent with the file scan — one diskutil/tmutil pass, no files touched.
        async let invisibleReport = InvisibleSpace.report()
        // Likewise: simctl reports its own sizes, so this costs one process
        // rather than a walk of storage the user can't even read.
        async let runtimeList = SimulatorRuntimes.list()

        // Re-profile the machine: a tool installed since the last scan should
        // show up, one that was uninstalled should stop being probed, and a
        // place the user has cleaned since then should now be offered.
        if force {
            ToolProbe.invalidate()
            RootAdvisor.invalidate()
        }
        await refreshSeeds()

        let roots = AppSettings.shared.scanRoots
        let excludes = AppSettings.shared.excludedPaths
        let cacheKey = roots.joined(separator: "|") + "‖" + excludes.joined(separator: "|")
            + "‖\(AppSettings.shared.projectIdleDays)"
            + (AppSettings.shared.skipProjectArtifacts ? "‖noproj" : "")

        // Smart discovery: find cache-like dirs beyond the curated seed list,
        // across the user's chosen scan roots and respecting their exclusions.
        // Recent results are reused (Spotlight sweep + stats aren't free).
        let found: [CleanTarget]
        if !force, let c = discoveryCache, c.key == cacheKey,
           Date().timeIntervalSince(c.at) < 180 {
            found = c.found
        } else {
            let seedPaths = Set(targets.flatMap { $0.target.expandedPaths })
            let activePaths = Set(activity
                .filter { Date().timeIntervalSince($0.lastChange) < 120 }
                .map(\.id))
            found = await Discovery.discover(roots: roots,
                                             excluding: seedPaths,
                                             excludes: excludes,
                                             activePaths: activePaths,
                                             learn: LearningStore.shared.boosts(),
                                             expect: LearningStore.shared.expectations(),
                                             hotSpots: LearningStore.shared.hotSpots(),
                                             boomerang: LearningStore.shared.boomerangKinds(),
                                             projectIdleDays: AppSettings.shared.projectIdleDays,
                                             skipProjects: AppSettings.shared.skipProjectArtifacts)
            discoveryCache = (cacheKey, Date(), found)
            sweepDebug("🔭 keşif: \(found.count) aday — " + found.prefix(12).map { t in
                let flag = t.safety == .safe ? "🟢" : "🟠"
                let age = t.ageDays.map { "\($0)g" } ?? "?"
                return "\(t.name)[\(flag) \(age)\(t.inUse ? " 🔴kullanımda" : "")\(t.learned ? " 🧠öğrenildi" : "")]"
            }.joined(separator: ", "))
            sweepDebug("🧠 öğrenilen bilgi: \(LearningStore.shared.summary)")
        }

        let prevSel = Dictionary(discovered.map { ($0.id, $0.isSelected) },
                                 uniquingKeysWith: { a, _ in a })
        discovered = found.map { t in
            let s = TargetState(target: t)
            if let was = prevSel[t.id] { s.isSelected = was }
            return s
        }

        // A learned place sitting inside something discovery found this scan
        // would count its bytes twice; the discovered parent already covers it.
        let discoveredPaths = discovered.flatMap { $0.target.expandedPaths }
        targets.removeAll { st in
            st.target.id.hasPrefix(DeviceProfile.learnedPrefix)
                && st.target.expandedPaths.contains { p in
                    discoveredPaths.contains { p.hasPrefix($0 + "/") }
                }
        }

        let prevRuntimeSel = Dictionary(runtimes.map { ($0.id, $0.isSelected) },
                                        uniquingKeysWith: { a, _ in a })
        runtimes = await runtimeList.map { rt in
            let s = TargetState(target: SimulatorRuntimes.target(for: rt))
            s.size = rt.size
            if let was = prevRuntimeSel[s.id] { s.isSelected = was }
            return s
        }
        if !runtimes.isEmpty {
            sweepDebug("📱 simülatör çalışma zamanları: " +
                       runtimes.map { "\($0.target.name)=\($0.size.fileSize)" }
                           .joined(separator: ", "))
        }

        // Size seeds + discovered concurrently (only settings-allowed paths).
        let states = targets + discovered
        await withTaskGroup(of: (String, UInt64).self) { group in
            for st in states {
                let id = st.target.id
                let paths = allowedPaths(st.target)
                group.addTask { (id, await Scanner.size(of: paths)) }
            }
            for await (id, size) in group {
                if let s = states.first(where: { $0.id == id }) { s.size = size }
            }
        }
        // Fresh measurements answer any open boomerang question ("did the
        // cleaned folder refill?") — single-path targets only, since a size
        // spread over several paths says nothing about one place.
        for st in states where st.target.rawPaths.count == 1 {
            if let p = st.target.expandedPaths.first {
                LearningStore.shared.noticeMeasuredSize(path: p, size: st.size)
            }
        }
        invisible = await invisibleReport
        rootSuggestions = await RootAdvisor.suggestions(
            roots: roots, excludes: excludes,
            dismissed: AppSettings.shared.dismissedRoots,
            probed: targets.flatMap { $0.target.expandedPaths },
            places: LearningStore.shared.knownPlaces())
        if !rootSuggestions.isEmpty {
            sweepDebug("🧭 taranmayan disk önerisi: " +
                       rootSuggestions.map { "\($0.name)(\($0.hits) iz\($0.named ? ", adı geçti" : ""))" }
                           .joined(separator: ", "))
        }
        lastScan = Date()
        refreshFreeSpace()
        onTotalsChanged?()
    }

    /// Rebuild the seed list from the machine as it is right now, keeping the
    /// selection of anything that survives.
    private func refreshSeeds() async {
        let probed = await ToolProbe.detect()
        let previous = Dictionary(targets.map { ($0.id, $0.isSelected) },
                                  uniquingKeysWith: { a, _ in a })
        let seeds = DeviceProfile.seeds(knownPlaces: LearningStore.shared.knownPlaces(),
                                        probed: probed)
        targets = seeds.map { t in
            let s = TargetState(target: t)
            if let was = previous[t.id] { s.isSelected = was }
            return s
        }
        let learned = seeds.filter { $0.id.hasPrefix(DeviceProfile.learnedPrefix) }
        sweepDebug("🖥️ cihaz profili: \(seeds.count) tohum · \(probed.count) araç kendi yolunu bildirdi"
                   + " · katalogdan \(seeds.count - probed.count - learned.count)"
                   + (learned.isEmpty ? "" : " · \(learned.count) öğrenilen yer"))
        if !probed.isEmpty {
            sweepDebug("🔧 " + probed.map { "\($0.name)→\($0.detail)" }.joined(separator: ", "))
        }
    }

    /// Start scanning a disk the advisor found, and rescan straight away so
    /// the user sees what was there all along.
    func acceptRootSuggestion(_ s: RootAdvisor.Suggestion) async {
        AppSettings.shared.addCustomFolder(s.path)
        rootSuggestions.removeAll { $0.path == s.path }
        discoveryCache = nil
        await scan(force: true)
    }

    func dismissRootSuggestion(_ s: RootAdvisor.Suggestion) {
        AppSettings.shared.dismissRootSuggestion(s.path)
        rootSuggestions.removeAll { $0.path == s.path }
    }

    /// TCC probe: a protected path readable ⇒ Full Disk Access is granted.
    private func probeFullDiskAccess() {
        let probe = NSHomeDirectory() + "/Library/Safari"
        fdaGranted = (try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil
    }

    // MARK: - Cleaning

    func cleanSelected() async {
        await clean(ids: allStates.filter { $0.isSelected && $0.size > 0 }.map(\.id))
    }

    func clean(ids: [String]) async {
        guard !isCleaning, !isScanning, !ids.isEmpty else { return }
        isCleaning = true
        defer { isCleaning = false }

        // Phase 3 — kinds the user deliberately left unselected: one skip per
        // kind per clean action, not per folder.
        let skippedSigs = Set(discovered
            .filter { $0.size > 0 && !$0.isSelected && !ids.contains($0.id) }
            .map { LearningStore.signature(forPath: $0.target.expandedPaths.first ?? "") })
        for sig in skippedSigs { LearningStore.shared.recordSkipped(signature: sig) }

        let chosen = allStates.filter { ids.contains($0.id) }
        for state in chosen { state.isCleaning = true }
        // Clean only paths inside enabled roots and not excluded in Settings.
        let payload = chosen.map { st -> CleanTarget in
            var t = st.target
            t.rawPaths = allowedPaths(st.target)
            return t
        }

        let results = await withTaskGroup(of: (String, CleanOutcome).self) { group -> [String: CleanOutcome] in
            for t in payload { group.addTask { (t.id, Cleaner.clean(t)) } }
            var out: [String: CleanOutcome] = [:]
            for await (id, o) in group { out[id] = o }
            return out
        }

        // Record "cleaned" only when bytes were actually freed (a permissions
        // failure should not count as evidence). The byte count travels with
        // it: how much a kind actually returns is what lets the next scan
        // rank it, and what makes a place worth probing again.
        for st in chosen where st.target.isDiscovered {
            let freed = results[st.id]?.freed ?? 0
            if freed > 0, let p = st.target.expandedPaths.first {
                LearningStore.shared.recordCleaned(path: p, freed: freed)
            }
        }

        for state in chosen { state.isCleaning = false }
        lastFreed = results.values.reduce(0) { $0 + $1.freed }
        var total = CleanOutcome()
        for o in results.values { total.merge(o) }
        surfaceIfFailed(total)
        discoveryCache = nil          // cleaned folders must not reappear from cache
        // Re-size only what was cleaned — a full scan here (every target plus
        // a discovery sweep) kept the spinner going long after deletion ended.
        // The popover triggers a full scan on next open anyway.
        await withTaskGroup(of: (String, UInt64).self) { group in
            for st in chosen where !st.target.rawPaths.isEmpty {
                let id = st.target.id
                let paths = allowedPaths(st.target)
                group.addTask { (id, await Scanner.size(of: paths)) }
            }
            for await (id, size) in group {
                chosen.first(where: { $0.id == id })?.size = size
            }
        }
        // Path-less targets have nothing to re-walk: ask the owning tool
        // again, so a refused deletion can't read as space freed.
        if chosen.contains(where: { $0.target.rawPaths.isEmpty }) {
            let live = await SimulatorRuntimes.list()
            for st in runtimes {
                st.size = live.first { "simrt:\($0.id)" == st.id }?.size ?? 0
            }
        }
        refreshFreeSpace()
        onTotalsChanged?()
    }

    // MARK: - System areas (admin)

    /// One password prompt: measure the root-owned allowlist.
    func scanSystemAreas() async {
        guard !isSystemWorking else { return }
        isSystemWorking = true
        defer { isSystemWorking = false }
        snapshotCount = await RootCleaner.snapshotCount()
        do {
            let sizes = try await RootCleaner.scanSizes()
            for st in systemStates { st.size = sizes[st.id] ?? 0 }
            systemScanned = true
            sweepDebug("🔒 sistem alanları: " + systemStates.map { "\($0.target.id)=\($0.size.fileSize)" }.joined(separator: ", ") + " · snapshots=\(snapshotCount)")
        } catch {
            // Cancelled prompt or failure — leave the section untouched.
        }
    }

    /// One password prompt: clean the selected root-owned targets
    /// (and, if chosen, all local Time Machine snapshots).
    func cleanSystemSelected() async {
        let chosen = systemStates.filter { $0.isSelected && $0.size > 0 }
        let wantSnapshots = snapshotsSelected && snapshotCount > 0
        guard !chosen.isEmpty || wantSnapshots, !isSystemWorking else { return }
        isSystemWorking = true
        defer { isSystemWorking = false }
        do {
            try await RootCleaner.clean(targets: chosen.map(\.target),
                                        deleteSnapshots: wantSnapshots)
            lastFreed = chosen.reduce(0) { $0 + $1.size }
            for st in chosen { st.size = 0; st.isSelected = false }
            if wantSnapshots { snapshotCount = 0; snapshotsSelected = false }
            refreshFreeSpace()
            onTotalsChanged?()
        } catch {
            // Cancelled prompt — nothing was deleted.
        }
    }

    // MARK: - Live tracking

    func startMonitoring() {
        syncMonitoredRoots()
    }

    /// Keep the FSEvents watcher aligned with the user's scan roots
    /// (home by default, plus any enabled disks/folders).
    private func syncMonitoredRoots() {
        let roots = AppSettings.shared.scanRoots
        guard Set(roots) != Set(monitoredPaths) else { return }
        monitor?.stop()
        monitor = nil
        monitoredPaths = roots
        guard !roots.isEmpty else { isMonitoring = false; return }
        let m = FileActivityMonitor(paths: roots) { [weak self] changed in
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
        // Debounce, but never postpone a flush by more than ~8s — otherwise a
        // long build (FSEvents batches every ~1.5s) would starve size updates.
        let now = Date()
        if resizePendingSince == nil { resizePendingSince = now }
        let overdue = now.timeIntervalSince(resizePendingSince ?? now) >= 8
        resizeTask?.cancel()
        resizeTask = Task { @MainActor [weak self] in
            if !overdue { try? await Task.sleep(for: .seconds(2)) }
            guard let self, !Task.isCancelled else { return }
            self.resizePendingSince = nil
            let buckets = self.dirty
            self.dirty.removeAll()
            for path in buckets {
                let size = await Scanner.size(of: [path])
                LearningStore.shared.noticeMeasuredSize(path: path, size: size)
                if let e = self.activity.first(where: { $0.id == path }) {
                    if !e.hasBaseline { e.baseline = size; e.hasBaseline = true }
                    e.size = size
                    ActivityHistory.shared.record(path: e.id, label: e.label, size: size)
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
        let outcome = await withTaskGroup(of: CleanOutcome.self) { group -> CleanOutcome in
            group.addTask { Cleaner.clean(t) }
            var total = CleanOutcome()
            for await o in group { total.merge(o) }
            return total
        }
        lastFreed = outcome.freed
        surfaceIfFailed(outcome)
        let newSize = await Scanner.size(of: [entry.id])
        entry.size = newSize
        entry.baseline = newSize
        refreshFreeSpace()
    }

    /// A clean that freed nothing but hit errors must not look like a dead
    /// button — tell the user what happened (usually missing permissions).
    private func surfaceIfFailed(_ outcome: CleanOutcome) {
        guard outcome.freed == 0, outcome.failedCount > 0 else { return }
        var message = Lf("clean.error.hint", Int32(outcome.failedCount))
        if let detail = outcome.firstError { message += "\n\n" + detail }
        cleanError = message
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
