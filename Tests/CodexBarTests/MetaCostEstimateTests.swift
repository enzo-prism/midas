import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

struct MetaCostEstimateTests {
    @Test
    func `classifies muse pricing tiers`() {
        #expect(CostUsagePricing.metaPricingTier(forModel: "muse-spark-1.3-contributor") == .contributor)
        #expect(CostUsagePricing.metaPricingTier(forModel: "gpt-5") == nil)
        #expect(CostUsagePricing.metaPricingTier(forModel: "muse-spark-1.2") == .standard)
        #expect(CostUsagePricing.metaPricingTier(forModel: "parakeet-tdt-0.6b-v3") == nil)
        #expect(CostUsagePricing.metaPricingTier(forModel: "") == nil)
        #expect(
            CostUsagePricing.metaPricingTier(forModels: ["muse-spark-1.3-contributor"]) == .contributor)
        #expect(CostUsagePricing.metaPricingTier(forModels: []) == nil)
        #expect(
            CostUsagePricing.metaPricingTier(
                forModels: ["muse-spark-1.3-contributor", "muse-spark-1.2"]) == nil)
    }

    @Test
    func `prices tokens at both tiers`() {
        // Contributor: 1M in * $0.10 + 1M out * $0.20 + 1M cached * $0.002, reasoning at output rate.
        let contributor = CostUsagePricing.metaCost(
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            reasoningTokens: 1_000_000,
            cacheReadTokens: 1_000_000,
            tier: .contributor)
        #expect(abs(contributor - 0.502) < 1e-9)
        // Standard: 1M in * $1.25 + 1M out * $4.25 + 1M cached * $0.15.
        let standard = CostUsagePricing.metaCost(
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            reasoningTokens: 1_000_000,
            cacheReadTokens: 1_000_000,
            tier: .standard)
        #expect(abs(standard - 9.9) < 1e-9)
    }

    @Test
    func `list price prefers standard equivalent for meta`() {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let meta = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 100,
            last30DaysCostUSD: 0.01,
            last30DaysAPIEquivalentCostUSD: 0.2,
            daily: [],
            updatedAt: now)
        #expect(CostUsageFetcher.listPriceCostUSD(provider: .meta, snapshot: meta) == 0.2)

        let metaFallback = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 100,
            last30DaysCostUSD: 0.01,
            daily: [],
            updatedAt: now)
        #expect(CostUsageFetcher.listPriceCostUSD(provider: .meta, snapshot: metaFallback) == 0.01)
        #expect(CostUsageFetcher.listPriceCostUSD(provider: .codex, snapshot: metaFallback) == 0.01)
    }

    @Test
    func `renders token sparkline`() {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let empty = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            daily: [],
            updatedAt: now)
        #expect(CodexBarCLI.tokenSparkline(from: empty) == nil)

        let entries = (1...5).map { day in
            CostUsageDailyReport.Entry(
                date: "2026-09-0\(day)",
                inputTokens: day * 100,
                outputTokens: 10,
                totalTokens: day * 100 + 10,
                costUSD: 0.01,
                modelsUsed: nil,
                modelBreakdowns: nil)
        }
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 1530,
            last30DaysCostUSD: 0.05,
            historyDays: 5,
            daily: entries,
            updatedAt: now)
        let sparkline = CodexBarCLI.tokenSparkline(from: snapshot)
        #expect(sparkline?.count == 5)
        #expect(sparkline?.allSatisfy { "▁▂▃▄▅▆▇█".contains($0) } == true)
    }

    @Test
    func `renders cross provider total`() {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        func snapshot(tokens: Int, cost: Double?) -> CostUsageTokenSnapshot {
            CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: tokens,
                last30DaysCostUSD: cost,
                daily: [],
                updatedAt: now)
        }
        let total = CodexBarCLI.renderTotalSection(
            [
                (provider: UsageProvider.codex, snapshot: snapshot(tokens: 1000, cost: 1.5)),
                (provider: UsageProvider.claude, snapshot: snapshot(tokens: 2000, cost: 2.5)),
                (provider: UsageProvider.meta, snapshot: CostUsageTokenSnapshot(
                    sessionTokens: nil,
                    sessionCostUSD: nil,
                    last30DaysTokens: 4000,
                    last30DaysCostUSD: 0.01,
                    last30DaysAPIEquivalentCostUSD: 0.25,
                    daily: [],
                    updatedAt: now)),
            ],
            useColor: false)
        let text = try? #require(total)
        #expect(text?.contains("Total: $4.25") == true)
        #expect(text?.contains("7K tokens") == true)
        #expect(text?.contains("Meta") == true)
    }

    @Test
    func `meta card hides window rows`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.meta])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .meta,
            metadata: metadata,
            snapshot: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 0,
                    windowMinutes: 24 * 60,
                    resetsAt: nil,
                    resetDescription: "1.1M today"),
                secondary: RateWindow(
                    usedPercent: 0,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: nil,
                    resetDescription: "2.2M last 7d"),
                tertiary: nil,
                updatedAt: now,
                identity: nil),
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
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        // The 30-day token + cost section (tokenSnapshot) carries the Meta card;
        // daily/weekly window rows stay out.
        #expect(model.metrics.isEmpty)
    }

    @Test
    func `meta cost text skips today line`() {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 100,
            sessionCostUSD: 0.01,
            last30DaysTokens: 300,
            last30DaysCostUSD: 0.03,
            last30DaysAPIEquivalentCostUSD: 0.4,
            daily: [],
            updatedAt: now)
        let output = CodexBarCLI.renderCostText(provider: .meta, snapshot: snapshot, useColor: false)

        #expect(!output.contains("Today:"))
        #expect(output.contains("tokens"))
        #expect(output.contains("At standard API rates:"))
    }

    @Test
    func `meta menu dashboard shows graphic and api equivalent`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.meta])
        let daily = [
            CostUsageDailyReport.Entry(
                date: "2026-09-02",
                inputTokens: 1_000_000,
                outputTokens: 100_000,
                totalTokens: 1_100_000,
                costUSD: 0.12,
                apiEquivalentCostUSD: 1.675,
                modelsUsed: ["muse-spark-1.3-contributor"],
                modelBreakdowns: nil),
        ]
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 1_100_000,
            sessionCostUSD: 0.12,
            last30DaysTokens: 1_100_000,
            last30DaysCostUSD: 0.12,
            last30DaysAPIEquivalentCostUSD: 1.675,
            historyDays: 30,
            historyLabel: "Last 30 days (local Muse log)",
            daily: daily,
            updatedAt: now)
        let model = UsageMenuCardView.Model.make(.init(
            provider: .meta,
            metadata: metadata,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 0, windowMinutes: 1440, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: tokenSnapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let dashboard = try #require(model.inlineUsageDashboard)
        #expect(dashboard.points.count == 1)
        #expect(dashboard.detailLines.contains(where: { $0.contains("At standard API rates") }))
    }
}
