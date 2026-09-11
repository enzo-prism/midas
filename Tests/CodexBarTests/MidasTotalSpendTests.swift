import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct MidasTotalSpendTests {
    @Test func partialHistoryRemainsPartialWhenEveryProviderHasAnEstimate() {
        var item = self.item(.codex, amount: 12)
        item.spend?.coverageNote = "Incomplete month"
        let total = MidasTotalSpend(presentations: [item])
        #expect(total.excludedProviderCount == 0)
        #expect(total.hasIncompleteCoverage)
        #expect(total.totals.first?.amount == 12)
    }

    @Test func sumsPrimaryEstimatesAcrossEverySuppliedProvider() throws {
        let total = MidasTotalSpend(presentations: [
            self.item(
                .codex,
                amount: 12.50), self.item(
                .cursor,
                amount: 7.25), self.item(
                .meta,
                amount: 0),
        ])
        #expect(try #require(total.totals.first).amount == 19.75)
        #expect(total.includedProviderCount == 3)
        #expect(total.excludedProviderCount == 0)
        #expect(total.periodText == "Last 30 days")
    }

    @Test func excludesMeteredUnknownAndMissingWithoutLosingRealZero() {
        let total = MidasTotalSpend(presentations: [
            self.item(
                .codex,
                amount: 0),
            self.item(
                .cursor,
                amount: 99,
                provenance: .vendorMetered),
            self.item(
                .meta,
                amount: nil),
            self.item(
                .claude,
                amount: 5,
                provenance: .unknown),
        ])
        #expect(total.totals.first?.amount == 0)
        #expect(total.includedProviderCount == 1)
        #expect(total.excludedProviderCount == 3)
        #expect(total.coverageText.contains("1 of 4 providers"))
    }

    @Test func differentCurrenciesNeverAddTogether() {
        let total = MidasTotalSpend(presentations: [
            self.item(
                .codex,
                amount: 10), self.item(
                .mistral,
                amount: 20,
                currency: "EUR"),
        ])
        #expect(total.totals.count == 2)
        #expect(total.totals.first { $0.currency == "USD" }?.amount == 10)
        #expect(total.totals.first { $0.currency == "EUR" }?.amount == 20)
    }

    @Test func differentWindowsAreExplicitInsteadOfClaimingOneMonth() {
        let total = MidasTotalSpend(presentations: [
            self.item(
                .codex,
                amount: 10,
                days: 7), self.item(
                .cursor,
                amount: 20,
                days: 30),
        ])
        #expect(total.totals.first?.amount == 30)
        #expect(total.periodText == "Across provider reporting periods")
    }

    @Test func duplicateProviderIsCountedOnce() {
        let total = MidasTotalSpend(presentations: [
            self.item(
                .codex,
                amount: 10), self.item(
                .codex,
                amount: 10), self.item(
                .cursor,
                amount: 5),
        ])
        #expect(total.providerCount == 2)
        #expect(total.includedProviderCount == 2)
        #expect(total.totals.first?.amount == 15)
    }

    @Test func secondaryMeteringAndStandardEquivalentAreNotDoubleCounted() {
        let total = MidasTotalSpend(presentations: [
            self.item(
                .cursor,
                amount: 10,
                provenance: .mixed,
                metered: 3),
            self.item(
                .meta,
                amount: 0,
                equivalent: 50),
        ])
        #expect(total.totals.first?.amount == 10)
        #expect(total.includedProviderCount == 2)
    }

    @Test func unavailableDoesNotProduceAZeroDollarTotal() {
        let total = MidasTotalSpend(presentations: [self.item(
            .codex,
            amount: nil)])
        #expect(total.totals.isEmpty)
        #expect(total.oldestUpdate == nil)
        #expect(total.periodText == "No estimate data")
        #expect(total.excludedProviderCount == 1)
        #expect(MidasTotalSpend(presentations: []).coverageText == "No enabled providers")
    }

    private func item(
        _ provider: UsageProvider,
        amount: Double?,
        provenance: CostProvenance = .listPriceEstimate,
        currency: String = "USD",
        days: Int = 30,
        metered: Double? = nil,
        equivalent: Double? = nil) -> MidasProviderPresentation
    {
        .make(
            provider: provider,
            card: nil,
            snapshot: nil,
            tokenSnapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: nil,
                last30DaysCostUSD: amount,
                last30DaysAPIEquivalentCostUSD: equivalent,
                currencyCode: currency,
                historyDays: days,
                meteredCostUSD: metered,
                costProvenance: provenance,
                daily: [],
                updatedAt: Date(timeIntervalSince1970: 1_788_523_200)),
            isRefreshing: false,
            isStale: false)
    }
}
