import SwiftUI

/// A pulsing "live" indicator dot.
struct LiveDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(.green)
            .frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.3)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// One live-tracked location: what it is, current size, session growth, recency.
struct ActivityRow: View {
    var entry: ActivityEntry
    var onClean: (() -> Void)?

    var body: some View {
        HStack(spacing: DS.s2) {
            Image(systemName: entry.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(entry.isKnown ? Color.green : Color.orange)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DS.s1) {
                    Text(entry.label)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !entry.isKnown {
                        Text(L("badge.new"))
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                secondLine
            }

            Spacer(minLength: DS.s1)

            if let onClean, !entry.isKnown, entry.size > 0 {
                Button(action: onClean) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(L("activity.cleanHelp"))
            }
        }
    }

    @ViewBuilder
    private var secondLine: some View {
        HStack(spacing: DS.s1) {
            if entry.size > 0 { Text(entry.size.fileSize) }
            if entry.delta > 0 {
                Text("▲ \(UInt64(entry.delta).fileSize)").foregroundStyle(.green)
            } else if entry.delta < 0 {
                Text("▼ \(UInt64(-entry.delta).fileSize)").foregroundStyle(.secondary)
            }
            Text("· \(recency)").foregroundStyle(.tertiary)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var recency: String {
        let s = Int(Date().timeIntervalSince(entry.lastChange))
        if s < 3 { return L("time.justNow") }
        if s < 60 { return Lf("time.secondsShort", Int32(s)) }
        return Lf("time.minutesShort", Int32(s / 60))
    }
}
