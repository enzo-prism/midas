import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MidasCursorPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_788_523_200)

    @Test func dashboardPoolsRemainIndependentQuotaRows() throws {
        let snapshot = self.cursorSnapshot().toUsageSnapshot()
        let model = try self.presentation(snapshot)
        #expect(model.hero?.remainingPercent == 70)
        #expect(model.metrics.first { $0.id == "cursor-pool-models" }?.remainingPercent == 80)
        #expect(model.metrics.first { $0.id == "cursor-pool-other" }?.remainingPercent == 55)
        #expect(model.metrics.first { $0.id == "cursor-grok-bot" }?.remainingPercent == 20)
        #expect(model.metrics.first { $0.id == "cursor-grok-bot" }?.resetText != nil)
    }

    @Test func modelSpendShareNeverMasqueradesAsRemainingQuota() throws {
        let model = try self.presentation(self.cursorSnapshot().toUsageSnapshot())
        #expect(model.metrics.contains { $0.id == "cursor-models" } == false)
        #expect(model.notes.contains { $0.contains("68% Cursor Models") && $0.contains("32% Other Models") })
    }

    @Test func modelMixOnlySnapshotHasAnInformativeSummaryWithoutInventingQuota() throws {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "cursor-models",
                    title: "Models",
                    window: RateWindow(
                        usedPercent: 68,
                        windowMinutes: nil,
                        resetsAt: nil,
                        resetDescription: nil)),
            ],
            updatedAt: self.now)
        let model = try self.presentation(snapshot)
        #expect(model.hero == nil)
        #expect(model.metrics.isEmpty)
        #expect(model.summary.contains("68% Cursor Models"))
    }

    @Test func legacyRequestQuotaKeepsTheActualCount() throws {
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 69.4,
                windowMinutes: 43200,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            cursorRequests: CursorRequestUsage(
                used: 347,
                limit: 500),
            updatedAt: self.now)
        let model = try self.presentation(snapshot)
        #expect(model.hero?.title == "Requests")
        #expect(model.notes.contains { $0.contains("347 / 500") })
    }

    @Test func cursorDailyEstimatesAndMeteredConsumptionStaySeparate() {
        let snapshot = self.costSnapshot(
            rows: [self.costDay(
                "2026-09-04",
                cost: 1.25)],
            metered: 0.40)
        let model = MidasCostPresentation(
            snapshot: snapshot,
            period: .week,
            now: self.now)
        #expect(model.costLabel == "API-equivalent value")
        #expect(model.totalCost == 1.25)
        #expect(model.meteredTotal == 0.40)
        #expect(model.models.first?.cost == 1.25)
        #expect(model.currency == "USD")
        #expect(model.explanation.contains("not a bill"))
    }

    @Test func meteredOnlySnapshotCannotFillTheDailyEstimateTotal() {
        let model = MidasCostPresentation(
            snapshot: self.costSnapshot(
                rows: [],
                metered: 0.40),
            period: .week,
            now: self.now)
        #expect(model.totalCost == nil)
        #expect(model.meteredTotal == 0.40)
        #expect(model.days.isEmpty)
    }

    @Test func missingModelPricesRemainUnavailable() {
        let model = MidasCostPresentation(
            snapshot: self.costSnapshot(
                rows: [self.costDay(
                    "2026-09-04",
                    cost: nil)],
                metered: nil),
            period: .all,
            now: self.now)
        #expect(model.models.first?.cost == nil)
        #expect(model.totalCost == nil)
        #expect(model.models.first?.tokens == 120)
    }

    private func presentation(_ snapshot: UsageSnapshot) throws -> MidasProviderPresentation {
        let card = try UsageMenuCardView.Model.make(.init(
            provider: .cursor,
            metadata: #require(ProviderDefaults.metadata[.cursor]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(
                email: nil,
                plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: self.now))
        return .make(
            provider: .cursor,
            card: card,
            snapshot: snapshot,
            tokenSnapshot: nil,
            isRefreshing: false,
            isStale: false)
    }

    private func cursorSnapshot() -> CursorStatusSnapshot {
        CursorStatusSnapshot(
            planPercentUsed: 30,
            planUsedUSD: 15,
            planLimitUSD: 50,
            onDemandUsedUSD: 0,
            onDemandLimitUSD: nil,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleStart: self.now.addingTimeInterval(-10 * 86400),
            billingCycleEnd: self.now.addingTimeInterval(20 * 86400),
            membershipType: "pro",
            accountEmail: "fixture@example.com",
            accountName: nil,
            rawJSON: nil,
            cursorModelUsedUSD: 68,
            nonCursorModelUsedUSD: 32,
            cursorModelsUsedPercent: 20,
            otherModelsUsedPercent: 45,
            grokBotWeeklyUsedPercent: 80,
            grokBotWeeklyReset: self.now.addingTimeInterval(86400))
    }

    private func costDay(
        _ date: String,
        cost: Double?) -> CostUsageDailyReport.Entry
    {
        .init(
            date: date,
            inputTokens: 100,
            outputTokens: 20,
            totalTokens: 120,
            requestCount: 1,
            costUSD: cost,
            modelsUsed: ["example-model"],
            modelBreakdowns: [
                .init(
                    modelName: "example-model",
                    costUSD: cost,
                    totalTokens: 120,
                    requestCount: 1),
            ])
    }

    private func costSnapshot(
        rows: [CostUsageDailyReport.Entry],
        metered: Double?) -> CostUsageTokenSnapshot
    {
        .init(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyDays: 30,
            meteredCostUSD: metered,
            costProvenance: .mixed,
            daily: rows,
            updatedAt: self.now)
    }
}
