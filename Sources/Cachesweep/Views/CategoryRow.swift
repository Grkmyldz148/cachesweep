import SwiftUI

/// A single cleanable category. Whole row is the tap target (toggles selection).
struct CategoryRow: View {
    var state: TargetState
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: DS.s3) {
                iconTile
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: DS.s1) {
                        // Seed names are localization keys; discovered names
                        // (paths, bundle components) pass through L() unchanged.
                        MarqueeText(text: L(state.target.name), truncation: .tail)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                            .layoutPriority(-1)   // the badge keeps its space; name compresses & scrolls
                        if state.target.isDiscovered {
                            Image(systemName: "sparkle.magnifyingglass")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.purple)
                                .help(L("discovered.help"))
                        }
                        if let b = primaryBadge {
                            badge(b.0, b.1)
                        }
                    }
                    MarqueeText(text: detailText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: DS.s2)
                trailing
            }
            .padding(.vertical, DS.s2)
            .padding(.horizontal, DS.s4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(state.isCleaning ? 0.45 : (isEmpty ? 0.5 : 1))
        .disabled(isEmpty || state.isCleaning)
        .contextMenu {
            if let path = state.target.expandedPaths.first {
                Button(L("reveal.help")) { Reveal.inFinder(path) }
            }
        }
    }

    private var isEmpty: Bool { state.size == 0 }

    /// At most one badge per row — the state that changes the cleaning
    /// decision most. Everything informational lives in the detail line.
    private var primaryBadge: (String, Color)? {
        if state.target.inUse { return (L("badge.inUse"), .orange) }
        // No lockfile: the reinstall is a fresh resolution of whatever the
        // registry serves today, not a restoration of what was deleted. That
        // outranks the other badges — it is the one that can bite.
        if !state.target.reproducible { return (L("badge.noLock"), .orange) }
        if state.target.isLeftover { return (L("badge.leftover"), .indigo) }
        if state.target.needsAdmin { return (L("badge.admin"), .gray) }
        return nil
    }

    /// Path plus the states that used to compete as badges on the name line.
    private var detailText: String {
        var parts = [state.target.detail]
        if state.target.isVersionFamily { parts.append(L("detail.oldVersions")) }
        if state.target.learned { parts.append(L("badge.learned")) }
        if !state.target.inUse, let d = state.target.ageDays, d >= 14 {
            parts.append(Lf("detail.idleDays", Int32(d)))
        }
        if state.target.boomerang { parts.append(L("detail.boomerang")) }
        // A workspace arrives as one row over several folders; say how many,
        // or the size looks like it came from the one path on the line.
        if state.target.category == .projects, state.target.rawPaths.count > 1 {
            parts.append(Lf("detail.artifactCount", Int32(state.target.rawPaths.count)))
        }
        // The restore command, right on the row. "Regenerable" is an abstract
        // reassurance until the user can see what regenerating it costs them.
        if let cmd = state.target.restoreCommand { parts.append(cmd) }
        return parts.joined(separator: " · ")
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var iconTile: some View {
        Image(systemName: state.target.symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(state.target.safety.tint)
            .frame(width: DS.iconTile, height: DS.iconTile)
            .background(
                state.target.safety.tint.opacity(0.15),
                in: RoundedRectangle(cornerRadius: DS.iconRadius)
            )
    }

    @ViewBuilder
    private var trailing: some View {
        if state.isCleaning {
            ProgressView().controlSize(.small)
        } else {
            Text(isEmpty ? "—" : state.size.fileSize)
                .font(.callout.monospacedDigit())
                .foregroundStyle(isEmpty ? .secondary : .primary)
            Image(systemName: state.isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(state.isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
        }
    }
}
