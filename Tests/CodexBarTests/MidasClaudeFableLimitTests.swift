import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// End to end: a Claude usage response carrying a Fable-only weekly limit reaches the Air overview
/// as a pinned bar next to the 5-hour and weekly limits.
struct MidasClaudeFableLimitTests {
    @Test
    func `oauth fable scoped limit becomes a pinned overview bar`() throws {
        // Shape of the claude.ai usage endpoint's `limits[]` rows as documented by Claude Code 2.1.281:
        // kind/group/percent/resets_at/scope.model.display_name/severity/is_active. Classify on `kind`,
        // never on a label; `is_active` marks the headline row only.
        let json = """
        {
          "five_hour": { "utilization": 12.0, "resets_at": "2026-09-24T20:00:00.000000+00:00" },
          "seven_day": { "utilization": 40.0, "resets_at": "2026-09-29T09:00:00.000000+00:00" },
          "seven_day_opus": null,
          "seven_day_sonnet": null,
          "limits": [
            { "kind": "session", "group": "session", "percent": 12,
              "resets_at": "2026-09-24T20:00:00.000000+00:00", "scope": null,
              "severity": "normal", "is_active": false },
            { "kind": "weekly_all", "group": "weekly", "percent": 40,
              "resets_at": "2026-09-29T09:00:00.000000+00:00", "scope": null,
              "severity": "normal", "is_active": false },
            { "kind": "weekly_scoped", "group": "weekly", "percent": 75,
              "resets_at": "2026-09-29T09:00:00.000000+00:00",
              "scope": { "model": { "display_name": "Fable" }, "surface": null },
              "severity": "warning", "is_active": true }
          ]
        }
        """
        let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8), subscriptionType: "max")
        let snapshot = ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage)
        let now = try #require(snapshot.updatedAt as Date?)
        let card = try UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: #require(ProviderDefaults.metadata[.claude]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: false,
            hidePersonalInfo: false,
            now: now))
        let presentation = MidasProviderPresentation.make(
            provider: .claude,
            card: card,
            snapshot: snapshot,
            tokenSnapshot: nil,
            isRefreshing: false,
            isStale: false)

        let overview = MidasAccountQuotaLayout.overviewMetrics(presentation)

        #expect(overview.map(\.title) == [
            MidasClaudeLimits.fiveHourTitle,
            MidasClaudeLimits.weeklyTitle,
            "Fable weekly limit",
        ])
        #expect(overview.map(\.valueText) == ["88% left", "60% left", "25% left"])
        #expect(overview.last?.resetsAt != nil)
    }

    /// Opt-in export uses synthetic data only; it never initializes stores or probes credentials.
    @Test @MainActor
    func `export claude fable overview when requested`() throws {
        guard let output = ProcessInfo.processInfo.environment["MIDAS_PREVIEW_OUTPUT"] else { return }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let now = Date()
        func window(_ used: Double, minutes: Int, hours: Double) -> RateWindow {
            RateWindow(
                usedPercent: used,
                windowMinutes: minutes,
                resetsAt: now.addingTimeInterval(hours * 3600),
                resetDescription: nil)
        }
        for (label, fableUsed) in [("fable-healthy", 35.0), ("fable-exhausted", 100.0)] {
            let snapshot = UsageSnapshot(
                primary: window(12, minutes: 300, hours: 3),
                secondary: window(40, minutes: 10080, hours: 110),
                extraRateWindows: [NamedRateWindow(
                    id: "claude-weekly-scoped-fable",
                    title: "Fable only",
                    window: window(fableUsed, minutes: 10080, hours: 110))],
                updatedAt: now)
            let card = try UsageMenuCardView.Model.make(.init(
                provider: .claude,
                metadata: #require(ProviderDefaults.metadata[.claude]),
                snapshot: snapshot,
                credits: nil,
                creditsError: nil,
                dashboard: nil,
                dashboardError: nil,
                tokenSnapshot: nil,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: nil),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: false,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: false,
                hidePersonalInfo: false,
                now: now))
            let presentation = MidasProviderPresentation.make(
                provider: .claude,
                card: card,
                snapshot: snapshot,
                tokenSnapshot: nil,
                isRefreshing: false,
                isStale: false)
            for scheme in [ColorScheme.light, .dark] {
                let view = MidasOverviewMetrics(item: presentation)
                    .padding(20).frame(width: 360, alignment: .topLeading)
                    .background(MidasTheme.background).environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try #require(renderer.nsImage)
                let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                let name = "midas-claude-\(label)-\(scheme == .dark ? "dark" : "light").png"
                try png.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
            }
        }
    }

    @Test
    func `surface scoped rows are not treated as model limits`() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.0, "resets_at": "2026-09-24T20:00:00.000000+00:00" },
          "seven_day": { "utilization": 40.0, "resets_at": "2026-09-29T09:00:00.000000+00:00" },
          "limits": [
            { "kind": "weekly_scoped", "group": "weekly", "percent": 10,
              "resets_at": "2026-09-29T09:00:00.000000+00:00",
              "scope": { "model": null, "surface": { "display_name": "Claude Design" } },
              "severity": "normal", "is_active": false }
          ]
        }
        """
        let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(usage.extraRateWindows.contains { MidasClaudeLimits.isModelWeekly($0.id) } == false)
    }
}
