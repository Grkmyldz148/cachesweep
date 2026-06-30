import SwiftUI
import AppKit

// Ensure a graphics context exists for offscreen rendering.
_ = NSApplication.shared

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var n: UInt64 = 0
        Scanner(string: s).scanHexInt64(&n)
        self = Color(.sRGB,
                     red: Double((n >> 16) & 0xff) / 255,
                     green: Double((n >> 8) & 0xff) / 255,
                     blue: Double(n & 0xff) / 255,
                     opacity: 1)
    }
}

/// HIG-grounded app icon: 824 squircle (continuous), specular Liquid-Glass
/// highlight, glass edge, centered Apple SF Symbol glyph, in a 1024 canvas.
struct IconView: View {
    let top: Color
    let bottom: Color
    let symbol: String
    let glyphScale: CGFloat

    private let radius: CGFloat = 185.4
    private let content: CGFloat = 824

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [top, bottom],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(                                   // top specular sheen (glass)
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0)],
                                             startPoint: .top, endPoint: .center))
                )
                .overlay(                                   // crisp glass edge
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 3)
                )
                .frame(width: content, height: content)
                .shadow(color: bottom.opacity(0.45), radius: 28, y: 16)

            Image(systemName: symbol)
                .font(.system(size: content * glyphScale, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.16), radius: 10, y: 8)
        }
        .frame(width: 1024, height: 1024)
    }
}

let outDir = "/Volumes/harici_ssd/Sweep/tools/preview"

@MainActor
func render(_ view: some View, _ name: String) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    guard let cg = renderer.cgImage else { print("✗ \(name): render basarisiz"); return }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    let path = "\(outDir)/\(name).png"
    try? data.write(to: URL(fileURLWithPath: path))
    print("✓ \(path)  (\(cg.width)x\(cg.height))")
}

MainActor.assumeIsolated {
    render(IconView(top: Color(hex: "6E8BFF"), bottom: Color(hex: "2533B0"),
                    symbol: "sparkles", glyphScale: 0.46), "A_sparkles_indigo")
    render(IconView(top: Color(hex: "36E2C0"), bottom: Color(hex: "0B86C6"),
                    symbol: "wind", glyphScale: 0.50), "B_wind_teal")
    render(IconView(top: Color(hex: "B07CFF"), bottom: Color(hex: "5A23C6"),
                    symbol: "wand.and.sparkles", glyphScale: 0.48), "C_wand_violet")
}
