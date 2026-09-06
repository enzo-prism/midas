import AppKit

/// Shared measurement and drawing metrics. Text keeps its native menu-bar size instead of shrinking to fit a preset.
enum MidasMenuBarLayout {
    static let horizontalInset: CGFloat = 6
    static let readingGap: CGFloat = 5
    static let markWidth: CGFloat = 16
    static let orbitWidth: CGFloat = 18
    static let badgeWidth: CGFloat = 12
    static let badgeGap: CGFloat = 4

    static var font: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    }

    static func readingWidth(_ title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: self.font]).width)
    }

    static func width(title: String, orbit: Bool) -> CGFloat {
        let adornments = orbit ? self.orbitWidth : self.markWidth + self.badgeGap + self.badgeWidth
        // Keep a bounded footprint even for pathological values.
        // The full reading remains in accessibility text and the panel.
        return min(220, max(24, self.horizontalInset * 2 + self.readingGap + adornments + self.readingWidth(title)))
    }
}
