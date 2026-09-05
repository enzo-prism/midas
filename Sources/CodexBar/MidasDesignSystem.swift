import AppKit
import SwiftUI

/// Solid, adaptive surfaces keep quota text legible with Reduce Transparency enabled.
enum MidasTheme {
    static let background = adaptive(light: 0xFAFAF7, dark: 0x20221F)
    static let surface = adaptive(light: 0xEFEFE9, dark: 0x2D302B)
    static let text = adaptive(light: 0x222420, dark: 0xF4F4ED)
    static let secondaryText = adaptive(light: 0x64675F, dark: 0xB3B7AB)
    static let accent = adaptive(light: 0x8A6017, dark: 0xE4BC70)
    static let warning = adaptive(light: 0xB13D2D, dark: 0xFFAB99)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1)
        })
    }
}

struct MidasQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(8)
            .background(configuration.isPressed ? MidasTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct MidasRemainingBar: View {
    let percent: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(MidasTheme.surface)
                Capsule().fill(self.percent <= 10 ? MidasTheme.warning : MidasTheme.accent)
                    .frame(width: geometry.size.width * min(100, max(0, self.percent)) / 100)
            }
        }
        .frame(height: 7)
        .accessibilityHidden(true)
    }
}
