import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MidasTokenTooltipTests {
    private let now = Date(timeIntervalSince1970: 1_788_566_400)
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }

    private func snapshot(
        _ tokens: Int?,
        days: Int = 30,
        label: String? = nil,
        daily: [CostUsageDailyReport.Entry] = []) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: 999,
            sessionCostUSD: nil,
            last30DaysTokens: tokens,
            last30DaysCostUSD: 123,
            historyDays: days,
            historyLabel: label,
            daily: daily,
            updatedAt: self.now)
    }

    @Test func selectedIsNotCountedTwiceAndUnknownIsDisclosed() {
        let text = MidasTokenTooltip.text(
            favorite: .codex,
            providers: [.codex, .codex, .cursor, .meta],
            snapshots: [.codex: self.snapshot(100), .meta: self.snapshot(200)],
            now: self.now,
            calendar: self.calendar)
        #expect(text == "Past 30 days\nCodex: 100 tokens\nAll providers: 300 tokens (2/3 reporting)")
        #expect(!text.contains("$"))
        #expect(!text.contains("percent"))
    }

    @Test func zeroIsKnownAndDisabledFavoriteIsNotSubstituted() {
        let text = MidasTokenTooltip.text(
            favorite: .codex,
            providers: [.meta],
            snapshots: [.meta: self.snapshot(0), .codex: self.snapshot(100)],
            now: self.now,
            calendar: self.calendar)
        #expect(text == "Past 30 days\nCodex: Unavailable\nAll providers: 0 tokens")
    }

    @Test func shortWindowsAndBillingPeriodsAreNotThirtyDays() {
        #expect(MidasTokenTooltip.count(self.snapshot(500, days: 7), now: self.now, calendar: self.calendar) == nil)
        #expect(MidasTokenTooltip.count(
            self.snapshot(500, label: "Billing cycle"),
            now: self.now,
            calendar: self.calendar) == nil)
    }

    @Test func longerHistoryFiltersBoundaryAndPreservesDailyZero() {
        let formatter = DateFormatter()
        formatter.calendar = self.calendar
        formatter.timeZone = self.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        func row(_ offset: Int, _ tokens: Int?) -> CostUsageDailyReport.Entry {
            let date = self.calendar.date(byAdding: .day, value: offset, to: self.now)!
            return .init(
                date: formatter.string(from: date),
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: tokens,
                costUSD: nil,
                modelsUsed: nil,
                modelBreakdowns: nil)
        }
        let snapshot = self.snapshot(999, days: 90, daily: [row(-30, 1000), row(-29, 10), row(0, 20), row(1, 1000)])
        #expect(MidasTokenTooltip.count(snapshot, now: self.now, calendar: self.calendar) == 30)
        #expect(MidasTokenTooltip.count(
            self.snapshot(nil, daily: [row(0, 0)]),
            now: self.now,
            calendar: self.calendar) == 0)
        #expect(MidasTokenTooltip.count(
            self.snapshot(nil, daily: [row(0, nil)]),
            now: self.now,
            calendar: self.calendar) == nil)
    }

    @Test func realRollingHistoryLabelsRemainAvailable() {
        for label in ["Last 30 days (local Muse log)", "Last 30 days (OpenAI Admin API)"] {
            #expect(MidasTokenTooltip.count(
                self.snapshot(300, label: label),
                now: self.now,
                calendar: self.calendar) == 300)
        }
    }

    @Test func overflowDoesNotCrashOrWrap() {
        let text = MidasTokenTooltip.text(
            favorite: .codex,
            providers: [.codex, .meta],
            snapshots: [.codex: self.snapshot(Int.max), .meta: self.snapshot(1)],
            now: self.now,
            calendar: self.calendar)
        #expect(text.hasSuffix("All providers: Unavailable"))
    }
}
