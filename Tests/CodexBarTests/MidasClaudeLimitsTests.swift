import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MidasClaudeLimitsTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func window(_ used: Double, minutes: Int?, resetIn seconds: TimeInterval) -> RateWindow {
        RateWindow(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: Self.now.addingTimeInterval(seconds),
            resetDescription: nil)
    }

    private func presentation(
        primary: RateWindow?,
        secondary: RateWindow?,
        tertiary: RateWindow? = nil,
        extraRateWindows: [NamedRateWindow]? = nil) throws -> MidasProviderPresentation
    {
        let snapshot = UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            extraRateWindows: extraRateWindows,
            updatedAt: Self.now,
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Max"))
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
            now: Self.now))
        return MidasProviderPresentation.make(
            provider: .claude,
            card: card,
            snapshot: snapshot,
            tokenSnapshot: nil,
            isRefreshing: false,
            isStale: false)
    }

    @Test
    func `overview always shows five hour and weekly limits even when both are healthy`() throws {
        let presentation = try self.presentation(
            primary: self.window(20, minutes: 300, resetIn: 3600),
            secondary: self.window(10, minutes: 10080, resetIn: 86400))

        let overview = MidasAccountQuotaLayout.overviewMetrics(presentation)

        #expect(overview.map(\.title) == [MidasClaudeLimits.fiveHourTitle, MidasClaudeLimits.weeklyTitle])
        #expect(overview.map(\.valueText) == ["80% left", "90% left"])
        #expect(overview[0].resetsAt == Self.now.addingTimeInterval(3600))
        #expect(overview[1].resetsAt == Self.now.addingTimeInterval(86400))
        #expect(presentation.hero?.title == MidasClaudeLimits.fiveHourTitle)
    }

    @Test
    func `weekly limit stays visible when it is the tighter limit`() throws {
        let presentation = try self.presentation(
            primary: self.window(5, minutes: 300, resetIn: 3600),
            secondary: self.window(70, minutes: 10080, resetIn: 86400))

        let overview = MidasAccountQuotaLayout.overviewMetrics(presentation)

        #expect(overview.map(\.id) == ["primary", "secondary"])
        #expect(overview.map(\.remainingPercent) == [95, 30])
    }

    @Test
    func `weekly-only primary is labeled weekly instead of five hour`() throws {
        // Claude falls back to a seven-day window in the primary slot when no 5-hour window is reported.
        let presentation = try self.presentation(
            primary: self.window(40, minutes: 10080, resetIn: 86400),
            secondary: nil)

        let overview = MidasAccountQuotaLayout.overviewMetrics(presentation)

        #expect(overview.map(\.title) == [MidasClaudeLimits.weeklyTitle])
        #expect(overview.first?.valueText == "60% left")
    }

    @Test
    func `duplicate weekly fallback is shown once`() throws {
        let presentation = try self.presentation(
            primary: self.window(40, minutes: 10080, resetIn: 86400),
            secondary: self.window(40, minutes: 10080, resetIn: 86400))

        let overview = MidasAccountQuotaLayout.overviewMetrics(presentation)

        #expect(overview.map(\.title) == [MidasClaudeLimits.weeklyTitle])
        #expect(overview.first?.id == "secondary")
    }

    @Test
    func `window length missing still reads as the five hour session`() throws {
        let presentation = try self.presentation(
            primary: self.window(50, minutes: nil, resetIn: 3600),
            secondary: self.window(10, minutes: 10080, resetIn: 86400))

        #expect(MidasAccountQuotaLayout.overviewMetrics(presentation).map(\.title)
            == [MidasClaudeLimits.fiveHourTitle, MidasClaudeLimits.weeklyTitle])
    }

    @Test
    func `model specific weekly window follows the limits and only surfaces when tight`() throws {
        let healthy = try self.presentation(
            primary: self.window(20, minutes: 300, resetIn: 3600),
            secondary: self.window(10, minutes: 10080, resetIn: 86400),
            tertiary: self.window(15, minutes: 10080, resetIn: 86400))
        #expect(MidasAccountQuotaLayout.overviewMetrics(healthy).map(\.id) == ["primary", "secondary"])
        #expect(MidasAccountQuotaLayout.allMetrics(healthy).map(\.id) == ["primary", "secondary", "tertiary"])

        let exhausted = try self.presentation(
            primary: self.window(20, minutes: 300, resetIn: 3600),
            secondary: self.window(10, minutes: 10080, resetIn: 86400),
            tertiary: self.window(100, minutes: 10080, resetIn: 86400))
        #expect(MidasAccountQuotaLayout.overviewMetrics(exhausted).map(\.id) == ["primary", "secondary", "tertiary"])
    }

    @Test
    func `fable only weekly limit is always pinned beside the five hour and weekly limits`() throws {
        let fable = NamedRateWindow(
            id: "claude-weekly-scoped-fable",
            title: "Fable only",
            window: self.window(5, minutes: 10080, resetIn: 86400))
        let presentation = try self.presentation(
            primary: self.window(20, minutes: 300, resetIn: 3600),
            secondary: self.window(10, minutes: 10080, resetIn: 86400),
            extraRateWindows: [fable])

        let overview = MidasAccountQuotaLayout.overviewMetrics(presentation)

        #expect(overview.map(\.id) == ["primary", "secondary", "claude-weekly-scoped-fable"])
        #expect(overview.map(\.title) == [
            MidasClaudeLimits.fiveHourTitle,
            MidasClaudeLimits.weeklyTitle,
            "Fable weekly limit",
        ])
        #expect(overview[2].valueText == "95% left")
        #expect(overview[2].resetsAt == Self.now.addingTimeInterval(86400))
        #expect(overview[2].resetText?.isEmpty == false)
        #expect(overview[2].helpText?.contains("Fable only") == true)
        #expect(overview[2].helpText?.contains("all-models weekly limit still applies") == true)
        #expect(presentation.hero?.title == MidasClaudeLimits.fiveHourTitle)
    }

    @Test
    func `exhausted fable limit reads as exhausted while other limits have room`() throws {
        let presentation = try self.presentation(
            primary: self.window(20, minutes: 300, resetIn: 3600),
            secondary: self.window(30, minutes: 10080, resetIn: 86400),
            extraRateWindows: [NamedRateWindow(
                id: "claude-weekly-scoped-fable",
                title: "Fable only",
                window: self.window(100, minutes: 10080, resetIn: 86400))])

        let fable = try #require(MidasAccountQuotaLayout.overviewMetrics(presentation).last)

        #expect(fable.title == "Fable weekly limit")
        #expect(fable.isExhausted)
        #expect(fable.valueText == "0% left")
    }

    @Test
    func `unknown fable usage is not drawn as a bar`() throws {
        let presentation = try self.presentation(
            primary: self.window(20, minutes: 300, resetIn: 3600),
            secondary: self.window(10, minutes: 10080, resetIn: 86400),
            extraRateWindows: [NamedRateWindow(
                id: "claude-weekly-scoped-fable",
                title: "Fable only",
                window: self.window(0, minutes: 10080, resetIn: 86400),
                usageKnown: false)])

        #expect(MidasAccountQuotaLayout.overviewMetrics(presentation).map(\.id) == ["primary", "secondary"])
    }

    @Test
    func `model weekly titles follow the model claude names`() {
        #expect(MidasClaudeLimits.modelWeeklyTitle("Fable only") == "Fable weekly limit")
        #expect(MidasClaudeLimits.modelWeeklyTitle("Opus 5 only") == "Opus 5 weekly limit")
        #expect(MidasClaudeLimits.modelWeeklyTitle("Sonnet") == "Sonnet weekly limit")
        #expect(MidasClaudeLimits.modelWeeklyTitle("  ") == MidasClaudeLimits.weeklyTitle)
    }

    @Test
    func `other providers keep the single-hero overview`() {
        let codex = MidasProviderPresentation.make(
            provider: .codex,
            card: nil,
            snapshot: UsageSnapshot(
                primary: self.window(20, minutes: 300, resetIn: 3600),
                secondary: self.window(10, minutes: 10080, resetIn: 86400),
                updatedAt: Self.now),
            tokenSnapshot: nil,
            isRefreshing: false,
            isStale: false)

        #expect(MidasAccountQuotaLayout.overviewMetrics(codex).map(\.id) == ["secondary"])
    }
}
