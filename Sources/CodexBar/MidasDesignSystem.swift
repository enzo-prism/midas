import AppKit
import SwiftUI

/// System colors inherit macOS appearance, accent, vibrancy, and accessibility contrast.
enum MidasTheme {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let text = Color.primary
    static let secondaryText = Color.secondary
    static let accent = Color.accentColor
    static let warning = Color(nsColor: .systemRed)
}

struct MidasQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 28, minHeight: 28)
            .background(
                configuration.isPressed ? Color.primary.opacity(0.1) : .clear,
                in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A single glass layer for navigation; data stays on an opaque, legible system surface.
struct MidasNavigationGlass<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var forceOpaque = false
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26, *), !self.reduceTransparency, !self.forceOpaque {
            GlassEffectContainer {
                self.content
                    .glassEffect(.regular, in: .capsule)
            }
        } else {
            self.content
                .background(MidasTheme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
    }
}

/// Short lists get shorter panels; long lists scroll without moving the total or actions.
enum MidasPanelLayout {
    static let width: CGFloat = 360
    static let maximumHeight: CGFloat = 540

    static func height(providerCount: Int, availableHeight: CGFloat, showsDetail: Bool = false) -> CGFloat {
        let preferred = showsDetail ? self.maximumHeight : min(
            self.maximumHeight,
            190 + CGFloat(max(0, providerCount)) * 120)
        return min(max(276, preferred), max(200, availableHeight - 48))
    }
}

struct MidasRemainingBar: View {
    let percent: Double
    /// Quota bars warn when nearly exhausted; activity bars stay accent at any level.
    var warningWhenLow = true
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(self.warningWhenLow && self.percent <= 10 ? MidasTheme.warning : MidasTheme.accent)
                    .frame(width: geometry.size.width * min(100, max(0, self.percent)) / 100)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
