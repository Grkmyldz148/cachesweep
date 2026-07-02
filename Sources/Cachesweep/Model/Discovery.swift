import Foundation
import AppKit

/// Phase 1 smart discovery.
///
/// Instead of a flat hardcoded list, we *find* cache-like directories via
/// Spotlight (project manifests + `CACHEDIR.TAG`) plus the system Caches dir,
/// then score each candidate with signals (regenerability, backup-exclusion,
/// name, location). The curated `CleanTarget.all` stays as a high-confidence
/// seed; this adds everything else.
enum Discovery {

    // MARK: Knowledge

    /// manifest filename → regenerable sibling dirs (proof: the manifest can rebuild them).
    static let manifestMap: [String: [String]] = [
        "package.json":     ["node_modules", ".next", ".nuxt", ".turbo", ".parcel-cache", ".svelte-kit"],
        "Cargo.toml":       ["target"],
        "Podfile":          ["Pods"],
        "pubspec.yaml":     [".dart_tool"],
        "build.gradle":     ["build", ".gradle"],
        "build.gradle.kts": ["build", ".gradle"],
        "pyproject.toml":   [".venv", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache"],
        "composer.json":    ["vendor"],
    ]

    static let cacheNameTokens: Set<String> = [
        "cache", "caches", ".cache", "tmp", "temp", "build", "dist", "target",
        "node_modules", "deriveddata", "__pycache__", ".gradle", "pods",
        ".next", ".nuxt", ".turbo", ".venv", "vendor", "logs", "cacheddata",
    ]

    // MARK: Public entry

    /// Discover and classify cache-like dirs across the user's chosen `roots`.
    /// `seedPaths` (curated list) and `excludes` (user opt-outs) are skipped.
    static func discover(roots: [String], excluding seedPaths: Set<String>,
                         excludes: [String], activePaths: Set<String>,
                         learn: [String: Double]) async -> [CleanTarget] {
        await Task.detached(priority: .utility) {
            run(roots: roots, excluding: seedPaths, excludes: excludes,
                activePaths: activePaths, learn: learn)
        }.value
    }

    // MARK: Implementation

    private static func run(roots: [String], excluding seedPaths: Set<String>,
                            excludes: [String], activePaths: Set<String>,
                            learn: [String: Double]) -> [CleanTarget] {
        let fm = FileManager()
        let home = NSHomeDirectory()
        var seen = Set<String>()
        var scored: [(target: CleanTarget, score: Double)] = []

        func consider(_ path: String, derived: Bool, hasTag: Bool, appleCaches: Bool) {
            guard !seen.contains(path) else { return }
            // Skip anything a curated seed already covers (exact or nested),
            // otherwise its bytes would be counted and cleaned twice.
            guard !seedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return }
            guard isDir(path, fm) else { return }
            let age = ageInDays(path, fm)
            let active = isActive(path, activePaths)
            let sig = (path as NSString).lastPathComponent.lowercased()
            let learnBoost = learn[sig] ?? 0
            guard let v = classify(path, derived: derived, hasTag: hasTag, appleCaches: appleCaches,
                                   excludes: excludes, ageDays: age, active: active, learnBoost: learnBoost) else { return }
            seen.insert(path)
            scored.append((makeTarget(path, v, ageDays: age, inUse: active, learned: learnBoost > 0), v.score))
        }

        for root in roots {
            // 1) CACHEDIR.TAG — the definitive "I am a cache" marker.
            for tag in mdfind(["-onlyin", root, "-name", "CACHEDIR.TAG"]).prefix(2000) {
                guard (tag as NSString).lastPathComponent == "CACHEDIR.TAG" else { continue }
                consider((tag as NSString).deletingLastPathComponent, derived: true, hasTag: true, appleCaches: false)
            }

            // 2) Manifest-derived: a manifest proves its sibling outputs are regenerable.
            for (manifest, derivedDirs) in manifestMap {
                for hit in mdfind(["-onlyin", root, "-name", manifest]).prefix(4000) {
                    guard (hit as NSString).lastPathComponent == manifest else { continue }
                    let dir = (hit as NSString).deletingLastPathComponent
                    if dir.contains("/node_modules/") || dir.contains("/.build/")
                        || dir.contains("/vendor/") || dir.contains("/Pods/") { continue }
                    for d in derivedDirs {
                        consider(dir + "/" + d, derived: true, hasTag: false, appleCaches: false)
                    }
                }
            }
        }

        // 3) ~/Library/Caches/* — only when the home root is enabled.
        if roots.contains(home) {
            let cachesRoot = "\(home)/Library/Caches"
            if let subs = try? fm.contentsOfDirectory(atPath: cachesRoot) {
                for s in subs where !s.hasPrefix(".") {
                    consider("\(cachesRoot)/\(s)", derived: false, hasTag: false, appleCaches: true)
                }
            }
        }

        // 4) Leftovers from uninstalled apps — the opaque bulk of "System Data".
        //    Bundle-id-named folders in Application Support / Containers whose
        //    app no longer exists anywhere on the system.
        if roots.contains(home) {
            let installed = installedBundleIDs()
            for base in ["\(home)/Library/Application Support", "\(home)/Library/Containers"] {
                guard let subs = try? fm.contentsOfDirectory(atPath: base) else { continue }
                var leftovers: [(path: String, age: Int?)] = []
                for s in subs where isBundleIDShaped(s) && !s.hasPrefix("com.apple.") {
                    let path = "\(base)/\(s)"
                    guard !seen.contains(path),
                          !seedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }),
                          !denylisted(path, excludes: excludes),
                          isDir(path, fm),
                          !isInstalled(s, installed) else { continue }
                    leftovers.append((path, ageInDays(path, fm)))
                }
                // Stalest first; keep the list small — this is a hint, not a dragnet.
                for l in leftovers.sorted(by: { ($0.age ?? 0) > ($1.age ?? 0) }).prefix(8) {
                    seen.insert(l.path)
                    scored.append((makeLeftoverTarget(l.path, age: l.age), 0.75))
                }
            }
        }

        // Drop candidates nested inside a shallower candidate — the parent
        // already covers their bytes (prevents double counting and racing
        // deletes like `target` + `target/wasm32-unknown-unknown`).
        var kept: [(target: CleanTarget, score: Double)] = []
        for cand in scored.sorted(by: { $0.target.rawPaths[0].count < $1.target.rawPaths[0].count }) {
            let p = cand.target.rawPaths[0]
            if kept.contains(where: { p.hasPrefix($0.target.rawPaths[0] + "/") }) { continue }
            kept.append(cand)
        }

        // Strongest signals first, cap the fan-out.
        return kept.sorted { $0.score > $1.score }.prefix(40).map(\.target)
    }

    // MARK: Classifier

    private struct Verdict { let safety: Safety; let score: Double }

    private static func classify(_ path: String, derived: Bool, hasTag: Bool, appleCaches: Bool,
                                 excludes: [String], ageDays: Int?, active: Bool, learnBoost: Double) -> Verdict? {
        if denylisted(path, excludes: excludes) { return nil }

        var cache = 0.0
        var safe = 0.0
        if hasTag                                     { cache += 1.0; safe += 0.6 }   // definitive
        if excludedFromBackup(path)                   { cache += 0.5; safe += 0.3 }   // dev said expendable
        if appleCaches                                { cache += 0.6 }
        if cacheNameTokens.contains(lastComp(path))   { cache += 0.4 }
        if derived                                    { cache += 0.5; safe += 0.7 }   // regenerable

        // Behavioral signals (Phase 2): staleness & live activity.
        if let ageDays {
            if ageDays >= 7      { safe += 0.3 }      // untouched for a week → safe to clear
            else if ageDays <= 1 { safe -= 0.2 }      // fresh → be cautious
        }
        if active { safe -= 0.6 }                     // being written right now → don't auto-select

        // Learned confidence (Phase 3): accumulated user/regeneration evidence.
        if learnBoost > 0 { cache += min(0.4, learnBoost); safe += learnBoost }
        else if learnBoost < 0 { safe += learnBoost }

        guard cache >= 0.7 else { return nil }
        return Verdict(safety: safe >= 0.6 ? .safe : .caution, score: cache)
    }

    /// Never offer these — sensitive or real user data, plus user exclusions.
    private static func denylisted(_ path: String, excludes: [String]) -> Bool {
        let home = NSHomeDirectory()
        let blocked = [
            "\(home)/Library/Mobile Documents",   // iCloud Drive
            "\(home)/Library/Mail",
            "\(home)/Library/Messages",
            "\(home)/Library/Keychains",
            "\(home)/.ssh",
            "\(home)/.gnupg",
            "\(home)/.config",                    // config ≠ cache
        ]
        if blocked.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        if excludes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        if path.contains(".photoslibrary") || path.contains(".sparsebundle") { return true }
        return false
    }

    private static func excludedFromBackup(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
    }

    // MARK: Helpers

    private static func makeTarget(_ path: String, _ v: Verdict, ageDays: Int?, inUse: Bool, learned: Bool) -> CleanTarget {
        let leaf = (path as NSString).lastPathComponent
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return CleanTarget(
            id: "disc:\(path)",
            name: parent.isEmpty ? leaf : "\(parent) · \(leaf)",
            detail: tildeAbbreviate(path),
            symbol: symbol(for: leaf),
            rawPaths: [path],
            safety: v.safety,
            strategy: .directory,
            isDiscovered: true,
            ageDays: ageDays,
            inUse: inUse,
            learned: learned
        )
    }

    private static func symbol(for name: String) -> String {
        switch name.lowercased() {
        case "node_modules", "pods", "vendor":               return "shippingbox"
        case "target", "build", ".gradle", ".build":         return "hammer"
        case "deriveddata":                                  return "hammer.fill"
        case ".venv", "__pycache__", ".pytest_cache":        return "ladybug"
        default:                                             return "tray.full"
        }
    }

    private static func lastComp(_ path: String) -> String {
        (path as NSString).lastPathComponent.lowercased()
    }

    private static func tildeAbbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private static func isDir(_ path: String, _ fm: FileManager) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }

    // MARK: Uninstalled-app leftovers

    /// "com.vendor.App"-shaped names only — matching by display name is too risky.
    private static func isBundleIDShaped(_ name: String) -> Bool {
        let parts = name.split(separator: ".")
        return parts.count >= 3 && !name.contains(" ")
    }

    /// Is an app with this bundle id (or a parent of it) present on the system?
    /// LaunchServices lookup catches apps anywhere; the prefix check keeps
    /// helper folders like com.microsoft.VSCode.ShipIt tied to their app.
    private static func isInstalled(_ id: String, _ installed: Set<String>) -> Bool {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil { return true }
        return installed.contains { id == $0 || id.hasPrefix($0 + ".") || $0.hasPrefix(id + ".") }
    }

    /// Bundle ids of everything in the standard app folders.
    private static func installedBundleIDs() -> Set<String> {
        let fm = FileManager()
        var ids = Set<String>()
        let dirs = ["/Applications", "/Applications/Utilities",
                    "/System/Applications", "/System/Applications/Utilities",
                    NSHomeDirectory() + "/Applications"]
        for dir in dirs {
            guard let apps = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for app in apps where app.hasSuffix(".app") {
                if let d = NSDictionary(contentsOfFile: "\(dir)/\(app)/Contents/Info.plist"),
                   let id = d["CFBundleIdentifier"] as? String {
                    ids.insert(id)
                }
            }
        }
        return ids
    }

    private static func makeLeftoverTarget(_ path: String, age: Int?) -> CleanTarget {
        CleanTarget(
            id: "left:\(path)",
            name: (path as NSString).lastPathComponent,
            detail: tildeAbbreviate(path),
            symbol: "archivebox",
            rawPaths: [path],
            safety: .caution,           // may hold licenses/data — always opt-in
            strategy: .directory,
            isDiscovered: true,
            ageDays: age,
            isLeftover: true
        )
    }

    /// Days since the directory was last modified (cheap staleness proxy).
    private static func ageInDays(_ path: String, _ fm: FileManager) -> Int? {
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let mod = attrs[.modificationDate] as? Date else { return nil }
        return max(0, Int(Date().timeIntervalSince(mod) / 86_400))
    }

    /// Is this path (or an ancestor/descendant) currently being written?
    private static func isActive(_ path: String, _ active: Set<String>) -> Bool {
        active.contains { $0 == path || $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") }
    }

    /// Run `mdfind` and return the matched paths (Spotlight, near-instant).
    private static func mdfind(_ args: [String]) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init)
    }
}
