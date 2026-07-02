import SwiftUI
import AppKit

/// Reveals a filesystem path in Finder.
enum Reveal {
    static func inFinder(_ path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Single-line text that scrolls (marquee) under the cursor when it does not
/// fit its container, so truncated paths can be read in place. Inherits font
/// and foreground style from the environment like a plain Text.
struct MarqueeText: View {
    let text: String

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offsetX: CGFloat = 0
    @State private var hovering = false

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }

    var body: some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.middle)
            .opacity(hovering && overflow > 1 ? 0 : 1)
            .background(widthReader { containerWidth = $0 })
            .overlay(alignment: .leading) {
                // Full-width copy that slides left to reveal the tail.
                if hovering && overflow > 1 {
                    Text(text)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(x: offsetX)
                }
            }
            .clipped()
            .background(alignment: .leading) {
                // Hidden natural-width copy, used only for measurement.
                Text(text)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .hidden()
                    .background(widthReader { textWidth = $0 })
            }
            .onHover { h in
                hovering = h
                if h, overflow > 1 {
                    offsetX = 0
                    // ~50 pt/s, short pause before starting — calm, readable.
                    withAnimation(.linear(duration: max(0.8, Double(overflow) / 50)).delay(0.25)) {
                        offsetX = -overflow
                    }
                } else {
                    offsetX = 0
                }
            }
    }

    private func widthReader(_ update: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { g in
            Color.clear
                .onAppear { update(g.size.width) }
                .onChange(of: g.size.width) { _, w in update(w) }
        }
    }
}
