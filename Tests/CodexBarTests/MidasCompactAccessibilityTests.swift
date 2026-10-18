import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MidasCompactAccessibilityTests {
    @Test func summaryIncludesSpendMeaningAndExactCents() throws {
        let item = self.presentation(provider: .codex, metrics: [self.metric("secondary", "This week", 72)])
        let spend = try #require(item.spend)
        let summary = MidasCompactAccessibility.summary(item)
        #expect(summary.contains(spend.accessibilityTitle))
        #expect(summary.contains(MidasOverviewMoney.format(128.42, currency: "USD")))
        #expect(summary.contains("This week"))
        #expect(summary.contains("72% left"))
    }

    @Test func claudeSummaryAnnouncesBothIndependentWindows() {
        let item = self.presentation(provider: .claude, metrics: [
            self.metric("primary", MidasClaudeLimits.fiveHourTitle, 85),
            self.metric("secondary", MidasClaudeLimits.weeklyTitle, 72),
        ])
        let summary = MidasCompactAccessibility.summary(item)
        #expect(summary.contains("5-hour limit"))
        #expect(summary.contains("85% left"))
        #expect(summary.contains("Weekly limit"))
        #expect(summary.contains("72% left"))
        #expect(!summary.contains("157%"))
    }

    @Test func cursorSummaryAnnouncesEveryPinnedPoolAndItsOwnBalance() {
        let item = self.presentation(provider: .cursor, metrics: [
            self.metric("primary", "Total", 70),
            self.metric(MidasCursorLimits.cursorModelsID, "Cursor Models", 80),
            self.metric(MidasCursorLimits.otherModelsID, "Other Models", 55),
            self.metric(MidasCursorLimits.grokBotID, MidasCursorLimits.grokBotWeeklyTitle, 20),
        ])
        let summary = MidasCompactAccessibility.summary(item)
        for text in ["Cursor Models", "80% left", "Other Models", "55% left", "Grok Bot weekly", "20% left"] {
            #expect(summary.contains(text))
        }
        #expect(!summary.contains("155%"))
    }

    @Test func accountSummaryKeepsNamesAndBalancesSeparateWithoutSumming() {
        let first = self.presentation(provider: .codex, metrics: [self.metric("secondary", "This week", 72)])
        let second = self.presentation(provider: .codex, metrics: [self.metric("secondary", "This week", 46)])
        let accounts = [
            MidasAccountPresentation(id: "personal", isPrimary: true, presentation: first, displayName: "Personal"),
            MidasAccountPresentation(id: "work", isPrimary: false, presentation: second, displayName: "Work"),
        ]
        let summary = MidasCompactAccessibility.summary(first, accounts: accounts)
        for text in ["Personal", "72% left", "Work", "46% left"] {
            #expect(summary.contains(text))
        }
        #expect(!summary.contains("118%"))
        #expect(!summary.contains("59%"))
    }

    @Test func unavailableUsageDoesNotBecomeExhaustedOrFullCapacity() {
        let summary = MidasCompactAccessibility.summary(self.presentation(provider: .codex, metrics: []))
        #expect(summary.localizedCaseInsensitiveContains("unavailable"))
        #expect(!summary.contains("0%"))
        #expect(!summary.contains("100%"))
    }

    @Test func exhaustedLastKnownUsageRetainsZeroAndDisclosesStaleness() {
        let item = self.presentation(
            provider: .codex,
            metrics: [self.metric("secondary", "This week", 0)],
            stale: true)
        let summary = MidasCompactAccessibility.summary(item)
        #expect(summary.contains("0% left"))
        #expect(summary.localizedCaseInsensitiveContains("last known")
            || summary.localizedCaseInsensitiveContains("stale")
            || summary.localizedCaseInsensitiveContains("outdated"))
    }

    @Test func metaFallbackNamesTheRecordedBaselineAndAbsenceOfPlanQuota() {
        var item = self.presentation(provider: .meta, metrics: [])
        item.activityMetrics = [MidasActivityMetric(
            id: "meta-activity-today",
            title: "Today",
            tokens: 1000,
            requests: 4,
            sharePercent: 25,
            remainingPercent: 75,
            remainingTokens: 3000,
            comparisonTokens: 4000,
            comparisonLabel: "busiest recorded day",
            hasBaseline: true)]
        let summary = MidasCompactAccessibility.summary(item)
        #expect(summary.contains("Today"))
        #expect(summary.contains("75% left"))
        #expect(summary.localizedCaseInsensitiveContains("busiest recorded"))
        #expect(summary.localizedCaseInsensitiveContains("no reported plan limit")
            || summary.localizedCaseInsensitiveContains("no plan limit"))
    }

    private func metric(_ id: String, _ title: String, _ remaining: Double) -> MidasQuotaMetric {
        MidasQuotaMetric(
            id: id,
            title: title,
            remainingPercent: remaining,
            resetText: "Resets in 2d 4h",
            helpText: nil)
    }

    private func presentation(
        provider: UsageProvider,
        metrics: [MidasQuotaMetric],
        stale: Bool = false) -> MidasProviderPresentation
    {
        let now = Date(timeIntervalSince1970: 1_792_238_400)
        let cost = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 820_000,
            last30DaysCostUSD: 128.42,
            costProvenance: .listPriceEstimate,
            daily: [],
            updatedAt: now)
        return MidasProviderPresentation(
            provider: provider,
            name: ProviderDefaults.metadata[provider]?.displayName ?? provider.rawValue,
            account: "Synthetic account",
            plan: "Pro",
            hero: metrics.first,
            metrics: Array(metrics.dropFirst()),
            resetCreditsText: nil,
            resetCreditsHelp: nil,
            freshness: stale ? "Last known usage" : "Updated just now",
            error: nil,
            placeholder: "Usage unavailable",
            notes: [],
            financialSummary: nil,
            financialLabel: nil,
            spend: MidasSpendPresentation.make(provider: provider, snapshot: cost),
            isRefreshing: false,
            isStale: stale,
            updatedAt: now)
    }
}
