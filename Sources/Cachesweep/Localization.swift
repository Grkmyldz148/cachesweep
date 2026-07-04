import Foundation

/// Serves localized strings from the best-matching .lproj. By default it follows
/// the device language (Locale.preferredLanguages); a manual override (set from
/// Settings) takes precedence and updates live.
@MainActor
enum Localizer {
    /// The SwiftPM resource bundle. The generated `Bundle.module` accessor
    /// only checks next to the executable and the *build directory* — not the
    /// packaged app's Contents/Resources, where package.sh places it. On any
    /// machine without the build tree that made `Bundle.module` trap at
    /// launch. Resolve the real location first; keep `.module` for dev runs.
    private static let resources: Bundle = {
        if let url = Bundle.main.resourceURL?
            .appendingPathComponent("Cachesweep_Cachesweep.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()

    /// The active localization bundle (recomputed when the override changes).
    private(set) static var cached: Bundle = resolve(override: nil)

    /// Apply a manual language code, or nil to follow the device language.
    static func apply(_ override: String?) {
        cached = resolve(override: override)
    }

    private static func resolve(override: String?) -> Bundle {
        let available = resources.localizations
        let prefs = override.map { [$0] } ?? Locale.preferredLanguages
        for pref in prefs {
            if let match = bestMatch(pref, available),
               let path = resources.path(forResource: match, ofType: "lproj"),
               let localized = Bundle(path: path) {
                return localized
            }
        }
        return resources
    }

    /// Match "de-DE" / "pt-BR" / "zh-Hans-CN" against available codes,
    /// dropping trailing components until something matches.
    private static func bestMatch(_ pref: String, _ available: [String]) -> String? {
        let lowered = available.map { ($0.lowercased(), $0) }
        var parts = pref.lowercased().split(separator: "-").map(String.init)
        while !parts.isEmpty {
            let candidate = parts.joined(separator: "-")
            if let hit = lowered.first(where: { $0.0 == candidate }) { return hit.1 }
            parts.removeLast()
        }
        return nil
    }
}

/// Localized string for the active language. Falls back to the key itself.
@MainActor
func L(_ key: String) -> String {
    Localizer.cached.localizedString(forKey: key, value: key, table: nil)
}

/// Localized + formatted (keeps positional %1$@ / %d specifiers).
@MainActor
func Lf(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}
