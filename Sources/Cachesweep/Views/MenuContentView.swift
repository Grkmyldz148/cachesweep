import SwiftUI
import AppKit

struct MenuContentView: View {
    @Bindable var model: AppModel
    @State private var confirming = false
    @State private var pendingDiscovery: ActivityEntry?
    /// Live tracking is ambient status, not the popover's job — collapsed by
    /// default so the actionable list gets the space.
    @AppStorage("liveExpanded") private var liveExpanded = false
    /// Categories whose sub-megabyte rows are shown individually.
    @State private var expandedTiny: Set<TargetCategory> = []

    /// Below this, a row is noise on its own: grouped into one line per category.
    private static let tinyThreshold: UInt64 = 1_000_000

    var body: some View {
        VStack(spacing: 0) {
            header
            if !model.fdaGranted { fdaBanner }
            if let suggestion = model.rootSuggestions.first { rootBanner(suggestion) }
            Divider()
            if !model.activity.isEmpty {
                liveSection
                Divider()
            }
            list
            Divider()
            footer
        }
        .frame(width: DS.popoverWidth, height: DS.popoverHeight)
        .background(.regularMaterial)
        .confirmationDialog(
            pendingDiscovery.map { Lf("discovery.confirm.title", $0.label) } ?? "",
            isPresented: Binding(
                get: { pendingDiscovery != nil },
                set: { if !$0 { pendingDiscovery = nil } }
            ),
            titleVisibility: .visible,
            // `presenting:` snapshots the entry for the action closures —
            // reading `pendingDiscovery` there races with the isPresented
            // binding, which some macOS versions reset before the action runs.
            presenting: pendingDiscovery
        ) { entry in
            Button(L("discovery.confirm.clean"), role: .destructive) {
                Task { await model.cleanDiscovered(entry) }
            }
            Button(L("discovery.confirm.cancel"), role: .cancel) {}
        } message: { _ in
            Text(L("discovery.confirm.message"))
        }
        .alert(
            L("clean.error.title"),
            isPresented: Binding(
                get: { model.cleanError != nil },
                set: { if !$0 { model.cleanError = nil } }
            )
        ) {
            Button(L("welcome.ok"), role: .cancel) {}
        } message: {
            Text(model.cleanError ?? "")
        }
    }

