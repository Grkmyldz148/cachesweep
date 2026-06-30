import Foundation

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
    static func discover(roots: [String], excluding seedPaths: Set<String>, excludes: [String]) async -> [CleanTarget] {
        await Task.detached(priority: .utility) {
            run(roots: roots, excluding: seedPaths, excludes: excludes)
        }.value
    }

    // MARK: Implementation

    private static func run(roots: [String], excluding seedPaths: Set<String>, excludes: [String]) -> [CleanTarget] {
        let fm = FileManager()
        let home = NSHomeDirectory()
        var seen = Set<String>()
        var scored: [(target: CleanTarget, score: Double)] = []

        func consider(_ path: String, derived: Bool, hasTag: Bool, appleCaches: Bool) {
            guard !seen.contains(path), !seedPaths.contains(path) else { return }
            guard isDir(path, fm) else { return }
            guard let v = classify(path, derived: derived, hasTag: hasTag,
                                   appleCaches: appleCaches, excludes: excludes) else { return }
            seen.insert(path)
            scored.append((makeTarget(path, v), v.score))
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

        // Strongest signals first, cap the fan-out.
        return scored.sorted { $0.score > $1.score }.prefix(40).map(\.target)
    }

    // MARK: Classifier

    private struct Verdict { let safety: Safety; let score: Double }

    private static func classify(_ path: String, derived: Bool, hasTag: Bool, appleCaches: Bool, excludes: [String]) -> Verdict? {
        if denylisted(path, excludes: excludes) { return nil }

        var cache = 0.0
        var safe = 0.0
        if hasTag                                     { cache += 1.0; safe += 0.6 }   // definitive
        if excludedFromBackup(path)                   { cache += 0.5; safe += 0.3 }   // dev said expendable
        if appleCaches                                { cache += 0.6 }
        if cacheNameTokens.contains(lastComp(path))   { cache += 0.4 }
        if derived                                    { cache += 0.5; safe += 0.7 }   // regenerable

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

    private static func makeTarget(_ path: String, _ v: Verdict) -> CleanTarget {
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
            isDiscovered: true
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
