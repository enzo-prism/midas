import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MidasSpendPeriodTests {
    private let now = Date(timeIntervalSince1970: 1_789_171_200) // September 12, 2026 UTC
    private let utc = MidasSpendPeriod.utc

    @Test func monthAndRollingWindowsHaveDifferentStarts() {
        #expect(MidasSpendPeriod.currentMonth.range(now: self.now, timeZone: self.utc)
            == .init(start: "2026-09-01", end: "2026-09-12"))
        #expect(MidasSpendPeriod.rolling30Days.range(now: self.now, timeZone: self.utc)
            == .init(start: "2026-08-14", end: "2026-09-12"))
        #expect(MidasSpendPeriod.month(year: 2024, month: 2).range(now: self.now, timeZone: self.utc)
            == .init(start: "2024-02-01", end: "2024-02-29"))
        #expect(MidasSpendPeriod.month(year: 2027, month: 1).range(now: self.now, timeZone: self.utc) == nil)
    }

    @Test func monthFiltersDailyEntriesRatherThanRelabelingRollingTotal() throws {
        let result = try #require(MidasSpendPeriod.currentMonth.amount(
            snapshot: self.snapshot([self.day("2026-08-31", 100), self.day("2026-09-01", 3)]),
            timeZone: self.utc,
            now: self.now))
        #expect(result.dollars == 3)
        #expect(result.isPartial)
    }

    @Test func coverageMustBeExplicitAndContainEntireWindow() throws {
        let snapshot = self.snapshot([self.day("2026-09-01", 3)])
        let period = MidasSpendPeriod.currentMonth
        let complete = try #require(period.amount(
            snapshot: snapshot,
            sourceCoverage: .init(start: "2026-08-14", end: "2026-09-12"),
            timeZone: self.utc,
            now: self.now))
        #expect(!complete.isPartial)
        let incomplete = try #require(period.amount(
            snapshot: snapshot,
            sourceCoverage: .init(start: "2026-09-02", end: "2026-09-12"),
            timeZone: self.utc,
            now: self.now))
        #expect(incomplete.isPartial)
    }

    @Test func emptyUnknownHistoryIsNotZero() throws {
        let result = try #require(MidasSpendPeriod.currentMonth.amount(
            snapshot: self.snapshot([]),
            timeZone: self.utc,
            now: self.now))
        #expect(result.dollars == nil)
        #expect(result.isPartial)
    }

    @Test func duplicateDatesDoNotDoubleCount() throws {
        let result = try #require(MidasSpendPeriod.currentMonth.amount(
            snapshot: self.snapshot([
                self.day("2026-09-01", 3),
                self.day("2026-09-01", 3),
            ]),
            timeZone: self.utc,
            now: self.now))
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
            timeZone: self.utc,
            now: self.now))
        #expect(result.dollars == 3)
        #expect(result.isPartial)
    }

    @Test func UTCMonthBoundaryAndInvalidDatesRemainHonest() throws {
        let midnight = Date(timeIntervalSince1970: 1_788_220_800) // September 1, 2026 UTC
        #expect(MidasSpendPeriod.currentMonth.range(now: midnight, timeZone: self.utc)?.start == "2026-09-01")
        let result = try #require(MidasSpendPeriod.currentMonth.amount(
            snapshot: self.snapshot([self.day("2026-09-32", 9), self.day("2026-09-01", 3)]),
            sourceCoverage: .init(start: "2026-09-01", end: "2026-09-12"),
            timeZone: self.utc,
            now: self.now))
        #expect(result.dollars == 3)
        #expect(result.isPartial)
    }

    @Test func localMonthDoesNotRollOverAtUTCMidnight() throws {
        // 6 PM Pacific on September 30 is already October 1 in UTC.
        let evening = try #require(ISO8601DateFormatter().date(from: "2026-10-01T01:00:00Z"))
        let pacific = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(MidasSpendPeriod.currentMonth.range(now: evening, timeZone: pacific)
            == .init(start: "2026-09-01", end: "2026-09-30"))
        #expect(MidasSpendPeriod.rolling30Days.range(now: evening, timeZone: pacific)
            == .init(start: "2026-09-01", end: "2026-09-30"))
        #expect(MidasSpendPeriod.currentMonth.range(now: evening, timeZone: self.utc)
            == .init(start: "2026-10-01", end: "2026-10-01"))

        let localDays = self.snapshot([self.day("2026-09-02", 4), self.day("2026-09-30", 5)])
        let local = try #require(MidasSpendPeriod.currentMonth.amount(
            snapshot: localDays, timeZone: pacific, now: evening))
        #expect(local.dollars == 9)
    }

    @Test func localMonthStartsBeforeUTCMidnightEastOfGreenwich() throws {
        // 9 AM October 1 in Tokyo is still September 30 in UTC.
        let morning = try #require(ISO8601DateFormatter().date(from: "2026-10-01T00:00:00+09:00"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(MidasSpendPeriod.currentMonth.range(now: morning, timeZone: tokyo)
            == .init(start: "2026-10-01", end: "2026-10-01"))
        #expect(MidasSpendPeriod.month(year: 2026, month: 9).range(now: morning, timeZone: tokyo)
            == .init(start: "2026-09-01", end: "2026-09-30"))
        let result = try #require(MidasSpendPeriod.currentMonth.amount(
            snapshot: self.snapshot([self.day("2026-09-30", 7), self.day("2026-10-01", 2)]),
            timeZone: tokyo,
            now: morning))
        #expect(result.dollars == 2)
    }

    @Test func pickerRejectsInvalidDatesAndKeepsSelectedMonth() {
        let months = MidasSpendPeriodChoices.recordedMonths(
            dates: ["2026-08-01", "2026-08-31", "2026-02-30", "2026-09-01", "2027-01-01", "bad-date!!"],
            selection: "2026-07",
            now: self.now)
        #expect(months == ["2026-08", "2026-07"])
        #expect(MidasSpendPeriodChoices.recordedMonths(dates: [], now: self.now).isEmpty)
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
