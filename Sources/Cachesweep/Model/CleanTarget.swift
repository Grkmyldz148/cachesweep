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

/// Display grouping for the main list.
enum TargetCategory: Int, CaseIterable, Sendable {
    case devCaches   // package managers & build outputs
    case appCaches   // per-app caches under ~/Library/Caches
    case leftovers   // remains of uninstalled apps
    case aiData      // AI tool bulk data: models, VM images, session stores
    case other       // logs, trash

    @MainActor var title: String {
        switch self {
        case .devCaches: return L("category.dev")
        case .appCaches: return L("category.app")
        case .leftovers: return L("category.leftovers")
        case .aiData:    return L("category.ai")
        case .other:     return L("category.other")
        }
    }
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
    var needsAdmin = false      // root-owned; cleaned via administrator authorization
    var category: TargetCategory = .devCaches

    var expandedPaths: [String] {
        rawPaths.map { ($0 as NSString).expandingTildeInPath }
    }

    /// Curated, dev-focused, non-overlapping cache locations.
    /// `name` may be a localization key ("seed.*") — resolved at display time;
    /// non-key names (product names like "npm Cache") pass through unchanged.
    static let all: [CleanTarget] = [
        CleanTarget(id: "dot-cache", name: "seed.dotcache",
                    detail: "~/.cache (codex, puppeteer, uv…)",
                    symbol: "tray.full", rawPaths: ["~/.cache"],
                    safety: .safe, strategy: .contents),

        CleanTarget(id: "npm", name: "npm Cache",
                    detail: "~/.npm/_cacache",
                    symbol: "shippingbox", rawPaths: ["~/.npm/_cacache"],
                    safety: .safe, strategy: .directory),

        CleanTarget(id: "yarn", name: "Yarn Cache",
                    detail: "~/Library/Caches/Yarn",
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
                    detail: "~/Library/Developer/Xcode/DerivedData",
                    symbol: "hammer.fill", rawPaths: ["~/Library/Developer/Xcode/DerivedData"],
                    safety: .safe, strategy: .contents),

        CleanTarget(id: "devicesupport", name: "Xcode DeviceSupport",
                    detail: "iOS/watchOS/tvOS DeviceSupport",
                    symbol: "iphone",
                    rawPaths: ["~/Library/Developer/Xcode/iOS DeviceSupport",
                               "~/Library/Developer/Xcode/watchOS DeviceSupport",
                               "~/Library/Developer/Xcode/tvOS DeviceSupport"],
                    safety: .safe, strategy: .contents),

        CleanTarget(id: "archives", name: "seed.archives",
                    detail: "~/Library/Developer/Xcode/Archives",
                    symbol: "shippingbox.fill", rawPaths: ["~/Library/Developer/Xcode/Archives"],
                    safety: .caution, strategy: .contents),

        CleanTarget(id: "simcaches", name: "seed.sim",
                    detail: "~/Library/Developer/CoreSimulator/Caches",
                    symbol: "iphone", rawPaths: ["~/Library/Developer/CoreSimulator/Caches"],
                    safety: .caution, strategy: .contents),

        CleanTarget(id: "maven", name: "Maven Repository",
                    detail: "~/.m2/repository",
                    symbol: "shippingbox", rawPaths: ["~/.m2/repository"],
                    safety: .safe, strategy: .directory),

        CleanTarget(id: "gomod", name: "Go Cache",
                    detail: "~/go/pkg/mod + go-build",
                    symbol: "shippingbox", rawPaths: ["~/go/pkg/mod", "~/Library/Caches/go-build"],
                    safety: .safe, strategy: .directory),

        CleanTarget(id: "cargo", name: "Cargo Cache",
                    detail: "~/.cargo/registry + git",
                    symbol: "shippingbox", rawPaths: ["~/.cargo/registry", "~/.cargo/git"],
                    safety: .safe, strategy: .directory),

        CleanTarget(id: "bun", name: "Bun Cache",
                    detail: "~/.bun/install/cache",
                    symbol: "shippingbox", rawPaths: ["~/.bun/install/cache"],
                    safety: .safe, strategy: .directory),

        CleanTarget(id: "spm", name: "SwiftPM Cache",
                    detail: "~/Library/Caches/org.swift.swiftpm",
                    symbol: "shippingbox", rawPaths: ["~/Library/Caches/org.swift.swiftpm"],
                    safety: .safe, strategy: .directory),

        CleanTarget(id: "pip", name: "pip Cache",
                    detail: "~/Library/Caches/pip",
                    symbol: "shippingbox", rawPaths: ["~/Library/Caches/pip"],
                    safety: .safe, strategy: .directory),

        CleanTarget(id: "cocoapods", name: "CocoaPods Cache",
                    detail: "~/Library/Caches/CocoaPods",
                    symbol: "shippingbox", rawPaths: ["~/Library/Caches/CocoaPods"],
                    safety: .safe, strategy: .directory),

        CleanTarget(id: "homebrew", name: "Homebrew Cache",
                    detail: "~/Library/Caches/Homebrew",
                    symbol: "mug", rawPaths: ["~/Library/Caches/Homebrew"],
                    safety: .safe, strategy: .contents),

        // AI tool bulk data: never preselected (.caution). Models and VM
        // images re-download on demand; session stores are past-conversation
        // logs the tools keep forever and never prune.
        CleanTarget(id: "ollama", name: "seed.ollama",
                    detail: "~/.ollama/models",
                    symbol: "brain", rawPaths: ["~/.ollama/models"],
                    safety: .caution, strategy: .directory, category: .aiData),

        CleanTarget(id: "claude-vm", name: "Claude VM Bundles",
                    detail: "~/Library/Application Support/Claude/vm_bundles",
                    symbol: "cube.box",
                    rawPaths: ["~/Library/Application Support/Claude/vm_bundles"],
                    safety: .caution, strategy: .directory, category: .aiData),

        CleanTarget(id: "grok-sessions", name: "Grok CLI Sessions",
                    detail: "~/.grok/sessions",
                    symbol: "text.bubble", rawPaths: ["~/.grok/sessions"],
                    safety: .caution, strategy: .contents, category: .aiData),

        CleanTarget(id: "codex-sessions", name: "Codex CLI Sessions",
                    detail: "~/.codex/sessions",
                    symbol: "text.bubble", rawPaths: ["~/.codex/sessions"],
                    safety: .caution, strategy: .contents, category: .aiData),

        CleanTarget(id: "logs", name: "seed.logs",
                    detail: "~/Library/Logs",
                    symbol: "doc.text", rawPaths: ["~/Library/Logs"],
                    safety: .safe, strategy: .contents, category: .other),

        CleanTarget(id: "trash", name: "seed.trash",
                    detail: "~/.Trash",
                    symbol: "trash", rawPaths: ["~/.Trash", "~/.nt-trash"],
                    safety: .safe, strategy: .contents, category: .other),
    ]
}
