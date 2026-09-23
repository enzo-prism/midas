import Foundation
import Testing
@testable import CodexBarCore
@testable import CodexBarWidget

struct CodexBarAppShortcutsTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func `shortcuts donate check switch and spend actions`() {
        #expect(CodexBarShortcuts.appShortcuts.count == 3)
    }

    @Test
    func `check usage intent defaults to codex`() {
        #expect(CheckUsageIntent().provider == .codex)
        #expect(CheckUsageIntent(provider: .claude).provider == .claude)
    }

    @Test
    func `switch provider intent keeps provider for donation`() {
        #expect(SwitchWidgetProviderIntent(provider: .gemini).provider == .gemini)
    }

    @Test
    func `check usage summary reports missing snapshot`() {
        let summary = CheckUsageIntent.summary(snapshot: nil, provider: .codex)

        #expect(summary.contains("No Codex usage data yet"))
    }

    @Test
    func `check usage summary reports missing provider entry`() {
        let snapshot = WidgetSnapshot(entries: [], enabledProviders: [], generatedAt: Self.now)

        let summary = CheckUsageIntent.summary(snapshot: snapshot, provider: .claude)

        #expect(summary.contains("No Claude usage data yet"))
    }

    @Test
    func `check usage summary speaks rate rows and credits`() {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .codex,
            updatedAt: Self.now,
            primary: RateWindow(usedPercent: 35, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 60, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            creditsRemaining: 1243.4,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
        let snapshot = WidgetSnapshot(entries: [entry], generatedAt: Self.now)

        let summary = CheckUsageIntent.summary(snapshot: snapshot, provider: .codex)

        #expect(summary.contains("Codex:"))
        #expect(summary.contains("Session 65 percent left"))
        #expect(summary.contains("Weekly 40 percent left"))
        #expect(summary.contains("credits left"))
    }

    @Test
    func `check usage summary speaks session and 30d cost`() {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .claude,
            updatedAt: Self.now,
            primary: nil,
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: WidgetSnapshot.TokenUsageSummary(
                sessionCostUSD: 12.4,
                sessionTokens: 420_000,
                last30DaysCostUSD: 923.8,
                last30DaysTokens: 12_400_000),
            dailyUsage: [])
        let snapshot = WidgetSnapshot(entries: [entry], generatedAt: Self.now)

        let summary = CheckUsageIntent.summary(snapshot: snapshot, provider: .claude)

        #expect(summary.contains("Today cost"))
        #expect(summary.contains("12.40"))
        #expect(summary.contains("30d cost"))
        #expect(summary.contains("923.80"))
    }

    @Test
    func `spend summary reports missing snapshot`() {
        #expect(OpenSpendPanelIntent.spendSummary(snapshot: nil).contains("No spend data yet"))
    }

    @Test
    func `spend summary reports entries without token usage`() {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .codex,
            updatedAt: Self.now,
            primary: nil,
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
        let snapshot = WidgetSnapshot(entries: [entry], generatedAt: Self.now)

        #expect(OpenSpendPanelIntent.spendSummary(snapshot: snapshot).contains("No spend data yet"))
    }

    @Test
    func `spend summary names single provider total`() {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .codex,
            updatedAt: Self.now,
            primary: nil,
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: WidgetSnapshot.TokenUsageSummary(
                sessionCostUSD: nil,
                sessionTokens: nil,
                last30DaysCostUSD: 923.8,
                last30DaysTokens: nil),
            dailyUsage: [])
        let snapshot = WidgetSnapshot(entries: [entry], generatedAt: Self.now)

        let summary = OpenSpendPanelIntent.spendSummary(snapshot: snapshot)

        #expect(summary.contains("Codex 30-day spend is"))
        #expect(summary.contains("923.80"))
    }

    @Test
    func `spend summary totals multiple providers`() {
        let codex = WidgetSnapshot.ProviderEntry(
            provider: .codex,
            updatedAt: Self.now,
            primary: nil,
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: WidgetSnapshot.TokenUsageSummary(
                sessionCostUSD: nil,
                sessionTokens: nil,
                last30DaysCostUSD: 100,
                last30DaysTokens: nil),
            dailyUsage: [])
        let claude = WidgetSnapshot.ProviderEntry(
            provider: .claude,
            updatedAt: Self.now,
            primary: nil,
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: WidgetSnapshot.TokenUsageSummary(
                sessionCostUSD: nil,
                sessionTokens: nil,
                last30DaysCostUSD: 23.8,
                last30DaysTokens: nil),
            dailyUsage: [])
        let snapshot = WidgetSnapshot(entries: [codex, claude], generatedAt: Self.now)

        let summary = OpenSpendPanelIntent.spendSummary(snapshot: snapshot)

        #expect(summary.contains("Total 30-day spend is"))
        #expect(summary.contains("123.80"))
        #expect(summary.contains("across 2 providers"))
    }
}
