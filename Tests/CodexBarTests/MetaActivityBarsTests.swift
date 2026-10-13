import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MetaActivityBarsTests {
    private let now = Date(timeIntervalSince1970: 1_788_523_200)

    @Test
    func `activity windows scale to busiest comparable window`() {
        let activity = MetaActivitySnapshot(summary: self.summary())
        #expect(activity.busiestDayTokens == 4000)
        #expect(activity.busiestWeekTokens == 10000)
        let windows = activity.windows
        #expect(windows.map(\.id) == ["meta-activity-today", "meta-activity-week"])
        #expect(windows[0].tokens == 1000)
        #expect(windows[0].sharePercent == 25)
        #expect(windows[1].tokens == 10000)
        #expect(windows[1].sharePercent == 100)
    }

    @Test
    func `busiest week uses rolling calendar days across gaps`() {
        let daily = [
            MetaDailyUsage(dayKey: "2026-09-01", usage: MetaTokenUsage(inputTokens: 5000)),
            MetaDailyUsage(dayKey: "2026-09-10", usage: MetaTokenUsage(inputTokens: 1000)),
            MetaDailyUsage(dayKey: "2026-09-11", usage: MetaTokenUsage(inputTokens: 1000)),
            MetaDailyUsage(dayKey: "2026-09-12", usage: MetaTokenUsage(inputTokens: 1000)),
        ]
        let summary = MetaUsageSummary(
            today: MetaTokenUsage(inputTokens: 1000),
            last7Days: MetaTokenUsage(inputTokens: 3000),
            last30Days: MetaTokenUsage(inputTokens: 8000),
            daily: daily,
            updatedAt: self.now)
        let activity = MetaActivitySnapshot(summary: summary)
        // Sep 1 alone (5000) beats the Sep 10-12 cluster (3000); gaps count as zero.
        #expect(activity.busiestWeekTokens == 5000)
        #expect(activity.windows[1].sharePercent == 60)
    }

    @Test
    func `zero activity stays at zero without inventing capacity`() {
        let activity = MetaActivitySnapshot(summary: MetaUsageSummary(updatedAt: self.now))
        #expect(!activity.hasActivity)
        #expect(activity.windows.allSatisfy { $0.sharePercent == 0 })
    }

    @Test
    func `activity survives snapshot codable round trip and old payloads`() throws {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            metaActivity: MetaActivitySnapshot(summary: self.summary()),
            updatedAt: self.now)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        #expect(decoded.metaActivity == snapshot.metaActivity)

        let legacy = #"{"primary":null,"secondary":null,"tertiary":null,"updatedAt":810211200}"#
        let old = try JSONDecoder().decode(UsageSnapshot.self, from: Data(legacy.utf8))
        #expect(old.metaActivity == nil)
    }

    @Test
    func `aggregate only history still covers today in the week window`() {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 12000,
            sessionCostUSD: nil,
            last30DaysTokens: 12000,
            last30DaysCostUSD: nil,
            daily: [],
            updatedAt: self.now)
        let activity = MetaActivitySnapshot(tokenSnapshot: snapshot)
        #expect(activity?.todayTokens == 12000)
        #expect(activity?.last7DaysTokens == 12000)
        #expect(activity?.windows[1].sharePercent == 100)
    }

    @Test
    func `air presentation shows activity bars and no quota`() {
        let result = self.presentation()
        #expect(result.hero == nil)
        #expect(result.metrics.isEmpty)
        #expect(result.activityMetrics.map(\.id) == ["meta-activity-today", "meta-activity-week"])
        #expect(result.activityMetrics[0].valueText.hasSuffix("tokens"))
        #expect(result.activityMetrics[0].sharePercent == 25)
        #expect(!result.activityMetrics[0].detailText.contains("left"))
        #expect(!result.summary.contains("%"))
    }

    @Test
    func `legacy menu card shows claude style activity rows`() throws {
        let snapshot = MetaUsageSnapshot(summary: self.summary()).toUsageSnapshot()
        let metadata = try #require(ProviderDefaults.metadata[.meta])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .meta,
            metadata: metadata,
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
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: self.now))
        #expect(model.metrics.map(\.id) == ["meta-activity-today", "meta-activity-week"])
        #expect(model.metrics[0].percent == 25)
        #expect(model.metrics[0].percentLabel.hasSuffix("tokens"))
        #expect(!model.metrics[0].percentLabel.contains("left"))
        #expect(model.metrics[0].resetText?.contains("busiest day") == true)
        #expect(model.metrics[1].detailText?.contains("No provider limit") == true)
    }

    private func summary() -> MetaUsageSummary {
        MetaUsageSummary(
            today: MetaTokenUsage(inputTokens: 600, outputTokens: 400, requests: 3),
            last7Days: MetaTokenUsage(inputTokens: 6000, outputTokens: 4000, requests: 30),
            last30Days: MetaTokenUsage(inputTokens: 6000, outputTokens: 4000, requests: 30),
            sessionsWithData: 4,
            daily: [
                MetaDailyUsage(dayKey: "2026-09-01", usage: MetaTokenUsage(inputTokens: 4000, requests: 12)),
                MetaDailyUsage(dayKey: "2026-09-02", usage: MetaTokenUsage(inputTokens: 3000, requests: 9)),
                MetaDailyUsage(dayKey: "2026-09-03", usage: MetaTokenUsage(inputTokens: 2000, requests: 6)),
                MetaDailyUsage(dayKey: "2026-09-04", usage: MetaTokenUsage(inputTokens: 1000, requests: 3)),
            ],
            updatedAt: self.now)
    }

    private func presentation() -> MidasProviderPresentation {
        let snapshot = MetaUsageSnapshot(summary: self.summary()).toUsageSnapshot()
        return MidasProviderPresentation.make(
            provider: .meta,
            card: nil,
            snapshot: snapshot,
            tokenSnapshot: nil,
            isRefreshing: false,
            isStale: false)
    }
}
