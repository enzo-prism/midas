import Foundation
import Testing
@testable import CodexBar

struct MidasPanelLayoutTests {
    @Test func panelUsesCompactMenuDimensions() {
        #expect(MidasPanelLayout.width <= 360)
        #expect(MidasPanelLayout.maximumHeight <= 540)
        #expect(MidasPanelLayout.width * MidasPanelLayout.maximumHeight < 400 * 660 * 0.75)
    }

    @Test func emptyAndShortListsReclaimVerticalSpace() {
        let empty = MidasPanelLayout.height(providerCount: 0, availableHeight: 900)
        let one = MidasPanelLayout.height(providerCount: 1, availableHeight: 900)
        let three = MidasPanelLayout.height(providerCount: 3, availableHeight: 900)
        #expect(empty >= 200)
        #expect(empty < one)
        #expect(one < three)
        #expect(three <= MidasPanelLayout.maximumHeight)
        #expect(MidasPanelLayout.height(providerCount: -1, availableHeight: 900) == empty)
    }

    @Test func largeProviderListsAndDetailsStayWithinTheSameMaximum() {
        let crowded = MidasPanelLayout.height(providerCount: 100, availableHeight: 900)
        let detail = MidasPanelLayout.height(providerCount: 1, availableHeight: 900, showsDetail: true)
        #expect(crowded == MidasPanelLayout.maximumHeight)
        #expect(detail == MidasPanelLayout.maximumHeight)
    }

    @Test func shortScreensLeaveRoomForTheMenuBarAndPopoverAnchor() {
        for count in [0, 1, 3, 100] {
            for detail in [false, true] {
                let height = MidasPanelLayout.height(providerCount: count, availableHeight: 400, showsDetail: detail)
                #expect(height >= 200)
                #expect(height <= 352)
            }
        }
    }
}
