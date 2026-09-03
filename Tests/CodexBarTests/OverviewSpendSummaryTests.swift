import CodexBarCore
import Testing
@testable import CodexBar

@Suite struct OverviewSpendSummaryTests {
    @Test func emptyCostsShowSpendUnavailable() {
        let summary = OverviewSpendSummary.build(costs: [], tokens: [], providerCount: 2)
        #expect(!summary.hasSpend)
        #expect(summary.primarySpendText == "Spend unavailable")
        #expect(summary.tokenText == nil)
    }

    @Test func singleCurrencyCostsSum() {
        let summary = OverviewSpendSummary.build(
            costs: [("USD", 100.0), ("USD", 23.5)],
            tokens: [1000],
            providerCount: 2)
        #expect(summary.hasSpend)
        #expect(summary.totals.count == 1)
        #expect(summary.totals.first?.amount == 123.5)
        #expect(summary.pricedProviderCount == 2)
        #expect(summary.tokenText != nil)
    }

    @Test func mixedCurrenciesStaySeparate() {
        let summary = OverviewSpendSummary.build(
            costs: [("USD", 10.0), ("EUR", 5.0)],
            tokens: [],
            providerCount: 2)
        #expect(summary.totals.count == 2)
        #expect(summary.primarySpendText.contains("·"))
        #expect(summary.tokenText == nil)
    }

    @Test func tokenOverflowYieldsNilTokens() {
        let summary = OverviewSpendSummary.build(
            costs: [("USD", 1.0)],
            tokens: [Int.max, 1],
            providerCount: 1)
        #expect(summary.hasSpend)
        #expect(summary.tokenText == nil)
    }

    @Test func providerCountFloorsAtPricedCount() {
        let summary = OverviewSpendSummary.build(costs: [("USD", 1.0)], tokens: [], providerCount: 0)
        #expect(summary.providerCount == 1)
    }

    @Test func noPriorCostsOmitsComparison() {
        let summary = OverviewSpendSummary.build(costs: [("USD", 100.0)], tokens: [], providerCount: 1)
        #expect(summary.comparison == nil)
    }

    @Test func spendUpShowsUpComparison() {
        let summary = OverviewSpendSummary.build(
            costs: [("USD", 112.0)],
            tokens: [],
            providerCount: 1,
            priorCosts: [("USD", 100.0)],
            priorPricedProviderCount: 1)
        let comparison = try? #require(summary.comparison)
        #expect(comparison?.deltas.first?.direction == .up)
        #expect(comparison?.isUp == true)
        #expect(comparison?.isPartial == false)
        #expect(comparison?.text.contains("▲ 12%") == true)
        #expect(comparison?.text.contains("vs prior 30d") == true)
    }

    @Test func spendDownShowsDownComparison() {
        let summary = OverviewSpendSummary.build(
            costs: [("USD", 80.0)],
            tokens: [],
            providerCount: 1,
            priorCosts: [("USD", 100.0)],
            priorPricedProviderCount: 1)
        #expect(summary.comparison?.deltas.first?.direction == .down)
        #expect(summary.comparison?.isDown == true)
        #expect(summary.comparison?.text.contains("▼ 20%") == true)
    }

    @Test func flatSpendShowsFlatComparison() {
        let summary = OverviewSpendSummary.build(
            costs: [("USD", 100.2)],
            tokens: [],
            providerCount: 1,
            priorCosts: [("USD", 100.0)],
            priorPricedProviderCount: 1)
        #expect(summary.comparison?.deltas.first?.direction == .flat)
        #expect(summary.comparison?.isUp == false)
        #expect(summary.comparison?.isDown == false)
    }

    @Test func mixedDirectionsStayNeutral() {
        let summary = OverviewSpendSummary.build(
            costs: [("USD", 120.0), ("EUR", 80.0)],
            tokens: [],
            providerCount: 2,
            priorCosts: [("USD", 100.0), ("EUR", 100.0)],
            priorPricedProviderCount: 2)
        let comparison = try? #require(summary.comparison)
        #expect(comparison?.deltas.count == 2)
        #expect(comparison?.isUp == false)
        #expect(comparison?.isDown == false)
        #expect(comparison?.text.contains("▲ 20%") == true)
        #expect(comparison?.text.contains("▼ 20%") == true)
    }

    @Test func zeroPriorSpendOmitsComparison() {
        let summary = OverviewSpendSummary.build(
            costs: [("USD", 50.0)],
            tokens: [],
            providerCount: 1,
            priorCosts: [("USD", 0.0)],
            priorPricedProviderCount: 1)
        #expect(summary.comparison == nil)
    }

    @Test func missingPriorProviderMarksPartial() {
        let summary = OverviewSpendSummary.build(
            costs: [("USD", 100.0), ("USD", 100.0)],
            tokens: [],
            providerCount: 2,
            priorCosts: [("USD", 100.0)],
            priorPricedProviderCount: 1)
        #expect(summary.comparison?.isPartial == true)
        #expect(summary.comparison?.text.contains("partial") == true)
    }

    @Test func priorPeriodSlicingTakesDays31To60() {
        let entries = (0..<60).map { day in
            CostUsageDailyReport.Entry(
                date: String(format: "2026-0%d-%02d", day < 30 ? 6 : 7, (day % 30) + 1),
                inputTokens: nil,
                outputTokens: nil,
                cacheReadTokens: nil,
                cacheCreationTokens: nil,
                totalTokens: nil,
                costUSD: day < 30 ? 1.0 : 2.0,
                modelsUsed: [],
                modelBreakdowns: [])
        }
        #expect(OverviewSpendSummary.priorPeriodCost(daily: entries) == 30.0)
        #expect(OverviewSpendSummary.hasFullPriorWindow(daily: entries) == true)
    }

    @Test func shortSeriesYieldsPartialPriorWindow() {
        let entries = (0..<40).map { day in
            CostUsageDailyReport.Entry(
                date: String(format: "2026-08-%02d", day + 1),
                inputTokens: nil,
                outputTokens: nil,
                cacheReadTokens: nil,
                cacheCreationTokens: nil,
                totalTokens: nil,
                costUSD: 1.0,
                modelsUsed: [],
                modelBreakdowns: [])
        }
        #expect(OverviewSpendSummary.priorPeriodCost(daily: entries) == 10.0)
        #expect(OverviewSpendSummary.hasFullPriorWindow(daily: entries) == false)
    }
}
