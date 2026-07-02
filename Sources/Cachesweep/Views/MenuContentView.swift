import SwiftUI
import AppKit

struct MenuContentView: View {
    @Bindable var model: AppModel
    @State private var confirming = false
    @State private var pendingDiscovery: ActivityEntry?

    var body: some View {
        VStack(spacing: 0) {
            header
            if !model.fdaGranted { fdaBanner }
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
            titleVisibility: .visible
        ) {
            Button(L("discovery.confirm.clean"), role: .destructive) {
                if let e = pendingDiscovery { Task { await model.cleanDiscovered(e) } }
                pendingDiscovery = nil
            }
            Button(L("discovery.confirm.cancel"), role: .cancel) { pendingDiscovery = nil }
        } message: {
            Text(L("discovery.confirm.message"))
        }
    }

    // MARK: Live activity

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            HStack(spacing: DS.s2) {
                LiveDot()
                Text(L("live.title"))
                    .font(.caption2.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L("live.writingNow"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(model.activity.prefix(4)) { entry in
                ActivityRow(entry: entry,
                            onClean: entry.isKnown ? nil : { pendingDiscovery = entry })
            }
        }
        .padding(.horizontal, DS.s4)
        .padding(.vertical, DS.s3)
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
                    Text(model.isCleaning ? L("action.cleaning") : L("action.cleanSelected"))
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(model.selectedCount == 0 || model.isCleaning || model.isScanning)
            .confirmationDialog(
                Lf("clean.confirm.title", Int32(model.selectedCount), model.selectedReclaimable.fileSize),
                isPresented: $confirming, titleVisibility: .visible
            ) {
                Button(L("clean.confirm.clean"), role: .destructive) {
                    Task { await model.cleanSelected() }
                }
                Button(L("clean.confirm.cancel"), role: .cancel) {}
            } message: {
                Text(L("clean.confirm.message"))
            }
        }
        .padding(DS.s4)
    }

    private var subtitle: String {
        if model.isScanning { return L("subtitle.scanning") }
        if model.lastFreed > 0 {
            return Lf("subtitle.lastClean", model.lastFreed.fileSize, model.grandTotal.fileSize)
        }
        return Lf("subtitle.selected", Int32(model.selectedCount), model.grandTotal.fileSize)
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(TargetCategory.allCases, id: \.self) { cat in
                    let rows = rows(for: cat)
                    if !rows.isEmpty {
                        sectionHeader(cat.title)
                        ForEach(rows) { state in
                            CategoryRow(state: state) { state.isSelected.toggle() }
                            if state.id != rows.last?.id {
                                Divider().padding(.leading, DS.s4 + DS.iconTile + DS.s3)
                            }
                        }
                    }
                }
                systemSection
            }
            .padding(.vertical, DS.s1)
        }
    }

    private func rows(for cat: TargetCategory) -> [TargetState] {
        model.allStates
            .filter { $0.target.category == cat }
            .filter { !($0.target.isDiscovered && $0.size == 0) }   // transient empties add noise
            .sorted { a, b in
                if (a.size == 0) != (b.size == 0) { return b.size == 0 }  // empties last
                return a.size > b.size
            }
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
        }
        .padding(DS.s3)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.cardRadius))
        .padding(.horizontal, DS.s4)
        .padding(.bottom, DS.s3)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.s4)
            .padding(.top, DS.s3)
            .padding(.bottom, DS.s1)
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
                }
            }
            .padding(.horizontal, DS.s4)
            .padding(.top, DS.s4)
            .padding(.bottom, DS.s2)

            if model.systemScanned {
                ForEach(model.systemStates) { st in
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
