import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MidasRecordedTokenTotalTests {
    private let now = Date(timeIntervalSince1970: 1_789_171_200)

    @Test @MainActor func sharedTotalsIgnoreLocalDisplayAndUnsupportedLocalSources() {
        let shared: [UsageProvider] = [.claude, .codex, .localInference, .cursor]
        let mini = MidasRecordedTokenTotal.providersForTotal(local: [.codex, .openai], shared: shared, combined: true)
        let laptop = MidasRecordedTokenTotal.providersForTotal(local: [.claude, .meta], shared: shared, combined: true)
        #expect(mini == laptop)
        #expect(!mini.contains(.openai))
        #expect(MidasRecordedTokenTotal
            .providersForTotal(local: [.openai], shared: shared, combined: false) == [.openai])
    }

    @Test func sumsUnpricedTokensAndCountsEachProviderOnce() {
        let result = self.total(
            providers: [.codex, .codex, .claude],
            snapshots: [
                .codex: self.snapshot([self.day("2026-09-12", 100)]),
                .claude: self.snapshot([self.day("2026-09-11", 200)]),
            ])
        #expect(result.tokens == 300)
        #expect(result.reportingProviders == 2)
        #expect(result.isPartial)
    }

    @Test func includesOnlyThirtyUTCDaysAndRejectsFutureRecords() {
        let result = self.total(snapshots: [.codex: self.snapshot([
            self.day("2026-08-13", 1000), self.day("2026-08-14", 10),
            self.day("2026-09-12", 20), self.day("2026-09-13", 2000),
        ])])
        #expect(result.tokens == 30)
    }

    @Test func absentCountsRemainUnavailableAndKnownZeroSurvives() {
        #expect(self.total(snapshots: [:]).tokens == nil)
        #expect(self.total(snapshots: [.codex: self.snapshot([])]).tokens == nil)
        #expect(self.total(snapshots: [.codex: self.snapshot([self.day("2026-09-12", 0)])]).tokens == 0)
        let partial = self.total(snapshots: [.codex: self.snapshot([
            self.day("2026-09-11", nil), self.day("2026-09-12", 40),
        ])])
        #expect(partial.tokens == 40)
        #expect(partial.isPartial)
    }

    @Test func duplicateDailyAggregatesAreNotAdded() {
        let result = self.total(snapshots: [.codex: self.snapshot([
            self.day("2026-09-12", 10), self.day("2026-09-12", 10),
        ])])
        #expect(result.tokens == nil)
        #expect(result.isPartial)
    }

    @Test func billedOrganizationReportsStaySeparateFromRecordedSessions() {
        let result = self.total(
            providers: [.claude, .anthropic],
            snapshots: [
                .claude: self.snapshot([self.day("2026-09-12", 100)]),
                .anthropic: self.snapshot([self.day("2026-09-12", 100)], provenance: .vendorBilled),
            ])
        #expect(result.tokens == 100)
        #expect(result.providerCount == 1)
    }

    @Test func overflowsNeverWrapIntoPlausibleTotals() {
        let result = self.total(snapshots: [.codex: self.snapshot([
            self.day("2026-09-11", Int.max), self.day("2026-09-12", 1),
        ])])
        #expect(result.tokens == nil)
        #expect(result.isPartial)
    }

    @Test func localInferenceContributesTokensWithoutInventingDollars() {
        let result = self.total(
            providers: [.localInference],
            snapshots: [.localInference: self.snapshot([self.day("2026-09-12", 150)], provenance: .unknown)])
        #expect(result.tokens == 150)
    }

    private func total(
        providers: [UsageProvider] = [.codex],
        snapshots: [UsageProvider: CostUsageTokenSnapshot]) -> MidasRecordedTokenTotal
    {
        MidasRecordedTokenTotal(
            providers: providers,
            snapshots: snapshots,
            period: .rolling30Days,
            reportingTimeZones: Dictionary(uniqueKeysWithValues: Set(providers).map { ($0, MidasSpendPeriod.utc) }),
            now: self.now)
    }

    private func day(_ date: String, _ tokens: Int?) -> CostUsageDailyReport.Entry {
        .init(
            date: date,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: nil,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }

    private func snapshot(
        _ daily: [CostUsageDailyReport.Entry],
        provenance: CostProvenance = .listPriceEstimate) -> CostUsageTokenSnapshot
    {
        .init(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            costProvenance: provenance,
            daily: daily,
            updatedAt: self.now)
    }
}
