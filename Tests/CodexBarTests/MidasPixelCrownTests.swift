import SwiftUI
import Testing
@testable import CodexBar

struct MidasPixelCrownTests {
    @Test
    func `sweep head burns brightest then trails off`() {
        #expect(MidasPixelCrown.sweepOpacity(column: 4, head: 4, colorScheme: .dark) == 0.85)
        #expect(MidasPixelCrown.sweepOpacity(column: 3, head: 4, colorScheme: .dark) == 0.4)
        #expect(MidasPixelCrown.sweepOpacity(column: 2, head: 4, colorScheme: .dark) == 0.16)
        #expect(MidasPixelCrown.sweepOpacity(column: 1, head: 4, colorScheme: .dark) == 0)
    }

    @Test
    func `columns ahead of the sweep stay dark`() {
        #expect(MidasPixelCrown.sweepOpacity(column: 5, head: 4, colorScheme: .dark) == 0)
        #expect(MidasPixelCrown.sweepOpacity(column: 8, head: 0, colorScheme: .light) == 0)
    }

    @Test
    func `light scheme stays subtler than dark`() {
        for trail in 0...2 {
            let dark = MidasPixelCrown.sweepOpacity(column: 4 - trail, head: 4, colorScheme: .dark)
            let light = MidasPixelCrown.sweepOpacity(column: 4 - trail, head: 4, colorScheme: .light)
            #expect(light > 0)
            #expect(light < dark)
        }
        #expect(MidasPixelCrown.sparkOpacity(colorScheme: .light) < MidasPixelCrown.sparkOpacity(colorScheme: .dark))
    }

    @Test
    func `spark candidates sit on lit crown teeth`() {
        #expect(!MidasPixelCrown.sparkCandidates.isEmpty)
        for spark in MidasPixelCrown.sparkCandidates {
            let row = MidasPixelCrown.pixels[spark.row]
            let cell = row[row.index(row.startIndex, offsetBy: spark.column)]
            #expect(cell == "1")
        }
    }

    @Test
    func `grid keeps its fixed geometry`() {
        #expect(MidasPixelCrown.pixels.count == 7)
        #expect(MidasPixelCrown.pixels.allSatisfy { $0.count == 9 })
    }
}
