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
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DS.s2) {
            Image(systemName: entry.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(entry.isKnown ? Color.green : Color.orange)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DS.s1) {
                    MarqueeText(text: entry.label)
                        .font(.caption.weight(.medium))
                    if !entry.isKnown {
                        Text(L("badge.new"))
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                secondLine
            }

            Spacer(minLength: DS.s1)

            // A worded button instead of a bare trash glyph: a destructive
            // action should say what it does, and the ellipsis promises the
            // confirmation step before anything is deleted.
            if let onClean, !entry.isKnown, entry.size > 0 {
                Button(L("activity.clean"), action: onClean)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(.caption)
                    .help(L("activity.cleanHelp"))
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(L("reveal.help")) { Reveal.inFinder(entry.id) }
        }
    }

    @ViewBuilder
    private var secondLine: some View {
        HStack(spacing: DS.s1) {
            if entry.size > 0 { Text(entry.size.fileSize) }
            if entry.delta > 0 {
                // Growth is the bad news here — never paint it green (green
                // means "safe" elsewhere). Neutral normally, orange when the
                // session's growth is big enough to care about.
                Text("▲ \(UInt64(entry.delta).fileSize)")
                    .foregroundStyle(entry.delta >= 100_000_000 ? Color.orange : Color.secondary)
            } else if entry.delta < 0 {
                Text("▼ \(UInt64(-entry.delta).fileSize)").foregroundStyle(.secondary)
            }
            Text("· \(recency)")
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
