import SwiftUI

/// A fixed pixel silhouette: motion changes its light, never its geometry or layout.
struct MidasPixelCrown: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var sweepHead: Int?
    @State private var spark: SparkPixel?
    var animated = true

    struct SparkPixel: Hashable {
        let column: Int
        let row: Int
    }

    static let pixels = [
        "100010001",
        "110111011",
        "111111111",
        "011111110",
        "011111110",
        "000000000",
        "011111110",
    ]

    /// Pixels eligible for the end-of-sweep sparkle: the three teeth of the top row.
    /// Every candidate must stay on a lit cell of ``pixels`` (covered by tests).
    static let sparkCandidates: [SparkPixel] = [
        SparkPixel(column: 0, row: 0),
        SparkPixel(column: 4, row: 0),
        SparkPixel(column: 8, row: 0),
    ]

    /// White-overlay opacity for a pixel column while the sweep head passes it.
    /// The head burns bright white; the two columns behind it trail off warm,
    /// like a sheen gliding across gold. Columns ahead of the head stay dark.
    static func sweepOpacity(column: Int, head: Int, colorScheme: ColorScheme) -> Double {
        let trail = head - column
        switch trail {
        case 0:
            return colorScheme == .dark ? 0.85 : 0.5
        case 1:
            return colorScheme == .dark ? 0.4 : 0.22
        case 2:
            return colorScheme == .dark ? 0.16 : 0.08
        default:
            return 0
        }
    }

    static func sparkOpacity(colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.95 : 0.7
    }

    var body: some View {
        Canvas { context, _ in
            for (row, cells) in Self.pixels.enumerated() {
                for (column, cell) in cells.enumerated() where cell == "1" {
                    let square = Path(CGRect(x: column * 2, y: row * 2 + 2, width: 2, height: 2))
                    context.fill(square, with: .color(MidasTheme.accent))
                    if !self.reduceMotion, let head = self.sweepHead {
                        let opacity = Self.sweepOpacity(
                            column: column,
                            head: head,
                            colorScheme: self.colorScheme)
                        if opacity > 0 {
                            context.fill(square, with: .color(.white.opacity(opacity)))
                        }
                    }
                    if !self.reduceMotion,
                       let spark = self.spark,
                       spark.column == column,
                       spark.row == row
                    {
                        let opacity = Self.sparkOpacity(colorScheme: self.colorScheme)
                        context.fill(square, with: .color(.white.opacity(opacity)))
                    }
                }
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
        .task(id: self.animated && !self.reduceMotion) {
            self.sweepHead = nil
            self.spark = nil
            guard self.animated, !self.reduceMotion else { return }
            // SwiftUI cancels this task when the popover releases its hosting controller.
            // Rest between sweeps instead of continuously redrawing an idle crown.
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(3.2))
                    for column in 0..<9 {
                        try Task.checkCancellation()
                        self.sweepHead = column
                        try await Task.sleep(for: .milliseconds(90))
                    }
                    self.sweepHead = nil
                    self.spark = Self.sparkCandidates.randomElement()
                    try await Task.sleep(for: .milliseconds(260))
                    self.spark = nil
                }
            } catch {
                self.sweepHead = nil
                self.spark = nil
            }
        }
    }
}
