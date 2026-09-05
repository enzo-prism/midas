import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MidasMetaPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_788_523_200)

    @Test func localUsageMustRemainVisibleWithoutInventingQuota() {
        let result = self.presentation(tokens: 12000)
        #expect(result.hero == nil)
        #expect(result.metrics.isEmpty)
        #expect(!result.summary.contains("%"))
        #expect(result.summary.localizedCaseInsensitiveContains("tokens"))
        #expect(!result.summary.localizedCaseInsensitiveContains("unavailable"))
    }

    @Test func knownZeroTokenUsageIsNotUnavailable() {
        let result = self.presentation(tokens: 0)
        #expect(result.hero == nil)
        #expect(result.summary.localizedCaseInsensitiveContains("tokens"))
        #expect(!result.summary.localizedCaseInsensitiveContains("unavailable"))
    }

    @Test func unknownLocalUsageNeverShowsFullCapacity() {
        let result = self.presentation(tokens: nil)
        #expect(result.hero == nil)
        #expect(result.metrics.isEmpty)
        #expect(!result.summary.contains("100%"))
    }

    @Test func primaryLogActivitySurvivesDisabledCostHistory() {
        let result = self.presentation(tokens: nil)
        #expect(result.hero == nil)
        #expect(result.metrics.isEmpty)
        #expect(!result.summary.contains("%"))
        #expect(!result.summary.localizedCaseInsensitiveContains("unavailable"))
        #expect(result.summary.localizedCaseInsensitiveContains("today") || result.summary.contains("7 days"))
    }

    @Test func trulyMissingMetaDataDoesNotFabricateZeroActivity() {
        let result = MidasProviderPresentation.make(
            provider: .meta,
            card: nil,
            snapshot: nil,
            tokenSnapshot: nil,
            isRefreshing: false,
            isStale: false)
        #expect(result.hero == nil)
        #expect(result.summary.localizedCaseInsensitiveContains("unavailable"))
    }

    @Test func localTokenCountsDoNotCreateCashCharges() {
        let result = self.presentation(tokens: 12000)
        #expect(!result.summary.localizedCaseInsensitiveContains("billed"))
        #expect(!result.summary.localizedCaseInsensitiveContains("charged"))
        #expect(result.account.isEmpty)
    }

    @Test func localFetcherPreservesEstimateProvenance() {
        let snapshot = CostUsageFetcher.metaTokenSnapshot(
            from: MetaUsageSummary(updatedAt: self.now), now: self.now, historyDays: 30)
        #expect(snapshot.costProvenance == .listPriceEstimate)
        #expect(snapshot.meteredCostUSD == nil)
        #expect(snapshot.historyLabel == "Last 30 days (local Muse log)")
    }

    @Test func pricedZeroIsDistinctFromUnpricedLocalUsage() {
        let zero = CostUsageFetcher.metaTokenSnapshot(
            from: MetaUsageSummary(daily: [MetaDailyUsage(
                dayKey: "2026-09-04",
                usage: MetaTokenUsage(),
                modelsUsed: ["muse-spark-1.3-contributor"])]),
            now: self.now,
            historyDays: 30)
        let missing = CostUsageFetcher.metaTokenSnapshot(
            from: MetaUsageSummary(updatedAt: self.now), now: self.now, historyDays: 30)
        #expect(zero.last30DaysAPIEquivalentCostUSD == 0)
        #expect(missing.last30DaysAPIEquivalentCostUSD == nil)
    }

    @Test func modelTierEstimateIsDistinctFromStandardAPIEquivalent() {
        let row = CostUsageDailyReport.Entry(
            date: "2026-09-04",
            inputTokens: 1000,
            outputTokens: 1000,
            totalTokens: 2000,
            costUSD: 0,
            apiEquivalentCostUSD: 0.02,
            modelsUsed: nil,
            modelBreakdowns: nil)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 2000,
            last30DaysCostUSD: 0,
            costProvenance: .listPriceEstimate,
            daily: [row],
            updatedAt: self.now)
        let model = MidasCostPresentation(snapshot: snapshot, period: .all, now: self.now)
        #expect(model.totalCost == 0)
        #expect(model.totalAPIEquivalent == 0.02)
        #expect(model.costLabel == "Estimated model-tier cost")
        #expect(model.explanation.contains("not a bill"))
    }

    private func presentation(tokens: Int?) -> MidasProviderPresentation {
        let summary = MetaUsageSummary(
            today: MetaTokenUsage(inputTokens: 600, outputTokens: 400),
            last7Days: MetaTokenUsage(inputTokens: 6000, outputTokens: 4000),
            sessionsWithData: 2,
            updatedAt: self.now)
        let snapshot = MetaUsageSnapshot(summary: summary).toUsageSnapshot()
        let tokenSnapshot = tokens.map { tokens in
            CostUsageTokenSnapshot(
                sessionTokens: 1000,
                sessionCostUSD: nil,
                last30DaysTokens: tokens,
                last30DaysCostUSD: nil,
                historyDays: 30,
                historyLabel: "Last 30 days (local Muse log)",
                costProvenance: .listPriceEstimate,
                daily: [],
                updatedAt: self.now)
        }
        return MidasProviderPresentation.make(
            provider: .meta,
            card: nil,
            snapshot: snapshot,
            tokenSnapshot: tokenSnapshot,
            isRefreshing: false,
            isStale: false)
    }
}
