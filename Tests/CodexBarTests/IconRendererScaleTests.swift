import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct IconRendererScaleTests {
    @Test func explicitScaleControlsBitmapSize() {
        for scale: CGFloat in [1, 2] {
            let image = IconRenderer.makeIcon(
                primaryRemaining: 72,
                weeklyRemaining: 41,
                creditsRemaining: nil,
                stale: false,
                style: .codex,
                renderScale: scale)
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 18, height: 18))
            let rep = try? #require(self.bitmapRep(in: image))
            #expect(rep?.pixelsWide == Int(18 * scale))
            #expect(rep?.pixelsHigh == Int(18 * scale))
            // Points stay 18×18 so the button keeps its 1:1 (scaleNone) rendering.
            #expect(rep?.size == NSSize(width: 18, height: 18))
        }
    }

    @Test func defaultScaleMatchesMenuBarScreen() {
        let image = IconRenderer.makeIcon(
            primaryRemaining: 55,
            weeklyRemaining: 33,
            creditsRemaining: nil,
            stale: false,
            style: .claude)
        let expectedPx = Int(18 * MidasMenuBarLayout.currentMenuBarRenderScale)
        let rep = try? #require(self.bitmapRep(in: image))
        #expect(rep?.pixelsWide == expectedPx)
        #expect(rep?.pixelsHigh == expectedPx)
        #expect(image.isTemplate)
    }

    @Test func invalidScaleOverrideFallsBackToTwo() {
        for override: CGFloat in [0, -1, .nan, .infinity] {
            let image = IconRenderer.makeIcon(
                primaryRemaining: 90,
                weeklyRemaining: 80,
                creditsRemaining: nil,
                stale: false,
                style: .gemini,
                renderScale: override)
            let rep = try? #require(self.bitmapRep(in: image))
            #expect(rep?.pixelsWide == 36)
            #expect(rep?.pixelsHigh == 36)
        }
    }

    @Test func cacheSeparatesScales() {
        // Same artwork inputs at two scales must not share a cached bitmap.
        let twoX = IconRenderer.makeIcon(
            primaryRemaining: 63.3,
            weeklyRemaining: 17.7,
            creditsRemaining: nil,
            stale: false,
            style: .warp,
            renderScale: 2)
        let oneX = IconRenderer.makeIcon(
            primaryRemaining: 63.3,
            weeklyRemaining: 17.7,
            creditsRemaining: nil,
            stale: false,
            style: .warp,
            renderScale: 1)
        #expect(self.bitmapRep(in: twoX)?.pixelsWide == 36)
        #expect(self.bitmapRep(in: oneX)?.pixelsWide == 18)
    }

    @Test func oneXArtworkKeepsLayoutAndDrawsContent() {
        let image = IconRenderer.makeIcon(
            primaryRemaining: 72,
            weeklyRemaining: 41,
            creditsRemaining: nil,
            stale: false,
            style: .codex,
            renderScale: 1)
        let rep = try? #require(self.bitmapRep(in: image))
        guard let rep else { return }
        // Layout is authored at the 2× reference grid, so the 1× raster must still
        // carry the full composition (not an overflowing or empty canvas).
        var painted = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y) ?? .clear).alphaComponent > 0.05 {
                painted += 1
            }
        }
        #expect(painted > 20)
        // Center column stays painted (bars span the middle of the canvas).
        let midX = rep.pixelsWide / 2
        let midPainted = (0..<rep.pixelsHigh).contains {
            (rep.colorAt(x: midX, y: $0) ?? .clear).alphaComponent > 0.05
        }
        #expect(midPainted)
    }

    @Test func morphIconFollowsScale() {
        for scale: CGFloat in [1, 2] {
            let image = IconRenderer.makeMorphIcon(progress: 0.4, style: .codex, renderScale: scale)
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 18, height: 18))
            let rep = try? #require(self.bitmapRep(in: image))
            #expect(rep?.pixelsWide == Int(18 * scale))
            #expect(rep?.pixelsHigh == Int(18 * scale))
        }
    }

    private func bitmapRep(in image: NSImage) -> NSBitmapImageRep? {
        image.representations.compactMap { $0 as? NSBitmapImageRep }.first
    }
}
