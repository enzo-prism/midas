import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct ClaudeCLIScopedWeeklyLimitTests {
    @Test
    func `CLI usage surfaces Fable scoped weekly limit`() async throws {
        let cliUsage = """
        Settings  Status  Config  Usage  Stats

        Current session
        9% used
        Resets 2:09pm (Europe/Prague)

        Current week (all models)
        67% used
        Resets Jul 10 t 2:59am (Europe/Prague)

        Current week (Fable)
        68% used
        Reset Jul 10 at 2:59am (Europe/Prague)

        Current week (Compass)
        12% used
        """
        let status = try ClaudeStatusProbe.parse(text: cliUsage)
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .cli)
        let fetchOverride: ClaudeStatusProbe.FetchOverride = { _, _, _ in status }

        let snapshot = try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/usr/bin/true") {
            try await ClaudeStatusProbe.withFetchOverrideForTesting(fetchOverride) {
                try await fetcher.loadLatestUsage(model: "sonnet")
            }
        }

        let fable = try #require(snapshot.extraRateWindows.first { $0.id == "claude-weekly-scoped-fable" })
        #expect(fable.title == "Fable only")
        #expect(fable.window.usedPercent == 68)
        #expect(fable.window.resetDescription == "Reset Jul 10 at 2:59am (Europe/Prague)")
        let compass = try #require(snapshot.extraRateWindows.first { $0.id == "claude-weekly-scoped-compass" })
        #expect(compass.title == "Compass only")
        #expect(compass.window.usedPercent == 12)
        #expect(compass.window.resetDescription == "Resets Jul 10 at 2:59am (Europe/Prague)")
        #expect(snapshot.opus == nil)
    }

    @Test
    func `web extra windows merge with CLI scoped weekly limits`() {
        let fable = NamedRateWindow(
            id: "claude-weekly-scoped-fable",
            title: "Fable only",
            window: RateWindow(
                usedPercent: 68,
                windowMinutes: 7 * 24 * 60,
                resetsAt: nil,
                resetDescription: "Resets Jul 10 at 2:59am (Europe/Prague)"))
        let webFable = NamedRateWindow(
            id: "claude-weekly-scoped-fable",
            title: "Fable only",
            window: RateWindow(
                usedPercent: 70,
                windowMinutes: 7 * 24 * 60,
                resetsAt: nil,
                resetDescription: "Resets Jul 10 at 2:59am (Europe/Prague)"))
        let routines = NamedRateWindow(
            id: "claude-routines",
            title: "Daily Routines",
            window: RateWindow(
                usedPercent: 11,
                windowMinutes: 7 * 24 * 60,
                resetsAt: nil,
                resetDescription: nil))

        let merged = ClaudeUsageFetcher._mergeExtraRateWindowsForTesting(
            primary: [fable],
            web: [webFable, routines])

        #expect(merged.map(\.id) == ["claude-weekly-scoped-fable", "claude-routines"])
        #expect(merged.first?.window.usedPercent == 68)
        #expect(merged.last?.title == "Daily Routines")
    }
}
