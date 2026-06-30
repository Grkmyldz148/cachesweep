import SwiftUI
import AppKit

struct SettingsView: View {
    private let settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                ForEach(settings.availableRoots()) { root in
                    rootRow(root)
                }
                Button {
                    if let p = pickFolder() { settings.addCustomFolder(p) }
                } label: {
                    Label("Klasör Ekle…", systemImage: "plus")
                }
            } header: {
                Text("Taranacak Yerler")
            } footer: {
                Text("Akıllı tarama yalnızca açık olan disk ve klasörlerde cache arar.")
            }

            Section {
                if settings.excludedPaths.isEmpty {
                    Text("Hariç tutulan yok").foregroundStyle(.secondary)
                }
                ForEach(settings.excludedPaths, id: \.self) { path in
                    HStack(spacing: 10) {
                        Image(systemName: "nosign").foregroundStyle(.red).frame(width: 18)
                        Text(abbrev(path)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { settings.removeExclusion(path) } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                Button {
                    if let p = pickFolder() { settings.addExclusion(p) }
                } label: {
                    Label("Klasör Ekle…", systemImage: "plus")
                }
            } header: {
                Text("Hariç Tutulanlar (asla taranmaz)")
            } footer: {
                Text("Buradaki klasör ve diskler, açık olsalar bile taranmaz.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
    }

    @ViewBuilder
    private func rootRow(_ root: AppSettings.Root) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: root)).foregroundStyle(.blue).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(root.label)
                Text(abbrev(root.path))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if root.removable {
                Button { settings.removeCustomFolder(root.path) } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            Toggle("", isOn: Binding(
                get: { settings.isScanned(root.path) },
                set: { settings.setScanned(root.path, $0) }
            ))
            .labelsHidden()
        }
    }

    private func icon(for root: AppSettings.Root) -> String {
        if root.path == NSHomeDirectory() { return "house" }
        if root.removable { return "folder" }
        return "externaldrive"
    }

    private func abbrev(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func pickFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Seç"
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
