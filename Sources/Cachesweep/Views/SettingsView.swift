import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    private let settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("tr", "Türkçe"), ("de", "Deutsch"), ("fr", "Français"),
        ("es", "Español"), ("it", "Italiano"), ("pt-BR", "Português (Brasil)"),
        ("nl", "Nederlands"), ("ru", "Русский"), ("ja", "日本語"), ("ko", "한국어"),
        ("zh-Hans", "简体中文"), ("ar", "العربية"),
    ]

    var body: some View {
        Form {
            Section {
                Picker(selection: Binding(
                    get: { settings.language },
                    set: { settings.setLanguage($0) }
                )) {
                    Text(L("settings.language.system")).tag("system")
                    ForEach(Self.languages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.menu)

                // Backed by @State — a computed binding never invalidates the
                // view, so the toggle stayed off even after a successful
                // register(). Re-read the real status after each change.
                Toggle(L("settings.launchAtLogin"), isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            sweepDebug("login item: \(error)")
                        }
                        let status = SMAppService.mainApp.status
                        launchAtLogin = status == .enabled
                        // macOS queued it pending user approval — take them there.
                        if on, status == .requiresApproval {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                ))
                .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
            } header: {
                Text(L("settings.language"))
            }

            Section {
                locationRow(path: NSHomeDirectory(), label: L("settings.homeLabel"),
                            icon: "house", removable: false)
                ForEach(volumes, id: \.path) { v in
                    locationRow(path: v.path, label: v.name, icon: "externaldrive", removable: false)
                }
                ForEach(settings.customFolders, id: \.self) { folder in
                    locationRow(path: folder, label: (folder as NSString).lastPathComponent,
                                icon: "folder", removable: true)
                }
                Button {
                    if let p = pickFolder() { settings.addCustomFolder(p) }
                } label: {
                    Label(L("settings.addFolder"), systemImage: "plus")
                }
            } header: {
                Text(L("settings.scanLocations"))
            } footer: {
                Text(L("settings.scanLocations.footer"))
            }

            Section {
                if settings.excludedPaths.isEmpty {
                    Text(L("settings.noExclusions")).foregroundStyle(.secondary)
                }
                ForEach(settings.excludedPaths, id: \.self) { path in
                    HStack(spacing: 10) {
                        Image(systemName: "nosign").foregroundStyle(.red).frame(width: 18)
                        MarqueeText(text: abbrev(path))
                        Spacer()
                        Button(role: .destructive) { settings.removeExclusion(path) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless).foregroundStyle(.red)
                        .help(L("settings.removeFolder"))
                    }
                }
                Button {
                    if let p = pickFolder() { settings.addExclusion(p) }
                } label: {
                    Label(L("settings.addFolder"), systemImage: "plus")
                }
            } header: {
                Text(L("settings.exclusions"))
            } footer: {
                Text(L("settings.exclusions.footer"))
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 580)
    }

    private var volumes: [(name: String, path: String)] {
        AppSettings.mountedVolumes().filter { $0.path != "/" }
    }

    @ViewBuilder
    private func locationRow(path: String, label: String, icon: String, removable: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.blue).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                MarqueeText(text: abbrev(path))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if removable {
                Button(role: .destructive) { settings.removeCustomFolder(path) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless).foregroundStyle(.red)
                .help(L("settings.removeFolder"))
            }
            Toggle("", isOn: Binding(
                get: { settings.isScanned(path) },
                set: { settings.setScanned(path, $0) }
            ))
            .labelsHidden()
        }
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
        panel.prompt = L("settings.chooseFolder.prompt")
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
