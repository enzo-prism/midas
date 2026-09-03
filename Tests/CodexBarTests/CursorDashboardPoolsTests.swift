import Foundation
import Testing
@testable import CodexBarCore

struct CursorDashboardPoolsTests {
    private static let periodJSON = """
    {"billingCycleStart": "1786490627000",
     "billingCycleEnd": "1789169027000",
     "planUsage": {"autoPercentUsed": 80.0,
                   "apiPercentUsed": 100.0,
                   "totalPercentUsed": 85.0},
     "autoBucketModels": ["grok-4.5", "composer-2.5"]}
    """

    private static let sandJSON = """
    {"currentPeriodStart": "2026-09-01T23:22:26.061Z",
     "nextResetTimestampUtc": "2026-09-08T23:22:26.061Z",
     "usagePercent": 91.271409,
     "hasAvailableUsage": true,
     "hasNonZeroIncludedLimit": true,
     "grokPlanLabel": "Ultra"}
    """

    private static func periodUsage() throws -> CursorPeriodUsage {
        try JSONDecoder().decode(CursorPeriodUsage.self, from: Data(self.periodJSON.utf8))
    }

    private static func sandStatus() throws -> CursorSandUsageStatus {
        try JSONDecoder().decode(CursorSandUsageStatus.self, from: Data(self.sandJSON.utf8))
    }

    private static func summary() throws -> CursorUsageSummary {
        try JSONDecoder().decode(
            CursorUsageSummary.self,
            from: Data(
                """
                {"individualUsage": {"plan": {"used": 40000, "limit": 40000}},
                 "billingCycleEnd": "2026-09-11T00:00:00.000Z"}
                """.utf8))
    }

    @Test
    func `decodes dashboard pool payloads`() throws {
        let period = try Self.periodUsage()
        #expect(period.planUsage?.autoPercentUsed == 80.0)
        #expect(period.planUsage?.apiPercentUsed == 100.0)
        #expect(period.autoBucketModels?.count == 2)

        let sand = try Self.sandStatus()
        #expect(abs((sand.usagePercent ?? -1) - 91.271409) < 1e-9)
        #expect(sand.hasAvailableUsage == true)
    }

    @Test
    func `snapshot carries pool percents and grok reset`() throws {
        let probe = CursorStatusProbe(browserDetection: BrowserDetection())
        let snapshot = try probe.parseUsageSummary(
            Self.summary(),
            userInfo: nil,
            rawJSON: nil,
            periodUsage: Self.periodUsage(),
            sandStatus: Self.sandStatus())

        #expect(snapshot.cursorModelsUsedPercent == 80.0)
        #expect(snapshot.otherModelsUsedPercent == 100.0)
        #expect(abs((snapshot.grokBotWeeklyUsedPercent ?? -1) - 91.271409) < 1e-9)
        let reset = try #require(snapshot.grokBotWeeklyReset)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        #expect(calendar.component(.day, from: reset) == 8)
        #expect(calendar.component(.month, from: reset) == 9)
    }

    @Test
    func `pool rows render with usage left`() throws {
        let probe = CursorStatusProbe(browserDetection: BrowserDetection())
        let snapshot = try probe.parseUsageSummary(
            Self.summary(),
            userInfo: nil,
            rawJSON: nil,
            periodUsage: Self.periodUsage(),
            sandStatus: Self.sandStatus())
        let usage = snapshot.toUsageSnapshot()
        let rows = Dictionary(
            uniqueKeysWithValues: (usage.extraRateWindows ?? []).map { ($0.id, $0) })

        #expect(rows["cursor-pool-models"]?.window.usedPercent == 80.0)
        #expect(rows["cursor-pool-other"]?.window.usedPercent == 100.0)
        #expect(abs((rows["cursor-grok-bot"]?.window.usedPercent ?? -1) - 91.271409) < 1e-9)
        #expect(rows["cursor-grok-bot"]?.window.resetsAt != nil)
        #expect(rows["cursor-grok-bot"]?.window.windowMinutes == 7 * 24 * 60)
    }

    @Test
    func `missing dashboard data hides pool rows`() throws {
        let probe = CursorStatusProbe(browserDetection: BrowserDetection())
        let snapshot = try probe.parseUsageSummary(Self.summary(), userInfo: nil, rawJSON: nil)
        let usage = snapshot.toUsageSnapshot()
        let ids = (usage.extraRateWindows ?? []).map(\.id)

        #expect(!ids.contains("cursor-pool-models"))
        #expect(!ids.contains("cursor-pool-other"))
        #expect(!ids.contains("cursor-grok-bot"))
    }
}
