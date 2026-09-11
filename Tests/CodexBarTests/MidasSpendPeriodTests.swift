import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MidasSpendPeriodTests {
    private let now = Date(timeIntervalSince1970: 1_789_171_200) // September 12, 2026 UTC

    @Test func monthAndRollingWindowsHaveDifferentStarts() {
        #expect(MidasSpendPeriod.currentMonth.range(now: self.now) == .init(start: "2026-09-01", end: "2026-09-12"))
        #expect(MidasSpendPeriod.rolling30Days.range(now: self.now) == .init(start: "2026-08-14", end: "2026-09-12"))
        #expect(MidasSpendPeriod.month(year: 2024, month: 2).range(now: self.now)
            == .init(start: "2024-02-01", end: "2024-02-29"))
        #expect(MidasSpendPeriod.month(year: 2027, month: 1).range(now: self.now) == nil)
    }

    @Test func monthFiltersDailyEntriesRatherThanRelabelingRollingTotal() throws {
        let result = try #require(MidasSpendPeriod.currentMonth.amount(
            snapshot: self.snapshot([self.day("2026-08-31", 100), self.day("2026-09-01", 3)]), now: self.now))
        #expect(result.dollars == 3)
        #expect(result.isPartial)
    }

    @Test func coverageMustBeExplicitAndContainEntireWindow() throws {
        let snapshot = self.snapshot([self.day("2026-09-01", 3)])
        let period = MidasSpendPeriod.currentMonth
        let complete = try #require(period.amount(
            snapshot: snapshot,
            sourceCoverage: .init(start: "2026-08-14", end: "2026-09-12"),
            now: self.now))
        #expect(!complete.isPartial)
        let incomplete = try #require(period.amount(
            snapshot: snapshot,
            sourceCoverage: .init(start: "2026-09-02", end: "2026-09-12"),
            now: self.now))
        #expect(incomplete.isPartial)
    }

    @Test func emptyUnknownHistoryIsNotZero() throws {
        let result = try #require(MidasSpendPeriod.currentMonth.amount(snapshot: self.snapshot([]), now: self.now))
        #expect(result.dollars == nil)
        #expect(result.isPartial)
    }

    @Test func duplicateDatesDoNotDoubleCount() throws {
        let result = try #require(MidasSpendPeriod.currentMonth.amount(
            snapshot: self.snapshot([
                self.day("2026-09-01", 3),
                self.day("2026-09-01", 3),
            ]), now: self.now))
        #expect(result.dollars == nil)
        #expect(result.isPartial)
    }

    @Test func unpricedDayRetainsOnlyKnownSubtotal() throws {
        let result = try #require(MidasSpendPeriod.currentMonth.amount(
            snapshot: self.snapshot([
                self.day("2026-09-01", 3),
                self.day("2026-09-02", nil),
            ]),
            sourceCoverage: .init(start: "2026-09-01", end: "2026-09-12"),
            now: self.now))
        #expect(result.dollars == 3)
        #expect(result.isPartial)
    }

    @Test func UTCMonthBoundaryAndInvalidDatesRemainHonest() throws {
        let midnight = Date(timeIntervalSince1970: 1_788_220_800) // September 1, 2026 UTC
        #expect(MidasSpendPeriod.currentMonth.range(now: midnight)?.start == "2026-09-01")
        let result = try #require(MidasSpendPeriod.currentMonth.amount(
            snapshot: self.snapshot([self.day("2026-09-32", 9), self.day("2026-09-01", 3)]),
            sourceCoverage: .init(start: "2026-09-01", end: "2026-09-12"),
            now: self.now))
        #expect(result.dollars == 3)
        #expect(result.isPartial)
    }

    private func day(_ date: String, _ cost: Double?) -> CostUsageDailyReport.Entry {
        .init(
            date: date,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 1,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }

    private func snapshot(_ daily: [CostUsageDailyReport.Entry]) -> CostUsageTokenSnapshot {
        .init(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: 999,
            daily: daily,
            updatedAt: self.now)
    }
}
