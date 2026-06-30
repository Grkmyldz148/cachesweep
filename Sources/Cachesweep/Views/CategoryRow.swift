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
                    Text(state.target.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(state.target.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
    }

    private var isEmpty: Bool { state.size == 0 }

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
