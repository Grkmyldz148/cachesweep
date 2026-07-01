import Foundation

/// Serves localized strings from the best-matching .lproj. By default it follows
/// the device language (Locale.preferredLanguages); a manual override (set from
/// Settings) takes precedence and updates live.
enum Localizer {
    /// The active localization bundle (recomputed when the override changes).
    private(set) static var cached: Bundle = resolve(override: nil)

    /// Apply a manual language code, or nil to follow the device language.
    static func apply(_ override: String?) {
        cached = resolve(override: override)
    }

    private static func resolve(override: String?) -> Bundle {
        let available = Bundle.module.localizations
        let prefs = override.map { [$0] } ?? Locale.preferredLanguages
        for pref in prefs {
            if let match = bestMatch(pref, available),
               let path = Bundle.module.path(forResource: match, ofType: "lproj"),
               let localized = Bundle(path: path) {
                return localized
            }
        }
        return .module
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
func L(_ key: String) -> String {
    Localizer.cached.localizedString(forKey: key, value: key, table: nil)
}

/// Localized + formatted (keeps positional %1$@ / %d specifiers).
func Lf(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}
