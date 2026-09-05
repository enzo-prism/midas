import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct MidasMenuBarLayoutTests {
    @Test func orbitUsesOnlyTheReadingRingAndPadding() {
        for title in ["$30", "$13.9k", "—", "••••", "2 FX"] {
            let width = MidasMenuBarLayout.width(title: title, orbit: true)
            #expect(width < 90)
            let geometry = MidasMenuBarView.geometry(in: CGRect(x: 0, y: 0, width: width, height: 24), orbit: true)
            #expect(geometry.title.width >= MidasMenuBarLayout.readingWidth(title))
            #expect(geometry.title.width - MidasMenuBarLayout.readingWidth(title) < 1)
            #expect(geometry.mark.minX - geometry.title.maxX == 5)
            #expect(geometry.title.minX == width - geometry.mark.maxX)
        }
    }

    @Test func normalAndLocalizedReadingsFitWithoutShrinking() {
        for orbit in [false, true] {
            for title in [
                "≈$42.80",
                "£999.99",
                "CHF 999.99",
                "€13,9k",
                "¥123M",
                "C 100%",
                "C 72%  U 54%  M —",
                "١٢٣٫٤ €",
            ] {
                let width = MidasMenuBarLayout.width(title: title, orbit: orbit)
                for height: CGFloat in [22, 24, 37] {
                    let bounds = CGRect(x: 3, y: 2, width: width, height: height)
                    let geometry = MidasMenuBarView.geometry(in: bounds, orbit: orbit)
                    #expect(bounds.contains(geometry.title))
                    #expect(bounds.contains(geometry.mark))
                    #expect(bounds.contains(geometry.badge))
                    #expect(geometry.title.width >= MidasMenuBarLayout.readingWidth(title))
                    #expect(orbit || geometry.title.maxX + 4 == geometry.badge.minX)
                }
            }
        }
        #expect(MidasMenuBarLayout.font.pointSize == 13)
    }

    @Test func changingDigitsAndRefreshStateDoesNotMoveNeighbors() {
        for orbit in [false, true] {
            #expect(MidasMenuBarLayout.width(title: "$11.11", orbit: orbit)
                == MidasMenuBarLayout.width(title: "$88.88", orbit: orbit))
            var widths = Set<CGFloat>()
            for active in [false, true] {
                for attention in [false, true] {
                    for stale in [false, true] {
                        let model = MidasMenuBarPresentation(
                            title: "$42.80",
                            accessibilityLabel: "Fixture",
                            tooltip: "Fixture",
                            isRefreshing: active,
                            attention: attention,
                            isStale: stale,
                            orbitProvider: orbit ? .codex : nil)
                        widths.insert(model.width)
                    }
                }
            }
            #expect(widths.count == 1)
        }
    }

    @Test func shorterReadingsReclaimSpaceAfterLongerReadings() {
        #expect(MidasMenuBarLayout.width(title: "—", orbit: true)
            < MidasMenuBarLayout.width(title: "$999.99", orbit: true))
        #expect(MidasMenuBarLayout.width(title: "C —", orbit: false)
            < MidasMenuBarLayout.width(title: "C 100%  U 100%  M —", orbit: false))
        #expect(MidasMenuBarLayout.width(title: String(repeating: "9", count: 300), orbit: false) == 220)
    }
}
