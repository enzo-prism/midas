import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct DGXSparkPricingTests {
    private let now = Date(timeIntervalSince1970: 1_792_065_600) // 2026-10-15 12:00 UTC

    @Test func cachedInputIsSubsetOfInputAndUnknownModelStaysUnpriced() {
        #expect(DGXSparkPricing.estimate(
            model: DGXSparkPricing.modelID,
            input: 1_000_000,
            cachedInput: 400_000,
            output: 100_000,
            total: 1_100_000) == 0.19)
        #expect(DGXSparkPricing.estimate(
            model: "fictitious-model", input: 1, cachedInput: 0, output: 1, total: 2) == nil)
        #expect(DGXSparkPricing.estimate(
            model: DGXSparkPricing.modelID, input: 1, cachedInput: nil, output: 1, total: 2) == nil)
        #expect(DGXSparkPricing.estimate(
            model: DGXSparkPricing.modelID, input: 1, cachedInput: 2, output: 1, total: 2) == nil)
        #expect(DGXSparkPricing.estimate(
            model: DGXSparkPricing.modelID, input: Int.max, cachedInput: 0, output: 1, total: Int.max) == nil)
    }

    @Test func projectionPricesKnownModelsAndPreservesUnknownSubtotalCoverage() {
        let known = self.model(tokens: 1_100_000, input: 1_000_000, output: 100_000, cached: 400_000)
        let unknown = self.model(name: "fictitious-model", tokens: 10, input: 8, output: 2, cached: 0)
        let raw = self.snapshot(rows: [self.row(date: "2026-10-15", tokens: 1_100_018, models: [known, unknown])])
        let valued = DGXSparkPricing.project(snapshot: raw, now: self.now)
        #expect(valued.last30DaysTokens == 1_100_018)
        #expect(valued.last30DaysCostUSD == 0.19)
        #expect(valued.costProvenance == .listPriceEstimate)
        #expect(valued.daily[0].unpricedRequestCount == 1)
        #expect(valued.daily[0].estimatedRequestCount == 1)
        #expect(valued.daily[0].modelBreakdowns?[1].costUSD == nil)
        #expect(valued.last30DaysAPIEquivalentCostUSD == nil)
        #expect(DGXSparkPricing.project(snapshot: valued, now: self.now) == valued)
        #expect(raw.daily[0].costUSD == nil)
    }

    @Test func missingClassAndInconsistentCountsDoNotCreateDollarZero() {
        let incomplete = self.model(tokens: 10, input: 8, output: 2, cached: nil)
        let overflow = self.model(tokens: Int.max, input: Int.max, output: 1, cached: 0)
        let raw = self.snapshot(rows: [self.row(date: "2026-10-15", tokens: Int.max, models: [incomplete, overflow])])
        let valued = DGXSparkPricing.project(snapshot: raw, now: self.now)
        #expect(valued.last30DaysCostUSD == nil)
        #expect(valued.costProvenance == .unknown)
        #expect(valued.daily[0].unpricedRequestCount == 2)
    }

    @Test func duplicateModelSubtotalsCannotCreateAnEstimate() {
        let known = self.model(tokens: 100, input: 80, output: 20, cached: 40)
        let raw = self.snapshot(rows: [self.row(date: "2026-10-15", tokens: 200, models: [known, known])])
        let valued = DGXSparkPricing.project(snapshot: raw, now: self.now)
        #expect(valued.last30DaysCostUSD == nil)
        #expect(valued.daily[0].unpricedRequestCount == 2)
    }

    @Test func projectionKeeps365DayHistoryAndPeriodSelectionUsesDailyRows() throws {
        let known = self.model(tokens: 1_100_000, input: 1_000_000, output: 100_000, cached: 400_000)
        let raw = self.snapshot(rows: [
            self.row(date: "2026-08-01", tokens: 1_100_000, models: [known]),
            self.row(date: "2026-09-16", tokens: 1_100_000, models: [known]),
            self.row(date: "2026-10-15", tokens: 1_100_000, models: [known]),
        ])
        let valued = DGXSparkPricing.project(snapshot: raw, now: self.now)
        #expect(valued.historyDays == 365)
        #expect(valued.historyLabel == "Across devices · 12 months")
        #expect(valued.daily.count == 3)
        #expect(valued.last30DaysTokens == 3_300_000)
        let month = try #require(MidasSpendPeriod.currentMonth.amount(
            snapshot: valued, timeZone: MidasSpendPeriod.utc, now: self.now))
        let thirtyDays = try #require(MidasSpendPeriod.rolling30Days.amount(
            snapshot: valued, timeZone: MidasSpendPeriod.utc, now: self.now))
        #expect(month.dollars == 0.19)
        #expect(thirtyDays.dollars == 0.38)
        #expect(valued.sessionCostUSD == 0.19)
    }

    private func model(
        name: String = DGXSparkPricing.modelID, tokens: Int, input: Int?, output: Int?, cached: Int?)
        -> CostUsageDailyReport.ModelBreakdown
    {
        CostUsageDailyReport.ModelBreakdown(
            modelName: name,
            costUSD: nil,
            totalTokens: tokens,
            requestCount: 1,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cached)
    }

    private func row(date: String, tokens: Int, models: [CostUsageDailyReport.ModelBreakdown])
        -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: date,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            requestCount: models.count,
            costUSD: nil,
            modelsUsed: models.map(\.modelName),
            modelBreakdowns: models,
            unpricedRequestCount: models.count)
    }

    private func snapshot(rows: [CostUsageDailyReport.Entry]) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: rows.last?.totalTokens,
            sessionCostUSD: nil,
            last30DaysTokens: rows.compactMap(\.totalTokens).first == Int.max
                ? Int.max : rows.compactMap(\.totalTokens).reduce(0, +),
            last30DaysCostUSD: nil,
            historyDays: 365,
            historyLabel: "Across devices · 12 months",
            daily: rows,
            updatedAt: self.now)
    }
}
