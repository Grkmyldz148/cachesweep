import SwiftUI
import AppKit

_ = NSApplication.shared

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var n: UInt64 = 0
        Scanner(string: s).scanHexInt64(&n)
        self = Color(.sRGB,
                     red: Double((n >> 16) & 0xff) / 255,
                     green: Double((n >> 8) & 0xff) / 255,
                     blue: Double(n & 0xff) / 255, opacity: 1)
    }
}

/// Concept A — indigo squircle + sparkles, HIG geometry (824/1024, r=185.4).
struct IconView: View {
    private let radius: CGFloat = 185.4
    private let content: CGFloat = 824
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: "6E8BFF"), Color(hex: "2533B0")],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0)],
                                             startPoint: .top, endPoint: .center)))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 3))
                .frame(width: content, height: content)
                .shadow(color: Color(hex: "2533B0").opacity(0.45), radius: 28, y: 16)
            Image(systemName: "sparkles")
                .font(.system(size: content * 0.46, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.16), radius: 10, y: 8)
        }
        .frame(width: 1024, height: 1024)
    }
}

let iconsetDir = "/Volumes/harici_ssd/Cachesweep/Resources/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

@MainActor
func write(_ pixels: CGFloat, _ name: String) {
    let r = ImageRenderer(content: IconView())
    r.scale = pixels / 1024.0
    guard let cg = r.cgImage else { print("✗ \(name)"); return }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: "\(iconsetDir)/\(name)"))
}

MainActor.assumeIsolated {
    write(16,   "icon_16x16.png")
    write(32,   "icon_16x16@2x.png")
    write(32,   "icon_32x32.png")
    write(64,   "icon_32x32@2x.png")
    write(128,  "icon_128x128.png")
    write(256,  "icon_128x128@2x.png")
    write(256,  "icon_256x256.png")
    write(512,  "icon_256x256@2x.png")
    write(512,  "icon_512x512.png")
    write(1024, "icon_512x512@2x.png")
    // README master
    write(1024, "../icon-1024.png")
    print("✓ iconset hazir")
}
