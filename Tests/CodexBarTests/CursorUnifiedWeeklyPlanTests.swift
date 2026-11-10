import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct CursorUnifiedWeeklyPlanTests {
    private static let weekMinutes = 7 * 24 * 60
    private static let weeklyReset = Date(timeIntervalSince1970: 1_794_900_000)
    private static let cycleEnd = Date(timeIntervalSince1970: 1_796_083_200)

    private static func snapshot(
        membershipType: String,
        unified: Bool,
        weeklyUsed: Double?,
        planName: String? = nil,
        unavailable: String? = nil) -> CursorStatusSnapshot
    {
        CursorStatusSnapshot(
            planPercentUsed: 0,
            planUsedUSD: 0,
            planLimitUSD: 553.95,
            onDemandUsedUSD: 0,
            onDemandLimitUSD: nil,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleStart: self.cycleEnd.addingTimeInterval(-30 * 86400),
            billingCycleEnd: self.cycleEnd,
            membershipType: membershipType,
            accountEmail: "person@example.com",
            accountName: nil,
            rawJSON: nil,
            cursorModelsUsedPercent: weeklyUsed,
            grokBotWeeklyUsedPercent: weeklyUsed,
            grokBotWeeklyReset: weeklyUsed == nil ? nil : self.weeklyReset,
            grokBotUnavailableReason: unavailable,
            isUnifiedWeeklyPlan: unified,
            unifiedPlanName: planName)
    }

    @Test
    func `unified plan headlines the weekly pool instead of the empty monthly plan`() throws {
        let usage = Self.snapshot(membershipType: "unified_ultra", unified: true, weeklyUsed: 11, planName: "Ultra")
            .toUsageSnapshot()

        let primary = try #require(usage.primary)
        #expect(primary.usedPercent == 11)
        #expect(primary.windowMinutes == Self.weekMinutes)
        #expect(primary.resetsAt == Self.weeklyReset)
        // The duplicate pool row (monthly reset) and the separate Grok Bot row are gone.
        #expect(usage.extraRateWindows?.contains { $0.id == "cursor-pool-models" } != true)
        #expect(usage.extraRateWindows?.contains { $0.id == "cursor-grok-bot" } != true)
        #expect(usage.identity?.loginMethod == "Cursor Ultra")

        let orbit = try #require(MidasOrbitQuota.make(provider: .cursor, snapshot: usage))
        #expect(orbit.title == "Weekly limit")
        #expect(orbit.remainingPercent == 89)
        #expect(orbit.resetsAt == Self.weeklyReset)
    }

    @Test
    func `unified plan without a weekly reading is unknown, not a full allowance`() {
        let usage = Self.snapshot(
            membershipType: "unified_ultra",
            unified: true,
            weeklyUsed: nil,
            unavailable: "timeout").toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(MidasOrbitQuota.make(provider: .cursor, snapshot: usage) == nil)
        // The unavailable Grok Bot row stays so the last known weekly reading can be kept.
        #expect(usage.extraRateWindows?.first { $0.id == "cursor-grok-bot" }?.usageKnown == false)
        #expect(usage.identity?.loginMethod == "Cursor Ultra")
    }

    @Test
    func `legacy monthly plans keep the monthly total and their pool rows`() throws {
        let usage = Self.snapshot(membershipType: "pro", unified: false, weeklyUsed: 40).toUsageSnapshot()

        let primary = try #require(usage.primary)
        #expect(primary.usedPercent == 0)
        #expect(primary.resetsAt == Self.cycleEnd)
        #expect(usage.extraRateWindows?.contains { $0.id == "cursor-pool-models" } == true)
        #expect(usage.extraRateWindows?.contains { $0.id == "cursor-grok-bot" } == true)
        #expect(MidasOrbitQuota.make(provider: .cursor, snapshot: usage)?.title == "Monthly limit")
    }

    @Test
    func `unified detection prefers the dashboard flag and falls back to the membership type`() throws {
        let json = #"{"usagePercent":11.07,"hasNonZeroIncludedLimit":true,"isUnified":true,"cursorPlanName":"Ultra"}"#
        let status = try JSONDecoder().decode(CursorSandUsageStatus.self, from: Data(json.utf8))
        #expect(status.isUnified == true)
        #expect(status.cursorPlanName == "Ultra")

        #expect(CursorStatusProbe.isUnifiedPlan(membershipType: "pro", sandStatus: status))
        #expect(CursorStatusProbe.isUnifiedPlan(membershipType: "unified_ultra", sandStatus: nil))
        #expect(!CursorStatusProbe.isUnifiedPlan(membershipType: "pro", sandStatus: nil))
        #expect(!CursorStatusProbe.isUnifiedPlan(
            membershipType: "unified_ultra",
            sandStatus: CursorSandUsageStatus(isUnified: false)))
    }
}
