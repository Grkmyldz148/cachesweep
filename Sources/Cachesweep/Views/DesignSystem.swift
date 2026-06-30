import SwiftUI

/// HIG-grounded design tokens. macOS spacing is an 8-pt-ish rhythm;
/// we use a small, consistent scale and the system's semantic colors,
/// materials and text styles so the app matches the OS automatically.
enum DS {
    // Spacing scale
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 20

    // Radii (concentric with macOS control radii)
    static let cardRadius: CGFloat = 12
    static let iconRadius: CGFloat = 8

    // Icon tile
    static let iconTile: CGFloat = 30

    // Popover size
    static let popoverWidth: CGFloat = 380
    static let popoverHeight: CGFloat = 560
}

extension Safety {
    /// Semantic system colors — adapt to light/dark automatically.
    var tint: Color {
        switch self {
        case .safe:    return .green
        case .caution: return .orange
        }
    }
}
