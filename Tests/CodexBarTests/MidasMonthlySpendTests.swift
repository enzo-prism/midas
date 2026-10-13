import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite struct MidasMonthlySpendTests {
    private let now = Date(timeIntervalSince1970: 1_789_171_200) // September 12, 2026 UTC.
    private let utc = MidasSpendPeriod.utc

    @Test func missingHistoryKeepsContiguousUnknownMonths() {
        let model = self.model(nil)
        #expect(model.months.map(\.id) == [
            "2026-04", "2026-05", "2026-06", "2026-07", "2026-08", "2026-09",
        ])
        #expect(model.months.allSatisfy { $0.cost == nil && $0.tokens == nil && $0.recordedDays == 0 })
        #expect(model.months.filter(\.isCurrentMonth).map(\.id) == ["2026-09"])
        #expect(model.currency == "USD")
        #expect(model.updatedAt == nil)
        #expect(model.comparison(for: "2026-09", metric: .cost) == nil)
    }

    @Test func monthCountIsClampedAndYearBoundaryIsContinuous() throws {
        let january = try self.date("2027-01-12T12:00:00Z")
        let short = MidasMonthlySpend(snapshot: nil, monthCount: -1, now: january, reportingTimeZone: self.utc)
        #expect(short.months.map(\.id) == ["2027-01"])
        let long = MidasMonthlySpend(snapshot: nil, monthCount: 100, now: january, reportingTimeZone: self.utc)
        #expect(long.months.count == 12)
        #expect(long.months.first?.id == "2026-02")
        #expect(long.months.suffix(2).map(\.id) == ["2026-12", "2027-01"])
        let twelve = MidasMonthlySpend(snapshot: nil, monthCount: 12, now: january, reportingTimeZone: self.utc)
        #expect(twelve.months.map(\.id) == long.months.map(\.id))
    }

    @Test func aggregatesDailyValuesWithoutUsingRollingOrMeteredTotals() throws {
        let model = self.model(self.snapshot([
            self.day("2026-07-31", cost: 20, tokens: 200),
            self.day("2026-08-01", cost: 3, tokens: 30),
            self.day("2026-08-31", cost: 4, tokens: nil),
            self.day("2026-09-01", cost: nil, tokens: 5),
        ]))
        let august = try #require(model.months.first { $0.id == "2026-08" })
        #expect(august.cost == 7)
        #expect(august.tokens == 30)
        #expect(august.recordedDays == 2)
        #expect(august.pricedDays == 2)
        #expect(august.tokenDays == 1)
        #expect(model.months.last?.cost == nil)
        #expect(model.months.last?.tokens == 5)
        #expect(model.updatedAt == self.now)
    }

    @Test func explicitZeroIsKnownAndGapsStayUnknown() throws {
        let model = self.model(self.snapshot([self.day("2026-09-01", cost: 0, tokens: 0)]))
        let current = try #require(model.months.last)
        #expect(current.cost == 0)
        #expect(current.tokens == 0)
        #expect(current.pricedDays == 1)
        #expect(current.tokenDays == 1)
        #expect(model.months.dropLast().allSatisfy { $0.cost == nil && $0.tokens == nil })
    }

    @Test func invalidAndFutureDatesAreExcluded() {
        let keys = [
            "2026-09-12", "2026-09-13", "2026-02-30", "2026-13-01", "2026-09-00", "2026-9-01", "bad",
        ]
        let model = self.model(self.snapshot(keys.map { self.day($0, cost: 1, tokens: 1) }))
        #expect(model.months.last?.recordedDays == 1)
        #expect(model.months.last?.cost == 1)
        #expect(model.months.dropLast().allSatisfy { $0.recordedDays == 0 })
    }

    @Test func pacificSourceMonthDoesNotRollOverAtUTCMidnight() throws {
        let evening = try self.date("2026-10-01T01:00:00Z")
        let pacific = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let snapshot = self.snapshot([
            self.day("2026-09-30", cost: 9, tokens: 90),
            self.day("2026-10-01", cost: 1, tokens: 10),
        ])
        let local = MidasMonthlySpend(snapshot: snapshot, now: evening, reportingTimeZone: pacific)
        let cloud = MidasMonthlySpend(snapshot: snapshot, now: evening, reportingTimeZone: self.utc)
        #expect(local.months.last?.id == "2026-09")
        #expect(local.months.last?.cost == 9)
        #expect(cloud.months.last?.id == "2026-10")
        #expect(cloud.months.last?.cost == 1)
        #expect(cloud.months.dropLast().last?.cost == 9)
    }

    @Test func sourceMonthStartsBeforeUTCInTokyoAndUsesNeutralPlotDates() throws {
        let morning = try self.date("2026-09-30T15:00:00Z")
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let snapshot = self.snapshot([self.day("2026-10-01", cost: 1, tokens: 10)])
        let local = MidasMonthlySpend(snapshot: snapshot, now: morning, reportingTimeZone: tokyo)
        let cloud = MidasMonthlySpend(snapshot: snapshot, now: morning, reportingTimeZone: self.utc)
        #expect(local.months.last?.id == "2026-10")
        #expect(try local.months.last?.date == (self.date("2026-10-01T00:00:00Z")))
        #expect(local.months.last?.cost == 1)
        #expect(cloud.months.last?.id == "2026-09")
        #expect(cloud.months.last?.cost == nil)
    }

    @Test func providerCalendarIsIndependentOfPriceProvenance() throws {
        let pacific = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let evening = try self.date("2026-10-01T01:00:00Z")
        let snapshot = self.snapshot([self.day("2026-10-01", cost: 1, tokens: 10)])
        for provider in [UsageProvider.openai, .anthropic, .mistral] {
            let zone = MidasMonthlySpend.reportingTimeZone(
                provider: provider, codexCloudEnabled: false, provenance: .unknown, localTimeZone: pacific)
            let model = MidasMonthlySpend(snapshot: snapshot, now: evening, reportingTimeZone: zone)
            #expect(model.months.last?.id == "2026-10")
            #expect(model.months.last?.tokens == 10)
        }
        for cloud in [true, false] {
            let zone = MidasMonthlySpend.reportingTimeZone(
                provider: .codex, codexCloudEnabled: cloud, provenance: .unknown, localTimeZone: pacific)
            let model = MidasMonthlySpend(snapshot: snapshot, now: evening, reportingTimeZone: zone)
            #expect(model.months.last?.id == (cloud ? "2026-10" : "2026-09"))
            #expect(model.months.last?.tokens == (cloud ? 10 : nil))
        }
    }

    @Test func duplicateDayMakesWholeMonthUnknownWithoutPoisoningOtherMonths() throws {
        let model = self.model(self.snapshot([
            self.day("2026-08-01", cost: 3, tokens: 30),
            self.day("2026-09-01", cost: 1, tokens: 10),
            self.day("2026-09-01", cost: 1, tokens: 10),
            self.day("2026-09-02", cost: 2, tokens: 20),
        ]))
        let month = try #require(model.months.last)
        #expect(month.cost == nil)
        #expect(month.tokens == nil)
        #expect(month.recordedDays == 2)
        #expect(month.pricedDays == 1)
        #expect(month.hasDuplicateDays)
        #expect(model.months.dropLast().last?.cost == 3)
        #expect(model.comparison(for: month.id, metric: .cost) == nil)
    }

    @Test func invalidValuesAreExcludedWhileKnownSubtotalsRemainVisible() throws {
        let model = self.model(self.snapshot([
            self.day("2026-09-01", cost: .nan, tokens: -1),
            self.day("2026-09-02", cost: .infinity, tokens: nil),
            self.day("2026-09-03", cost: -1, tokens: nil),
            self.day("2026-09-04", cost: 2, tokens: 7),
        ]))
        let month = try #require(model.months.last)
        #expect(month.cost == 2)
        #expect(month.tokens == 7)
        #expect(month.recordedDays == 4)
        #expect(month.pricedDays == 1)
        #expect(month.tokenDays == 1)
    }

    @Test func integerAndFloatingPointOverflowFailClosed() {
        let model = self.model(self.snapshot([
            self.day("2026-09-01", cost: .greatestFiniteMagnitude, tokens: .max),
            self.day("2026-09-02", cost: .greatestFiniteMagnitude, tokens: 1),
        ]))
        #expect(model.months.last?.tokens == nil)
        #expect(model.months.last?.cost == nil)
        #expect(model.months.last?.recordedDays == 2)
    }

    @Test func provenanceAndCurrencyKeepTheirExistingMeaning() {
        let meanings: [(CostProvenance, String)] = [
            (.listPriceEstimate, "API-equivalent value"),
            (.vendorMetered, "Provider-metered usage"),
            (.mixed, "API-equivalent value"),
            (.vendorBilled, "Billed API spend"),
            (.unknown, "Usage value · source unspecified"),
        ]
        for (provenance, label) in meanings {
            let model = self.model(self.snapshot(
                [self.day("2026-09-01", cost: 3, tokens: 30)],
                provenance: provenance,
                currency: "EUR"))
            #expect(model.costLabel == label)
            #expect(model.currency == "EUR")
            if provenance == .vendorBilled {
                #expect(model.explanation.contains("kept separate from inference estimates"))
            }
        }
        let tier = self.model(self.snapshot(
            [self.day("2026-09-01", cost: 3, tokens: 30, apiEquivalent: 2)],
            provenance: .listPriceEstimate))
        #expect(tier.costLabel == "Estimated model-tier cost")
        #expect(tier.explanation.contains("not a bill"))
    }

    @Test func comparisonsDoNotBridgeMissingCalendarMonths() {
        let model = self.model(self.snapshot([
            self.day("2026-07-01", cost: 1, tokens: 10),
            self.day("2026-09-01", cost: 3, tokens: 30),
        ]))
        #expect(model.comparison(for: "2026-09", metric: .cost) == nil)
        #expect(model.comparison(for: "2026-08", metric: .tokens) == nil)
        #expect(model.comparison(for: "2026-99", metric: .cost) == nil)
    }

    @Test func sparseMatchingRecordedDaysCanCompareSubtotals() throws {
        let model = self.model(self.snapshot([
            self.day("2026-08-01", cost: 2, tokens: 20),
            self.day("2026-08-05", cost: 3, tokens: 30),
            self.day("2026-09-01", cost: 4, tokens: 40),
            self.day("2026-09-05", cost: 6, tokens: 60),
        ]))
        let cost = try #require(model.comparison(for: "2026-09", metric: .cost))
        #expect(cost.current == 10)
        #expect(cost.previous == 5)
        #expect(cost.delta == 5)
        #expect(cost.percent == 100)
        #expect(cost.isMonthToDate)
        #expect(cost.throughDay == 12)
        #expect(model.comparison(for: "2026-09", metric: .tokens)?.delta == 50)
    }

    @Test func differentRecordedDayCoverageSuppressesComparison() {
        let model = self.model(self.snapshot([
            self.day("2026-08-01", cost: 2, tokens: 20),
            self.day("2026-08-02", cost: 3, tokens: 30),
            self.day("2026-09-01", cost: 4, tokens: 40),
        ]))
        #expect(model.comparison(for: "2026-09", metric: .cost) == nil)
        #expect(model.comparison(for: "2026-09", metric: .tokens) == nil)
    }

    @Test func missingMetricAndUnpricedRequestsSuppressOnlyAffectedComparison() {
        let missingCost = self.model(self.snapshot([
            self.day("2026-08-01", cost: 2, tokens: 20),
            self.day("2026-08-02", cost: nil, tokens: 30),
            self.day("2026-09-01", cost: 4, tokens: 40),
            self.day("2026-09-02", cost: 6, tokens: 60),
        ]))
        #expect(missingCost.comparison(for: "2026-09", metric: .cost) == nil)
        #expect(missingCost.comparison(for: "2026-09", metric: .tokens)?.delta == 50)
        let missingTokens = self.model(self.snapshot([
            self.day("2026-08-01", cost: 2, tokens: nil),
            self.day("2026-09-01", cost: 4, tokens: 40),
        ]))
        #expect(missingTokens.comparison(for: "2026-09", metric: .cost)?.delta == 2)
        #expect(missingTokens.comparison(for: "2026-09", metric: .tokens) == nil)
        let unpriced = self.model(self.snapshot([
            self.day("2026-08-01", cost: 2, tokens: 20),
            self.day("2026-09-01", cost: 4, tokens: 40, unpriced: 1),
        ]))
        #expect(unpriced.months.last?.cost == 4)
        #expect(unpriced.months.last?.hasUnpricedUsage == true)
        #expect(unpriced.comparison(for: "2026-09", metric: .cost) == nil)
        #expect(unpriced.comparison(for: "2026-09", metric: .tokens)?.delta == 20)
    }

    @Test func currentMTDExcludesLaterDaysFromPreviousMonthComparison() throws {
        let model = self.model(self.snapshot([
            self.day("2026-08-01", cost: 2, tokens: 20),
            self.day("2026-08-12", cost: 3, tokens: 30),
            self.day("2026-08-13", cost: 100, tokens: 1000),
            self.day("2026-09-01", cost: 4, tokens: 40),
            self.day("2026-09-12", cost: 6, tokens: 60),
        ]))
        let comparison = try #require(model.comparison(for: "2026-09", metric: .cost))
        #expect(comparison.previous == 5)
        #expect(comparison.current == 10)
        #expect(comparison.throughDay == 12)
        #expect(model.months.dropLast().last?.cost == 105)
    }

    @Test func currentMTDCapsBothMonthsToShorterPreviousMonth() throws {
        let march = try self.date("2026-03-31T12:00:00Z")
        let snapshot = self.snapshot([
            self.day("2026-02-28", cost: 2, tokens: 20),
            self.day("2026-03-28", cost: 4, tokens: 40),
            self.day("2026-03-29", cost: 100, tokens: 1000),
            self.day("2026-03-31", cost: 100, tokens: 1000),
        ])
        let model = MidasMonthlySpend(snapshot: snapshot, now: march, reportingTimeZone: self.utc)
        let comparison = try #require(model.comparison(for: "2026-03", metric: .cost))
        #expect(comparison.throughDay == 28)
        #expect(comparison.current == 4)
        #expect(comparison.previous == 2)
        #expect(model.months.last?.cost == 204)
    }

    @Test func leapYearUsesTwentyNineSharedDays() throws {
        let march = try self.date("2024-03-30T12:00:00Z")
        let snapshot = self.snapshot([
            self.day("2024-02-29", cost: 2, tokens: 20),
            self.day("2024-03-29", cost: 4, tokens: 40),
            self.day("2024-03-30", cost: 100, tokens: 1000),
        ])
        let model = MidasMonthlySpend(snapshot: snapshot, now: march, reportingTimeZone: self.utc)
        #expect(model.comparison(for: "2024-03", metric: .cost)?.throughDay == 29)
        #expect(model.comparison(for: "2024-03", metric: .cost)?.delta == 2)
        #expect(model.months.last?.cost == 104)
    }

    @Test func completeHistoricalMonthsCompareTheirDifferentCalendarLengths() throws {
        let october = try self.date("2026-10-12T12:00:00Z")
        let august = (1...31).map { self.day(String(format: "2026-08-%02d", $0), cost: 1, tokens: 10) }
        let september = (1...30).map { self.day(String(format: "2026-09-%02d", $0), cost: 2, tokens: 20) }
        let model = MidasMonthlySpend(
            snapshot: self.snapshot(august + september), now: october, reportingTimeZone: self.utc)
        let comparison = try #require(model.comparison(for: "2026-09", metric: .cost))
        #expect(comparison.current == 60)
        #expect(comparison.previous == 31)
        #expect(comparison.delta == 29)
        #expect(!comparison.isMonthToDate)
        #expect(comparison.throughDay == nil)
    }

    @Test func zeroPreviousValueHasNoPercentageAndLargeTokensKeepExactDelta() throws {
        let zero = self.model(self.snapshot([
            self.day("2026-08-01", cost: 0, tokens: 0),
            self.day("2026-09-01", cost: 4, tokens: 40),
        ]))
        let comparison = try #require(zero.comparison(for: "2026-09", metric: .cost))
        #expect(comparison.previous == 0)
        #expect(comparison.delta == 4)
        #expect(comparison.percent == nil)
        let huge = self.model(self.snapshot([
            self.day("2026-08-01", cost: 1, tokens: Int.max - 1),
            self.day("2026-09-01", cost: 1, tokens: .max),
        ]))
        #expect(huge.comparison(for: "2026-09", metric: .tokens)?.delta == 1)
        let hugePercent = self.model(self.snapshot([
            self.day("2026-08-01", cost: .leastNonzeroMagnitude, tokens: 1),
            self.day("2026-09-01", cost: .greatestFiniteMagnitude, tokens: 1),
        ]))
        #expect(hugePercent.comparison(for: "2026-09", metric: .cost)?.percent == nil)
    }

    @Test func duplicateOutsideMTDCutoffStillSuppressesComparison() {
        let model = self.model(self.snapshot([
            self.day("2026-08-01", cost: 2, tokens: 20),
            self.day("2026-08-31", cost: 1, tokens: 10),
            self.day("2026-08-31", cost: 1, tokens: 10),
            self.day("2026-09-01", cost: 4, tokens: 40),
        ]))
        #expect(model.comparison(for: "2026-09", metric: .cost) == nil)
        #expect(model.comparison(for: "2026-09", metric: .tokens) == nil)
    }

    private func model(_ snapshot: CostUsageTokenSnapshot?) -> MidasMonthlySpend {
        .init(snapshot: snapshot, now: self.now, reportingTimeZone: self.utc)
    }

    private func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    private func day(
        _ date: String,
        cost: Double?,
        tokens: Int?,
        apiEquivalent: Double? = nil,
        unpriced: Int? = nil) -> CostUsageDailyReport.Entry
    {
        .init(
            date: date,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            apiEquivalentCostUSD: apiEquivalent,
            modelsUsed: nil,
            modelBreakdowns: nil,
            unpricedRequestCount: unpriced)
    }

    private func snapshot(
        _ rows: [CostUsageDailyReport.Entry],
        provenance: CostProvenance = .unknown,
        currency: String = "USD") -> CostUsageTokenSnapshot
    {
        .init(
            sessionTokens: 99999,
            sessionCostUSD: 99999,
            last30DaysTokens: 99999,
            last30DaysCostUSD: 99999,
            currencyCode: currency,
            meteredCostUSD: 99999,
            costProvenance: provenance,
            daily: rows,
            updatedAt: self.now)
    }
}
