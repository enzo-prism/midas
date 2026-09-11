import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MidasCloudUsageTests {
    private let now = Date(timeIntervalSince1970: 1_789_171_200) // 2026-09-12 00:00 UTC

    private func usage(_ tokens: Int, date: String = "2026-09-10") throws -> CodexCloudAccountUsage {
        let profile: [String: Any] = [
            "stats": ["daily_usage_buckets": [["start_date": date, "tokens": tokens]]],
            "metadata": ["stats_as_of": "2026-09-11"],
        ]
        let breakdown: [String: Any] = [
            "units": "percent",
            "data": [["date": date, "models": [["model": "gpt-5", "credits": 42.0]]]],
        ]
        return try CodexCloudAccountUsage.parse(
            profile: JSONSerialization.data(withJSONObject: profile),
            breakdown: JSONSerialization.data(withJSONObject: breakdown),
            now: self.now)
    }

    @Test func cloudTokensCombineWithoutPricingPercentages() throws {
        let first = try self.usage(1_000_000)
        let second = try self.usage(2_000_000)
        let snapshot = UsageStore.cloudTokenSnapshot(accounts: [first, second], rate: 0, now: self.now)
        #expect(snapshot.last30DaysTokens == 3_000_000)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.daily.first?.modelBreakdowns == nil)
        #expect(first.modelUnits == "percent")
        #expect(first.models.first?.value == 42)
    }

    @Test func explicitRatePricesCombinedCloudTokensOnce() throws {
        let accounts = try [self.usage(1_000_000), self.usage(2_000_000)]
        let snapshot = UsageStore.cloudTokenSnapshot(accounts: accounts, rate: 0.75, now: self.now)
        #expect(snapshot.last30DaysCostUSD == 2.25)
        #expect(snapshot.daily.first?.costUSD == 2.25)
        #expect(snapshot.costProvenance == .unknown)
    }

    @Test func missingHistoryIsNotZeroAndOldDaysAreExcluded() throws {
        let old = try self.usage(500, date: "2026-01-01")
        #expect(old.totalTokens == nil)
        let snapshot = UsageStore.cloudTokenSnapshot(accounts: [old], rate: 1, now: self.now)
        #expect(snapshot.last30DaysTokens == nil)
        #expect(snapshot.last30DaysCostUSD == nil)
    }

    @Test func negativeTokensAreRejected() {
        #expect(throws: (any Error).self) { try self.usage(-1) }
    }

    @Test func inclusiveThirtyDayWindowUsesUTC() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-11T23:30:00Z"))
        let range = CodexCloudAccountUsage.window(now: now)
        #expect(range.start == "2026-08-13")
        #expect(range.end == "2026-09-11")
    }
}
