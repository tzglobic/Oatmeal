import SwiftUI
import AppKit

/// Semantic colours adapt to macOS appearance, including increased contrast.
enum OatmealStyle {
    static let accent = adaptive(light: 0xA94720, dark: 0xF1A37D)
    static let paper = adaptive(light: 0xF7F3ED, dark: 0x1D1A17)
    static let panel = adaptive(light: 0xFFFDF9, dark: 0x28231F)
    static let selection = adaptive(light: 0xF3DFD3, dark: 0x4B3025)
    static let ink = adaptive(light: 0x29241F, dark: 0xF3EADF)
    static let muted = adaptive(light: 0x746B62, dark: 0xB7AA9E)
    static let line = adaptive(light: 0xDED5C8, dark: 0x51473D)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
}

struct OatmealSectionLabel: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(1)
            .foregroundStyle(OatmealStyle.muted)
    }
}
