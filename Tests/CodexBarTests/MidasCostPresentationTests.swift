import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite struct MidasCostPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_788_523_200) // September 4, 2026, 12:00 UTC.

    @Test func unavailableIsDifferentFromZero() {
        let empty = MidasCostPresentation(
            snapshot: nil,
            period: .all)
        #expect(empty.totalCost == nil)
        #expect(empty.totalTokens == nil)
        #expect(empty.money(nil) == "Unavailable")
        let zero = MidasCostPresentation(
            snapshot: self.snapshot(rows: [self.row(
                "2026-09-04",
                cost: 0)]),
            period: .all,
            now: self.now)
        #expect(zero.totalCost == 0)
        #expect(zero.money(zero.totalCost) != "Unavailable")
    }

    @Test func sourceMeaningIsPreserved() {
        let expected: [(CostProvenance, String)] = [
            (.listPriceEstimate, "API-equivalent value"),
            (.vendorMetered, "Provider-metered usage"),
            (.mixed, "API-equivalent value"),
            (.unknown, "Usage value · source unspecified"),
        ]
        for (source, label) in expected {
            let model = MidasCostPresentation(
                snapshot: self.snapshot(
                    rows: [self.row(
                        "2026-09-04",
                        cost: 1)],
                    provenance: source),
                period: .all,
                now: self.now)
            #expect(model.costLabel == label)
        }
    }

    @Test func currencyIsPreserved() {
        let model = MidasCostPresentation(
            snapshot: self.snapshot(currency: "EUR"),
            period: .all)
        #expect(model.currency == "EUR")
        #expect(model.money(12) == 12.0.formatted(.currency(code: "EUR")))
    }

    @Test func sevenDaysUsesCalendarBoundariesAndExcludesFutureAndInvalidDates() {
        let rows = ["2026-08-28", "2026-08-29", "2026-09-04", "2026-09-05", "invalid", "2026-02-30"]
            .map { self.row(
                $0,
                cost: 1) }
        let model = MidasCostPresentation(
            snapshot: self.snapshot(rows: rows),
            period: .week,
            now: self.now)
        #expect(model.days.map(\.id) == ["2026-08-29", "2026-09-04"])
        #expect(model.totalCost == 2)
        #expect(model.coverage.contains("2 recorded days"))
    }

    @Test func filtersNeverUseWholeWindowAggregateAsSelectedPeriodTotal() {
        let model = MidasCostPresentation(
            snapshot: self.snapshot(rows: [self.row(
                "2026-08-01",
                cost: 9)]),
            period: .week,
            now: self.now)
        #expect(model.days.isEmpty)
        #expect(model.totalCost == nil)
    }

    @Test func rejectsInvalidCostsWithoutFabricatingMissingValues() {
        let rows = [
            self.row(
                "2026-09-01",
                cost: .nan),
            self.row(
                "2026-09-02",
                cost: -.infinity),
            self.row(
                "2026-09-03",
                cost: -1),
            self.row(
                "2026-09-04",
                cost: nil),
        ]
        let model = MidasCostPresentation(
            snapshot: self.snapshot(rows: rows),
            period: .all,
            now: self.now)
        #expect(model.totalCost == nil)
        #expect(model.days.allSatisfy { $0.cost == nil })
    }

    @Test func localEveningKeepsTheFirstRecordedDayInASevenDayWindow() throws {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let evening = Date(timeIntervalSince1970: 1_788_570_000) // September 5, 01:00 UTC; September 4 locally.
        let snapshot = self.snapshot(rows: [self.row(
            "2026-08-29",
            cost: 1), self.row(
            "2026-09-04",
            cost: 2)])
        let model = MidasCostPresentation(
            snapshot: snapshot,
            period: .week,
            now: evening,
            reportingCalendar: pacific)
        #expect(model.days.map(\.id) == ["2026-08-29", "2026-09-04"])
        #expect(model.totalCost == 3)
    }

    private func row(
        _ date: String,
        cost: Double?) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: date,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }

    private func snapshot(
        rows: [CostUsageDailyReport.Entry] = [],
        provenance: CostProvenance = .unknown,
        currency: String = "USD") -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: 999,
            currencyCode: currency,
            costProvenance: provenance,
            daily: rows,
            updatedAt: self.now)
    }
}
