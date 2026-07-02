import SwiftUI

/// A single cleanable category. Whole row is the tap target (toggles selection).
struct CategoryRow: View {
    var state: TargetState
    var onToggle: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: DS.s3) {
                iconTile
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: DS.s1) {
                        MarqueeText(text: state.target.name)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                            .layoutPriority(-1)   // badges keep their space; name compresses & scrolls
                        if state.target.isDiscovered {
                            Image(systemName: "sparkle.magnifyingglass")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.purple)
                                .help(L("discovered.help"))
                        }
                        if state.target.inUse {
                            badge(L("badge.inUse"), .orange)
                        } else if let d = state.target.ageDays, d >= 14 {
                            badge(Lf("badge.idleDays", Int32(d)), .gray)
                        }
                        if state.target.learned {
                            badge(L("badge.learned"), .teal)
                        }
                        if state.target.isLeftover {
                            badge(L("badge.leftover"), .indigo)
                        }
                        if state.target.needsAdmin {
                            badge(L("badge.admin"), .gray)
                        }
                    }
                    MarqueeText(text: state.target.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: DS.s2)
                trailing
            }
            .padding(.vertical, DS.s2)
            .padding(.horizontal, DS.s4)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
        }
        .buttonStyle(.plain)
        .opacity(state.isCleaning ? 0.45 : (isEmpty ? 0.5 : 1))
        .disabled(isEmpty || state.isCleaning)
    }

    private var isEmpty: Bool { state.size == 0 }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
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
            Button {
                Reveal.inFinder(state.target.expandedPaths.first ?? "")
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(.secondary)
            .help(L("reveal.help"))
            .opacity(isHovering ? 1 : 0)            // reserved space — no layout jump
            .allowsHitTesting(isHovering)
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
