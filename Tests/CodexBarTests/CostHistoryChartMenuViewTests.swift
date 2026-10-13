import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct CostHistoryChartMenuViewTests {
    @Test
    @MainActor
    func `window label keeps today for one day and dynamic labels otherwise`() {
        #expect(CostHistoryChartMenuView.windowLabel(days: 1) == "Today")
        #expect(CostHistoryChartMenuView.windowLabel(days: 7) == "Last 7 days")
        #expect(CostHistoryChartMenuView.windowLabel(days: 30) == "Last 30 days")
    }

    @Test
    @MainActor
    func `model breakdown keeps every item behind a bounded scrolling viewport`() {
        let breakdown = (1...6).map { index in
            CostUsageDailyReport.ModelBreakdown(
                modelName: "model-\(index)",
                costUSD: Double(index),
                totalTokens: index * 100)
        }

        let ordered = CostHistoryChartMenuView.orderedBreakdownItems(breakdown)

        #expect(ordered.map(\.modelName) == [
            "model-6",
            "model-5",
            "model-4",
            "model-3",
            "model-2",
            "model-1",
        ])
        #expect(ordered.count == 6)
        #expect(CostHistoryChartMenuView.detailViewportRowCount(itemCount: ordered.count) == 4)
        #expect(CostHistoryChartMenuView.detailRowsNeedScrolling(itemCount: ordered.count))
    }

    @Test
    @MainActor
    func `short model breakdown does not scroll or reserve extra rows`() {
        #expect(CostHistoryChartMenuView.detailViewportRowCount(itemCount: 3) == 3)
        #expect(CostHistoryChartMenuView.detailRowsNeedScrolling(itemCount: 3) == false)
    }

    @Test
    @MainActor
    func `shared chart dates use the supplied UTC calendar across local time zones`() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        var pacific = utc
        pacific.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let day = "2026-10-01"
        let shared = try #require(CostHistoryChartMenuView.dateFromDayKey(day, calendar: utc))
        let local = try #require(CostHistoryChartMenuView.dateFromDayKey(day, calendar: pacific))
        #expect(shared == ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z"))
        #expect(local == ISO8601DateFormatter().date(from: "2026-10-01T19:00:00Z"))
        #expect(utc.component(.day, from: shared) == 1)
        #expect(pacific.component(.day, from: local) == 1)
    }
}
