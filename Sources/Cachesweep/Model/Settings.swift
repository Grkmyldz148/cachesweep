import Foundation
import Observation
import AppKit

extension Notification.Name {
    static let showSettings = Notification.Name("cachesweep.showSettings")
}

/// User-configurable scan locations and exclusions, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let store = UserDefaults.standard
    private enum Key {
        static let roots = "scanRoots"
        static let custom = "customFolders"
        static let excluded = "excludedPaths"
        static let language = "language"
    }

    /// Locations the smart scanner searches.
    var scanRoots: [String]
    /// User-added folders (also appear as toggleable roots).
    var customFolders: [String]
    /// Folders/disks that must never be scanned (veto).
    var excludedPaths: [String]
    /// Manual language override, or "system" to follow the device.
    var language: String

    private init() {
        scanRoots = store.stringArray(forKey: Key.roots) ?? [NSHomeDirectory()]
        customFolders = store.stringArray(forKey: Key.custom) ?? []
        excludedPaths = store.stringArray(forKey: Key.excluded) ?? []
        language = store.string(forKey: Key.language) ?? "system"
        Localizer.apply(language == "system" ? nil : language)
    }

    func setLanguage(_ code: String) {
        language = code
        Localizer.apply(code == "system" ? nil : code)
        save()
    }

    private func save() {
        store.set(scanRoots, forKey: Key.roots)
        store.set(customFolders, forKey: Key.custom)
        store.set(excludedPaths, forKey: Key.excluded)
        store.set(language, forKey: Key.language)
    }

    // MARK: Scan roots

    func isScanned(_ path: String) -> Bool { scanRoots.contains(path) }

    func setScanned(_ path: String, _ on: Bool) {
        if on {
            if !scanRoots.contains(path) { scanRoots.append(path) }
        } else {
            scanRoots.removeAll { $0 == path }
        }
        save()
    }

    func addCustomFolder(_ path: String) {
        if !customFolders.contains(path) { customFolders.append(path) }
        if !scanRoots.contains(path) { scanRoots.append(path) }
        save()
    }

    func removeCustomFolder(_ path: String) {
        customFolders.removeAll { $0 == path }
        scanRoots.removeAll { $0 == path }
        save()
    }

    // MARK: Exclusions

    func addExclusion(_ path: String) {
        if !excludedPaths.contains(path) { excludedPaths.append(path) }
        save()
    }

    func removeExclusion(_ path: String) {
        excludedPaths.removeAll { $0 == path }
        save()
    }

    // MARK: Mounted volumes

    static func mountedVolumes() -> [(name: String, path: String)] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.volumeIsBrowsable == true else { return nil }
            return (v?.volumeName ?? url.lastPathComponent, url.path)
        }
    }
}
