import Foundation

/// How confident we are that cleaning a target is safe.
enum Safety: String, Sendable {
    case safe       // pure regenerable cache — green
    case caution    // real data that re-downloads or takes effort — orange

    var label: String {
        switch self {
        case .safe:    return "Güvenli"
        case .caution: return "Dikkat"
        }
    }
}

/// How a target's space is reclaimed.
enum CleanStrategy: Sendable {
    case directory   // remove the path itself (the tool recreates it)
    case contents    // remove the children, keep the folder
}

/// A known location whose size we track and that the user can clean.
/// This is the curated "rules database" — the heart of the product.
struct CleanTarget: Identifiable, Sendable {
    let id: String
    let name: String
    let detail: String
    let symbol: String          // SF Symbol name
    var rawPaths: [String]      // may contain ~
    let safety: Safety
    let strategy: CleanStrategy
    var isDiscovered = false    // true when found by the smart scanner, not the seed list
    var ageDays: Int? = nil     // days since last modified (staleness) — discovered only
    var inUse = false           // currently being written (from the live tracker)
    var learned = false         // promoted by accumulated learning (Phase 3)
    var isLeftover = false      // orphaned data from an app that is no longer installed

    var expandedPaths: [String] {
        rawPaths.map { ($0 as NSString).expandingTildeInPath }
    }

    /// Curated, dev-focused, non-overlapping cache locations.
    static let all: [CleanTarget] = [
        CleanTarget(id: "dot-cache", name: "Genel Cache",
                    detail: "~/.cache (codex, puppeteer, uv…)",
                    symbol: "tray.full", rawPaths: ["~/.cache"],
                    safety: .safe, strategy: .contents),

        CleanTarget(id: "npm", name: "npm Cache",
                    detail: "~/.npm/_cacache",
                    symbol: "shippingbox", rawPaths: ["~/.npm/_cacache"],
                    safety: .safe, strategy: .directory),

        CleanTarget(id: "yarn", name: "Yarn Cache",
                    detail: "Yarn paket önbelleği",
                    symbol: "shippingbox", rawPaths: ["~/Library/Caches/Yarn"],
                    safety: .safe, strategy: .directory),

        CleanTarget(id: "pnpm", name: "pnpm Store",
                    detail: "~/Library/pnpm/store",
                    symbol: "shippingbox", rawPaths: ["~/Library/pnpm/store", "~/Library/Caches/pnpm"],
                    safety: .safe, strategy: .directory),

        CleanTarget(id: "gradle", name: "Gradle Cache",
                    detail: "~/.gradle/caches",
                    symbol: "hammer", rawPaths: ["~/.gradle/caches"],
                    safety: .safe, strategy: .directory),

        CleanTarget(id: "derived", name: "Xcode DerivedData",
                    detail: "Derleme türevleri",
                    symbol: "hammer.fill", rawPaths: ["~/Library/Developer/Xcode/DerivedData"],
                    safety: .safe, strategy: .contents),

        CleanTarget(id: "simcaches", name: "Simulator Cache",
                    detail: "CoreSimulator/Caches",
                    symbol: "iphone", rawPaths: ["~/Library/Developer/CoreSimulator/Caches"],
                    safety: .caution, strategy: .contents),

        CleanTarget(id: "pip", name: "pip Cache",
                    detail: "~/Library/Caches/pip",
                    symbol: "shippingbox", rawPaths: ["~/Library/Caches/pip"],
                    safety: .safe, strategy: .directory),

        CleanTarget(id: "cocoapods", name: "CocoaPods Cache",
                    detail: "~/Library/Caches/CocoaPods",
                    symbol: "shippingbox", rawPaths: ["~/Library/Caches/CocoaPods"],
                    safety: .safe, strategy: .directory),

        CleanTarget(id: "homebrew", name: "Homebrew Cache",
                    detail: "İndirilen formüller",
                    symbol: "mug", rawPaths: ["~/Library/Caches/Homebrew"],
                    safety: .safe, strategy: .contents),

        CleanTarget(id: "ollama", name: "Ollama Modelleri",
                    detail: "İndirilen LLM modelleri",
                    symbol: "brain", rawPaths: ["~/.ollama/models"],
                    safety: .caution, strategy: .directory),

        CleanTarget(id: "logs", name: "Log Kayıtları",
                    detail: "~/Library/Logs",
                    symbol: "doc.text", rawPaths: ["~/Library/Logs"],
                    safety: .safe, strategy: .contents),

        CleanTarget(id: "trash", name: "Çöp Kutusu",
                    detail: "~/.Trash + güvenlik çöpü",
                    symbol: "trash", rawPaths: ["~/.Trash", "~/.nt-trash"],
                    safety: .safe, strategy: .contents),
    ]
}
