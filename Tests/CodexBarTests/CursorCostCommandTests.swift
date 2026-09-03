import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

struct CursorCostCommandTests {
    private static func snapshot(
        plan: Double = 20,
        onDemand: Double = 5,
        bot: Double = 3,
        botLimit: Double? = 10) -> CursorStatusSnapshot
    {
        CursorStatusSnapshot(
            planPercentUsed: 50,
            planUsedUSD: plan,
            planLimitUSD: 40,
            onDemandUsedUSD: onDemand,
            onDemandLimitUSD: nil,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleEnd: Date(timeIntervalSince1970: 1_700_265_600),
            membershipType: "pro",
            accountEmail: nil,
            accountName: nil,
            rawJSON: nil,
            botUsedUSD: bot,
            botLimitUSD: botLimit,
            cursorModelUsedUSD: 15,
            nonCursorModelUsedUSD: 5)
    }

    @Test
    func `cursor report totals plan ondemand and bot`() {
        let report = CostUsageFetcher.cursorDailyReport(
            from: Self.snapshot(),
            now: Date(timeIntervalSince1970: 1_700_179_200))

        #expect(report.data.count == 1)
        #expect(report.data[0].costUSD == 28)
        #expect(report.data[0].requestCount == nil)
        let names = report.data[0].modelBreakdowns?.map(\.modelName)
        #expect(names == ["Plan", "On-demand", "Bot"])
        #expect(report.data[0].modelBreakdowns?.map(\.costUSD) == [20, 5, 3])
    }

    @Test
    func `cursor report omits bot row when unreported`() {
        let report = CostUsageFetcher.cursorDailyReport(
            from: Self.snapshot(bot: 0, botLimit: nil),
            now: Date(timeIntervalSince1970: 1_700_179_200))

        #expect(report.data[0].costUSD == 25)
        #expect(report.data[0].modelBreakdowns?.map(\.modelName) == ["Plan", "On-demand"])
    }

    @Test
    func `cursor cost respects disabled source`() async {
        let settings = ProviderSettingsSnapshot.CursorProviderSettings(
            cookieSource: .off,
            manualCookieHeader: nil)
        do {
            _ = try await CostUsageFetcher().loadTokenSnapshot(
                provider: .cursor,
                refreshPricingInBackground: false,
                cursorSettings: settings)
            Issue.record("Expected sourceDisabled error")
        } catch let error as CostUsageError {
            #expect(error.errorDescription?.contains("cursor") == true)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `renders cursor cost text section`() {
        let report = CostUsageFetcher.cursorDailyReport(
            from: Self.snapshot(),
            now: Date(timeIntervalSince1970: 1_700_179_200))
        let snapshot = CostUsageFetcher.tokenSnapshot(from: report, now: Date(timeIntervalSince1970: 1_700_179_200))
        let output = CodexBarCLI.renderCostText(provider: .cursor, snapshot: snapshot, useColor: false)

        #expect(output.contains("Cursor Cost (API-rate estimate)"))
        #expect(output.contains("Billing cycle: $28.00"))
    }

    @Test
    func `cursor cost section is enabled in menu`() throws {
        #expect(ProviderDescriptorRegistry.descriptor(for: .cursor).tokenCost.supportsTokenCost)

        let report = CostUsageFetcher.cursorDailyReport(
            from: Self.snapshot(),
            now: Date(timeIntervalSince1970: 1_700_179_200))
        var snapshot = CostUsageFetcher.tokenSnapshot(from: report, now: Date(timeIntervalSince1970: 1_700_179_200))
        snapshot = CostUsageTokenSnapshot(
            sessionTokens: snapshot.sessionTokens,
            sessionCostUSD: snapshot.sessionCostUSD,
            sessionRequests: snapshot.sessionRequests,
            last30DaysTokens: snapshot.last30DaysTokens,
            last30DaysCostUSD: snapshot.last30DaysCostUSD,
            last30DaysRequests: snapshot.last30DaysRequests,
            currencyCode: snapshot.currencyCode,
            historyDays: snapshot.historyDays,
            historyLabel: "Current billing cycle (Cursor web session)",
            daily: snapshot.daily,
            updatedAt: snapshot.updatedAt)
        let section = UsageMenuCardView.Model.tokenUsageSection(
            provider: .cursor,
            enabled: true,
            snapshot: snapshot,
            error: nil)

        let lines = try #require(section)
        #expect(lines.sessionLine.hasPrefix("Billing cycle: $28.00"))
        #expect(lines.monthLine.contains("Current billing cycle (Cursor web session): $28.00"))
    }
}
