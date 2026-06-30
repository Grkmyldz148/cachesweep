import SwiftUI
import AppKit

struct MenuContentView: View {
    @Bindable var model: AppModel
    @State private var confirming = false
    @State private var pendingDiscovery: ActivityEntry?

    var body: some View {
        VStack(spacing: 0) {
            header
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
            pendingDiscovery.map { "\($0.label) içeriği temizlensin mi?" } ?? "",
            isPresented: Binding(
                get: { pendingDiscovery != nil },
                set: { if !$0 { pendingDiscovery = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("İçeriği Temizle", role: .destructive) {
                if let e = pendingDiscovery { Task { await model.cleanDiscovered(e) } }
                pendingDiscovery = nil
            }
            Button("Vazgeç", role: .cancel) { pendingDiscovery = nil }
        } message: {
            Text("Otomatik keşfedilen bir konum. İçeriği kalıcı olarak silinecek.")
        }
    }

    // MARK: Live activity

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            HStack(spacing: DS.s2) {
                LiveDot()
                Text("CANLI AKTİVİTE")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("şu an yazılıyor")
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
                        Task { await model.scan() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Yeniden tara")
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
                    Text(model.isCleaning ? "Temizleniyor…" : "Seçilenleri Temizle")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(model.selectedCount == 0 || model.isCleaning || model.isScanning)
            .confirmationDialog(
                "\(model.selectedCount) kategori (\(model.selectedReclaimable.fileSize)) kalıcı olarak silinsin mi?",
                isPresented: $confirming, titleVisibility: .visible
            ) {
                Button("Temizle", role: .destructive) {
                    Task { await model.cleanSelected() }
                }
                Button("Vazgeç", role: .cancel) {}
            } message: {
                Text("Bunlar yeniden oluşan önbelleklerdir. İşlem geri alınamaz.")
            }
        }
        .padding(DS.s4)
    }

    private var subtitle: String {
        if model.isScanning { return "Taranıyor…" }
        if model.lastFreed > 0 {
            return "Son temizlik: \(model.lastFreed.fileSize) açıldı · \(model.grandTotal.fileSize) bulundu"
        }
        return "\(model.selectedCount) seçili · toplam \(model.grandTotal.fileSize) bulundu"
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sortedTargets) { state in
                    CategoryRow(state: state) { state.isSelected.toggle() }
                    if state.id != sortedTargets.last?.id {
                        Divider().padding(.leading, DS.s4 + DS.iconTile + DS.s3)
                    }
                }
            }
            .padding(.vertical, DS.s1)
        }
    }

    private var sortedTargets: [TargetState] {
        model.targets.sorted { a, b in
            if (a.size == 0) != (b.size == 0) { return a.size > b.size } // empties to bottom
            return a.size > b.size
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: DS.s2) {
            Image(systemName: "internaldrive")
            Text("\(model.freeSpace.fileSize) boş")
            Spacer()
            Menu {
                if AppUpdater.shared.isAvailable {
                    Button("Güncellemeleri Denetle…") { AppUpdater.shared.checkForUpdates() }
                    Divider()
                }
                Button("Cachesweep’ten Çık") { NSApplication.shared.terminate(nil) }
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
