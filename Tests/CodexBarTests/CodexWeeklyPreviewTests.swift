import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexWeeklyPreviewTests {
    @Test(arguments: [0.0, 25.0, 100.0])
    func weeklyRemainingIgnoresSessionAndDisplayPreference(used: Double) {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 91, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: used, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())
        for showUsed in [false, true] {
            let resolved = IconRemainingResolver.resolvedPercents(
                snapshot: snapshot, style: .codex, showUsed: showUsed)
            #expect(resolved.primary == 100 - used)
            #expect(resolved.secondary == nil)
            #expect(StatusItemController.switcherWeeklyMetricPercent(
                for: .codex, snapshot: snapshot, showUsed: showUsed) == 100 - used)
        }
    }

    @Test
    func missingWeeklyDoesNotFallBackToSession() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let resolved = IconRemainingResolver.resolvedRemaining(snapshot: snapshot, style: .codex)
        #expect(resolved.primary == nil)
        #expect(resolved.secondary == nil)
        #expect(StatusItemController.switcherWeeklyMetricPercent(
            for: .codex, snapshot: snapshot, showUsed: false) == nil)
    }

    @Test
    func weeklyInPrimarySlotUsesSemanticLane() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 37, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let resolved = IconRemainingResolver.resolvedRemaining(snapshot: snapshot, style: .codex)
        #expect(resolved.primary == 63)
        #expect(resolved.secondary == nil)
    }

    @Test(arguments: [nil, 0.0, 75.0, 100.0] as [Double?])
    func rendererDrawsOneCenteredBarWithNoCreditFallback(remaining: Double?) throws {
        let image = IconRenderer.makeIcon(
            primaryRemaining: remaining,
            weeklyRemaining: nil,
            creditsRemaining: 1000,
            stale: false,
            style: .codex)
        let rep = try #require(image.representations.compactMap { $0 as? NSBitmapImageRep }
            .first { $0.pixelsWide == 36 && $0.pixelsHigh == 36 })
        let occupiedRows = (0..<36).filter { y in
            (0..<36).contains { x in (rep.colorAt(x: x, y: y) ?? .clear).alphaComponent > 0.05 }
        }
        let first = try #require(occupiedRows.first)
        let last = try #require(occupiedRows.last)
        #expect(first >= 11)
        #expect(last <= 24)
        #expect(occupiedRows.count == last - first + 1)
    }
}
