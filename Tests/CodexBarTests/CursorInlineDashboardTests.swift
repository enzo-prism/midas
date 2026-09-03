import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CursorInlineDashboardTests {
    @Test
    func `cursor snapshot builds cost dashboard with top model`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.cursor])
        let daily = [
            CostUsageDailyReport.Entry(
                date: "2026-08-25",
                inputTokens: 1000,
                outputTokens: 500,
                cacheReadTokens: nil,
                cacheCreationTokens: nil,
                totalTokens: 1500,
                costUSD: 10.0,
                modelsUsed: ["grok-code-fast-1"],
                modelBreakdowns: [
                    CostUsageDailyReport.ModelBreakdown(modelName: "grok-code-fast-1", costUSD: 10.0),
                ]),
            CostUsageDailyReport.Entry(
                date: "2026-09-02",
                inputTokens: 2000,
                outputTokens: 1000,
                cacheReadTokens: nil,
                cacheCreationTokens: nil,
                totalTokens: 3000,
                costUSD: 435.82,
                modelsUsed: ["grok-code-fast-1", "composer-1"],
                modelBreakdowns: [
                    CostUsageDailyReport.ModelBreakdown(modelName: "grok-code-fast-1", costUSD: 400.0),
                    CostUsageDailyReport.ModelBreakdown(modelName: "composer-1", costUSD: 35.82),
                ]),
        ]
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 3000,
            sessionCostUSD: 435.82,
            last30DaysTokens: 4500,
            last30DaysCostUSD: 445.82,
            historyDays: 30,
            daily: daily,
            updatedAt: now)
        let model = UsageMenuCardView.Model.make(.init(
            provider: .cursor,
            metadata: metadata,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 83, windowMinutes: 43200, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: now,
                identity: nil),
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
        #expect(dashboard.kpis.map(\.title).contains("Today"))
        #expect(dashboard.kpis.map(\.title).contains("30d cost"))
        #expect(dashboard.kpis.map(\.title).contains("30d tokens"))
        #expect(dashboard.kpis.map(\.title).contains("Latest tokens"))
        #expect(dashboard.points.count == 2)
        #expect(dashboard.detailLines.contains { $0.contains("Top model") && $0.contains("grok-code-fast-1") })
    }

    @Test
    func `meta sparse series builds dashboard over priced days`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.meta])
        let daily = [
            CostUsageDailyReport.Entry(
                date: "2026-08-20",
                inputTokens: 500_000,
                outputTokens: 50000,
                cacheReadTokens: nil,
                cacheCreationTokens: nil,
                totalTokens: 550_000,
                costUSD: nil,
                modelsUsed: nil,
                modelBreakdowns: nil),
            CostUsageDailyReport.Entry(
                date: "2026-09-02",
                inputTokens: 1_000_000,
                outputTokens: 100_000,
                cacheReadTokens: nil,
                cacheCreationTokens: nil,
                totalTokens: 1_100_000,
                costUSD: 0.12,
                modelsUsed: ["muse-spark-1.3-contributor"],
                modelBreakdowns: nil),
        ]
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 1_100_000,
            sessionCostUSD: 0.12,
            last30DaysTokens: 1_650_000,
            last30DaysCostUSD: 0.12,
            historyDays: 30,
            daily: daily,
            updatedAt: now)
        let model = UsageMenuCardView.Model.make(.init(
            provider: .meta,
            metadata: metadata,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 0, windowMinutes: 1440, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: now,
                identity: nil),
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
        #expect(dashboard.kpis.map(\.title).contains("30d tokens"))
    }
}
