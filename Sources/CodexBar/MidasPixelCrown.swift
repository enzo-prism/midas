import SwiftUI

/// A fixed pixel silhouette: motion changes its light, never its geometry or layout.
struct MidasPixelCrown: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var highlightColumn: Int?
    var animated = true

    static let pixels = [
        "100010001",
        "110111011",
        "111111111",
        "011111110",
        "011111110",
        "000000000",
        "011111110",
    ]

    var body: some View {
        Canvas { context, _ in
            for (row, cells) in Self.pixels.enumerated() {
                for (column, cell) in cells.enumerated() where cell == "1" {
                    let square = Path(CGRect(x: column * 2, y: row * 2 + 2, width: 2, height: 2))
                    context.fill(square, with: .color(MidasTheme.accent))
                    if !self.reduceMotion, column == self.highlightColumn {
                        context.fill(square, with: .color(.white.opacity(self.colorScheme == .dark ? 0.55 : 0.3)))
                    }
                }
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
        .task(id: self.animated && !self.reduceMotion) {
            self.highlightColumn = nil
            guard self.animated, !self.reduceMotion else { return }
            // SwiftUI cancels this task when the popover releases its hosting controller.
            // Rest between sweeps instead of continuously redrawing an idle crown.
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2.4))
                    for column in 0..<9 {
                        try Task.checkCancellation()
                        self.highlightColumn = column
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    self.highlightColumn = nil
                }
            } catch {
                self.highlightColumn = nil
            }
        }
    }
}