    // MARK: Live activity

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { liveExpanded.toggle() }
            } label: {
                HStack(spacing: DS.s2) {
                    LiveDot()
                    Text(L("live.title"))
                        .font(.caption2.weight(.semibold))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                    Text(verbatim: "· " + Lf("live.locations", Int32(model.activity.count)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !liveExpanded, sessionGrowth > 0 {
                        Text(Lf("live.session", sessionGrowth.fileSize))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L("live.writingNow"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(liveExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if liveExpanded {
                ForEach(model.activity.prefix(4)) { entry in
                    ActivityRow(entry: entry,
                                onClean: entry.isKnown ? nil : { pendingDiscovery = entry })
                }
            }
        }
        .padding(.horizontal, DS.s4)
        .padding(.vertical, DS.s3)
    }

    /// Net growth across every tracked location this session — the collapsed
    /// section's one-line summary.
    private var sessionGrowth: UInt64 {
        UInt64(model.activity.map { max(0, $0.delta) }.reduce(0, +))
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: DS.s3) {
            HStack {
                Label("Cachesweep", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                if model.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await model.scan(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(L("action.rescan"))
                }
            }

            VStack(spacing: DS.s1) {
                Text(model.selectedReclaimable.fileSize)
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if model.grandTotal > 0 { selectionGauge }
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.s1)

            Button {
                confirming = true
            } label: {
                HStack(spacing: DS.s2) {
                    if model.isCleaning { ProgressView().controlSize(.small) }
                    Text(ctaTitle)
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .prominentActionStyle()
            .disabled(model.selectedCount == 0 || model.isCleaning || model.isScanning)
            .confirmationDialog(
                Lf("clean.confirm.title", Int32(model.selectedCount), model.selectedReclaimable.fileSize),
                isPresented: $confirming, titleVisibility: .visible
            ) {
                Button(L("clean.confirm.clean"), role: .destructive) {
                    Task { await model.cleanSelected() }
                }
                // The escape hatch lives here rather than in the header,
                // because here is where the breakdown is read and here is
                // where it can still be a surprise.
                if !model.selectedNonCache.isEmpty {
                    let safeBytes = model.selectedReclaimable - model.selectedNonCacheBytes
                    if safeBytes > 0 {
                        Button(Lf("clean.confirm.safeOnly", safeBytes.fileSize)) {
                            model.keepOnlySafeSelection()
                            Task { await model.cleanSelected() }
                        }
                    }
                }
                Button(L("clean.confirm.cancel"), role: .cancel) {}
            } message: {
                Text(confirmMessage)
            }
        }
        .padding(DS.s4)
    }

    /// "18 items, 14.2 GB" answers the wrong question. What the user is
    /// actually deciding is whether pressing this costs them anything, so the
    /// sheet separates the bytes that come back on their own from the ones
    /// that come back only when they run a command.
    private var confirmMessage: String {
        // One row per project, so this counts projects and not the folders
        // they are made of — which is the number the sentence claims.
        let projects = model.selectedProjects
        guard !projects.isEmpty else { return L("clean.confirm.message") }
        let bytes = projects.reduce(UInt64(0)) { $0 + $1.size }
        return L("clean.confirm.message") + "\n\n"
            + Lf("clean.confirm.rebuildable", bytes.fileSize, Int32(projects.count))
    }

    private var subtitle: String {
        if model.isScanning { return L("subtitle.scanning") }
        if model.lastFreed > 0 {
            return Lf("subtitle.lastClean", model.lastFreed.fileSize, model.grandTotal.fileSize)
        }
        return Lf("subtitle.selected", Int32(model.selectedCount), model.grandTotal.fileSize)
    }

    /// The button says what it will do: "Clean 9.2 GB", not just "Clean".
    private var ctaTitle: String {
        if model.isCleaning { return L("action.cleaning") }
        if model.selectedReclaimable > 0 {
            return Lf("action.cleanAmount", model.selectedReclaimable.fileSize)
        }
        return L("action.cleanSelected")
    }

    /// Selected-of-found at a glance. The headline number alone kept reading
    /// as "this is all the app found" — the bar shows how much more is there.
    private var selectionGauge: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule().fill(Color.accentColor)
                    .frame(width: gaugeRatio == 0 ? 0 : max(4, geo.size.width * gaugeRatio))
            }
        }
        .frame(width: 220, height: 4)
        .padding(.vertical, 2)
        .animation(.easeInOut(duration: 0.25), value: gaugeRatio)
    }

    private var gaugeRatio: CGFloat {
        guard model.grandTotal > 0 else { return 0 }
        return min(1, CGFloat(Double(model.selectedReclaimable) / Double(model.grandTotal)))
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(TargetCategory.allCases, id: \.self) { cat in
                    let all = rows(for: cat)
                    let tiny = all.filter { $0.size < Self.tinyThreshold }
                    // Grouping one or two rows saves nothing — inline those.
                    let grouped = tiny.count >= 3
                    let inline = grouped ? all.filter { $0.size >= Self.tinyThreshold } : all
                    if !all.isEmpty {
                        sectionHeader(cat.title, rows: all)
                        ForEach(inline) { state in
                            CategoryRow(state: state) { state.isSelected.toggle() }
                            if state.id != inline.last?.id || grouped {
                                Divider().padding(.leading, DS.s4 + DS.iconTile + DS.s3)
                            }
                        }
                        if grouped {
                            tinyRow(cat, rows: tiny)
                            if expandedTiny.contains(cat) {
                                ForEach(tiny) { state in
                                    CategoryRow(state: state) { state.isSelected.toggle() }
                                }
                            }
                        }
                    }
                }
                systemSection
                if let inv = model.invisible, inv.hiddenTotal > 0 {
                    invisibleSection(inv)
                }
            }
            .padding(.vertical, DS.s1)
        }
        // Rows sliding under the header used to cut off hard; ease them out.
        .mask(
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 6)
                Color.black
            }
        )
    }

    private func rows(for cat: TargetCategory) -> [TargetState] {
        model.allStates
            .filter { $0.target.category == cat }
            .filter { $0.size > 0 }   // empties aren't options — don't render them
            .sorted { $0.size > $1.size }
    }

    /// Sub-megabyte rows drowned the list one 4 kB line at a time — collapse
    /// them into a single row per category with one collective checkbox.
    private func tinyRow(_ cat: TargetCategory, rows: [TargetState]) -> some View {
        let total = rows.reduce(UInt64(0)) { $0 + $1.size }
        let allOn = rows.allSatisfy(\.isSelected)
        let noneOn = !rows.contains(where: \.isSelected)
        let expanded = expandedTiny.contains(cat)
        return HStack(spacing: DS.s3) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if expanded { expandedTiny.remove(cat) } else { expandedTiny.insert(cat) }
                }
            } label: {
                HStack(spacing: DS.s3) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: DS.iconTile, height: DS.iconTile)
                        .background(Color.secondary.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: DS.iconRadius))
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: DS.s1) {
                            Text(Lf("tiny.title", Int32(rows.count)))
                                .font(.callout.weight(.medium))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                        Text(L("tiny.detail"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: DS.s2)
                    Text(total.fileSize)
                        .font(.callout.monospacedDigit())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                switch bulkAction(for: rows) {
                case .safe: for r in rows where r.target.safety.isPureCache { r.isSelected = true }
                case .all:  for r in rows { r.isSelected = true }
                case .none: for r in rows { r.isSelected = false }
                }
            } label: {
                Image(systemName: allOn ? "checkmark.circle.fill"
                                 : noneOn ? "circle" : "minus.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(noneOn ? Color.secondary.opacity(0.5) : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(L("section.selectAll"))
        }
        .padding(.vertical, DS.s2)
        .padding(.horizontal, DS.s4)
    }

    // MARK: Full Disk Access banner

    private var fdaBanner: some View {
        HStack(spacing: DS.s2) {
            Image(systemName: "exclamationmark.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("fda.title")).font(.caption.weight(.semibold))
                Text(L("fda.message")).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.s1)
            Button(L("fda.open")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
            .secondaryActionStyle()
        }
        .padding(DS.s3)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.cardRadius))
        .padding(.horizontal, DS.s4)
        .padding(.bottom, DS.s3)
    }

    // MARK: Unscanned disk

    /// A disk full of projects that nothing is looking at. Without this the
    /// app reports "nothing found" and the user has no way to know the scan
    /// was pointed at the wrong place.
    private func rootBanner(_ s: RootAdvisor.Suggestion) -> some View {
        HStack(spacing: DS.s2) {
            Image(systemName: "externaldrive.badge.questionmark")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(Lf("root.suggest.title", s.name)).font(.caption.weight(.semibold))
                Text(Lf("root.suggest.message", Int32(s.hits)))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.s1)
            Button(L("root.suggest.add")) {
                Task { await model.acceptRootSuggestion(s) }
            }
            .controlSize(.small)
            .secondaryActionStyle()
            Button {
                model.dismissRootSuggestion(s)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(.secondary)
            .help(L("root.suggest.dismiss"))
        }
        .padding(DS.s3)
        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.cardRadius))
        .padding(.horizontal, DS.s4)
        .padding(.bottom, DS.s3)
    }

    /// What a section's bulk control does next.
    ///
    /// One toggle that swept up every row in the section is what made this
    /// button dangerous: in a mixed section it selected pure caches and a
    /// project's dependencies with the same click, so "select all" could
    /// never be pressed without reading every line first. Now the safe rows
    /// go in on their own, and the rest is a second, deliberate press.
    private enum Bulk { case safe, all, none }

    private func bulkAction(for rows: [TargetState]) -> Bulk {
        if rows.allSatisfy(\.isSelected) { return .none }
        let safe = rows.filter { $0.target.safety.isPureCache }
        if !safe.isEmpty, !safe.allSatisfy(\.isSelected) { return .safe }
        return .all
    }

    private func sectionHeader(_ title: String, rows: [TargetState] = []) -> some View {
        HStack(spacing: DS.s2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Spacer()
            if !rows.isEmpty {
                // A worded control, not a circle: the old header circle read
                // as one more row checkbox and its effect was a surprise.
                let action = bulkAction(for: rows)
                let mixed = rows.contains { $0.target.safety.isPureCache }
                    && rows.contains { !$0.target.safety.isPureCache }
                Button(bulkLabel(action, mixed: mixed)) {
                    switch action {
                    case .safe: for r in rows where r.target.safety.isPureCache { r.isSelected = true }
                    case .all:  for r in rows { r.isSelected = true }
                    case .none: for r in rows { r.isSelected = false }
                    }
                }
                .buttonStyle(.plain)
                .font(.caption2.weight(.medium))
                .foregroundStyle(action == .all && mixed ? Color.orange : Color.accentColor)
                .help(L("section.selectAll"))
            }
        }
        .padding(.horizontal, DS.s4)
        .padding(.top, DS.s3)
        .padding(.bottom, DS.s1)
    }

    private func bulkLabel(_ action: Bulk, mixed: Bool) -> String {
        switch action {
        case .none: return L("section.deselectAll")
        // In a section that is all one tier there is nothing to stage, so the
        // button keeps its plain wording.
        case .safe: return mixed ? L("section.selectSafe") : L("section.selectAllBtn")
        case .all:  return mixed ? L("section.selectRisky") : L("section.selectAllBtn")
        }
    }

    // MARK: System areas (admin-gated)

    private var systemSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.s2) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(L("system.title"))
                    .font(.caption2.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isSystemWorking {
                    ProgressView().controlSize(.small)
                } else if !model.systemScanned {
                    Button(L("system.scan")) {
                        Task { await model.scanSystemAreas() }
                    }
                    .controlSize(.small)
                    .secondaryActionStyle()
                }
            }
            .padding(.horizontal, DS.s4)
            .padding(.top, DS.s4)
            .padding(.bottom, DS.s2)

            if model.systemScanned {
                ForEach(model.systemStates.filter { $0.size > 0 }) { st in
                    CategoryRow(state: st) { st.isSelected.toggle() }
                }
                if model.snapshotCount > 0 { snapshotRow }
                if model.systemStates.contains(where: { $0.isSelected && $0.size > 0 })
                    || (model.snapshotsSelected && model.snapshotCount > 0) {
                    Button {
                        Task { await model.cleanSystemSelected() }
                    } label: {
                        Text(L("system.clean"))
                            .frame(maxWidth: .infinity)
                    }
                    .secondaryActionStyle()
                    .disabled(model.isSystemWorking)
                    .padding(.horizontal, DS.s4)
                    .padding(.vertical, DS.s2)
                }
            } else if !model.isSystemWorking {
                Text(L("system.explain"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.s4)
                    .padding(.bottom, DS.s2)
            }
        }
    }

    /// Time Machine local snapshots — count-based row (sizes aren't reported).
    private var snapshotRow: some View {
        Button {
            model.snapshotsSelected.toggle()
        } label: {
            HStack(spacing: DS.s3) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: DS.iconTile, height: DS.iconTile)
                    .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: DS.iconRadius))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("sys.snapshots"))
                        .font(.callout.weight(.medium))
                    Text(verbatim: "tmutil · \(model.snapshotCount)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: DS.s2)
                Image(systemName: model.snapshotsSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(model.snapshotsSelected ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .padding(.vertical, DS.s2)
            .padding(.horizontal, DS.s4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Invisible space (informational)

    /// Space no file scan can account for: swap, update staging, the sealed
    /// system. Nothing here is user-deletable, so the rows carry no checkbox —
    /// the section exists to answer "the disk is full but nothing was found".
    private func invisibleSection(_ inv: InvisibleSpaceReport) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.s2) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(L("invisible.title"))
                    .font(.caption2.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(inv.hiddenTotal.fileSize)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .help(L("invisible.help"))
            .padding(.horizontal, DS.s4)
            .padding(.top, DS.s4)
            .padding(.bottom, DS.s2)

            if inv.pendingUpdate { pendingUpdateBanner }

            if inv.swapUsed > 0 {
                infoRow(symbol: "memorychip", tint: .purple,
                        name: L("invisible.swap"),
                        detail: L("invisible.swap.detail"),
                        size: inv.swapUsed)
            }
            if inv.bootUsed > 0 {
                infoRow(symbol: "square.and.arrow.down", tint: .blue,
                        name: L("invisible.boot"),
                        detail: L("invisible.boot.detail"),
                        size: inv.bootUsed)
            }
            if inv.systemUsed > 0 {
                infoRow(symbol: "apple.logo", tint: .gray,
                        name: L("invisible.system"),
                        detail: L("invisible.system.detail"),
                        size: inv.systemUsed)
            }
            if inv.purgeable > 1_000_000_000 {
                infoRow(symbol: "trash.slash", tint: .teal,
                        name: L("invisible.purgeable"),
                        detail: L("invisible.purgeable.detail"),
                        size: inv.purgeable)
            }
        }
    }

    /// A macOS update was downloaded and staged but never installed — until it
    /// finishes it pins undeletable snapshots and Preboot staging. The one
    /// thing the user can actually do about invisible space, so it gets a CTA.
    private var pendingUpdateBanner: some View {
        HStack(spacing: DS.s2) {
            Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("invisible.pending.title")).font(.caption.weight(.semibold))
                Text(L("invisible.pending.message")).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.s1)
            Button(L("invisible.pending.open")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
            .secondaryActionStyle()
        }
        .padding(DS.s3)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.cardRadius))
        .padding(.horizontal, DS.s4)
        .padding(.bottom, DS.s2)
    }

    /// Read-only counterpart of CategoryRow: icon tile + name + size, no
    /// selection circle, no reveal (these paths are not browsable folders).
    private func infoRow(symbol: String, tint: Color,
                         name: String, detail: String, size: UInt64) -> some View {
        HStack(spacing: DS.s3) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: DS.iconTile, height: DS.iconTile)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: DS.iconRadius))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout.weight(.medium))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.s2)
            Text(size.fileSize)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, DS.s2)
        .padding(.horizontal, DS.s4)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: DS.s2) {
            Image(systemName: "internaldrive")
            Text(Lf("footer.free", model.freeSpace.fileSize))
            Spacer()
            Menu {
                Button(L("menu.settings")) {
                    NotificationCenter.default.post(name: .showSettings, object: nil)
                }
                Button(L("menu.history")) {
                    NotificationCenter.default.post(name: .showHistory, object: nil)
                }
                Divider()
                if AppUpdater.shared.isAvailable {
                    Button(L("menu.checkUpdates")) { AppUpdater.shared.checkForUpdates() }
                    Divider()
                }
                Button(L("menu.quit")) { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.s4)
        .padding(.vertical, DS.s3)
    }
}
