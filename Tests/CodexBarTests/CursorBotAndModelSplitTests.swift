import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct CursorBotAndModelSplitTests {
    // MARK: - Fixture Parsing

    @Test
    func `parses bot usage and model split blocks`() throws {
        let json = """
        {
            "billingCycleStart": "2026-04-01T00:00:00.000Z",
            "billingCycleEnd": "2026-05-01T00:00:00.000Z",
            "membershipType": "pro",
            "individualUsage": {
                "plan": {
                    "enabled": true,
                    "used": 1500,
                    "limit": 5000,
                    "remaining": 3500,
                    "totalPercentUsed": 30.0
                },
                "botUsage": {
                    "enabled": true,
                    "used": 7500,
                    "limit": 10000,
                    "remaining": 2500
                },
                "modelSplit": {
                    "cursorModelCents": 6800,
                    "nonCursorModelCents": 3200
                }
            },
            "teamUsage": {
                "botUsage": {
                    "enabled": true,
                    "used": 100000,
                    "limit": 200000,
                    "remaining": 100000
                }
            }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let summary = try JSONDecoder().decode(CursorUsageSummary.self, from: data)

        #expect(summary.individualUsage?.botUsage?.used == 7500)
        #expect(summary.individualUsage?.botUsage?.limit == 10000)
        #expect(summary.individualUsage?.botUsage?.remaining == 2500)
        #expect(summary.individualUsage?.modelSplit?.cursorModelCents == 6800)
        #expect(summary.individualUsage?.modelSplit?.nonCursorModelCents == 3200)
        #expect(summary.teamUsage?.botUsage?.used == 100_000)
        #expect(summary.teamUsage?.botUsage?.limit == 200_000)
    }

    @Test
    func `missing bot and split blocks decode as nil`() throws {
        let json = """
        {
            "membershipType": "hobby",
            "individualUsage": {
                "plan": {
                    "used": 0,
                    "limit": 2000
                }
            }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let summary = try JSONDecoder().decode(CursorUsageSummary.self, from: data)

        #expect(summary.individualUsage?.botUsage == nil)
        #expect(summary.individualUsage?.modelSplit == nil)
        #expect(summary.teamUsage == nil)
    }

    // MARK: - Snapshot Mapping

    @Test
    func `individual bot quota drives Bot extra window`() throws {
        let snapshot = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
            .parseUsageSummary(
                CursorUsageSummary(
                    billingCycleStart: nil,
                    billingCycleEnd: nil,
                    membershipType: "pro",
                    limitType: nil,
                    isUnlimited: false,
                    autoModelSelectedDisplayMessage: nil,
                    namedModelSelectedDisplayMessage: nil,
                    individualUsage: CursorIndividualUsage(
                        plan: CursorPlanUsage(
                            enabled: true,
                            used: 1500,
                            limit: 5000,
                            remaining: 3500,
                            breakdown: nil,
                            autoPercentUsed: nil,
                            apiPercentUsed: nil,
                            totalPercentUsed: 30.0),
                        onDemand: nil,
                        botUsage: CursorBotUsage(enabled: true, used: 7500, limit: 10000, remaining: 2500),
                        modelSplit: CursorModelSplit(cursorModelCents: 6800, nonCursorModelCents: 3200)),
                    teamUsage: nil),
                userInfo: nil,
                rawJSON: nil)

        // Headline still comes from the plan block; bot data rides along untouched.
        #expect(snapshot.planPercentUsed == 30.0)
        #expect(snapshot.botUsedUSD == 75.0)
        #expect(snapshot.botLimitUSD == 100.0)
        #expect(snapshot.botUsedPercent == 75.0)
        #expect(snapshot.cursorModelUsedUSD == 68.0)
        #expect(snapshot.nonCursorModelUsedUSD == 32.0)
        #expect(snapshot.cursorModelSharePercent == 68.0)

        let windows = try #require(snapshot.toUsageSnapshot().extraRateWindows)
        let bot = try #require(windows.first(where: { $0.id == "cursor-bot" }))
        #expect(bot.title == "Bot")
        #expect(bot.window.usedPercent == 75.0)
        let models = try #require(windows.first(where: { $0.id == "cursor-models" }))
        #expect(models.title == "Models")
        #expect(abs(models.window.usedPercent - 68.0) < 0.0001)
    }

    @Test
    func `team bot pool is fallback when individual bot missing`() throws {
        let snapshot = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
            .parseUsageSummary(
                CursorUsageSummary(
                    billingCycleStart: nil,
                    billingCycleEnd: nil,
                    membershipType: "enterprise",
                    limitType: "team",
                    isUnlimited: false,
                    autoModelSelectedDisplayMessage: nil,
                    namedModelSelectedDisplayMessage: nil,
                    individualUsage: CursorIndividualUsage(
                        plan: nil,
                        onDemand: nil,
                        overall: CursorOverallUsage(enabled: true, used: 7384, limit: 10000, remaining: 2616)),
                    teamUsage: CursorTeamUsage(
                        onDemand: nil,
                        pooled: nil,
                        botUsage: CursorBotUsage(enabled: true, used: 50000, limit: 200_000, remaining: 150_000))),
                userInfo: nil,
                rawJSON: nil)

        #expect(snapshot.botUsedUSD == 500.0)
        #expect(snapshot.botLimitUSD == 2000.0)
        #expect(snapshot.botUsedPercent == 25.0)

        let windows = try #require(snapshot.toUsageSnapshot().extraRateWindows)
        let bot = try #require(windows.first(where: { $0.id == "cursor-bot" }))
        #expect(bot.window.usedPercent == 25.0)
    }

    @Test
    func `no bot or split blocks means no extra windows`() {
        let snapshot = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
            .parseUsageSummary(
                CursorUsageSummary(
                    billingCycleStart: nil,
                    billingCycleEnd: nil,
                    membershipType: "pro",
                    limitType: nil,
                    isUnlimited: false,
                    autoModelSelectedDisplayMessage: nil,
                    namedModelSelectedDisplayMessage: nil,
                    individualUsage: CursorIndividualUsage(
                        plan: CursorPlanUsage(
                            enabled: true,
                            used: 1500,
                            limit: 5000,
                            remaining: 3500,
                            breakdown: nil,
                            autoPercentUsed: nil,
                            apiPercentUsed: nil,
                            totalPercentUsed: 30.0),
                        onDemand: nil),
                    teamUsage: nil),
                userInfo: nil,
                rawJSON: nil)

        #expect(snapshot.botUsedPercent == nil)
        #expect(snapshot.cursorModelSharePercent == nil)
        #expect(snapshot.toUsageSnapshot().extraRateWindows == nil)
    }

    @Test
    func `bot without limit and empty split stay hidden`() {
        let snapshot = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
            .parseUsageSummary(
                CursorUsageSummary(
                    billingCycleStart: nil,
                    billingCycleEnd: nil,
                    membershipType: "pro",
                    limitType: nil,
                    isUnlimited: false,
                    autoModelSelectedDisplayMessage: nil,
                    namedModelSelectedDisplayMessage: nil,
                    individualUsage: CursorIndividualUsage(
                        plan: nil,
                        onDemand: nil,
                        botUsage: CursorBotUsage(enabled: true, used: 100, limit: nil, remaining: nil),
                        modelSplit: CursorModelSplit(cursorModelCents: nil, nonCursorModelCents: nil)),
                    teamUsage: nil),
                userInfo: nil,
                rawJSON: nil)

        #expect(snapshot.botUsedPercent == nil)
        #expect(snapshot.cursorModelSharePercent == nil)
        #expect(snapshot.toUsageSnapshot().extraRateWindows == nil)
    }

    // MARK: - Menu Card Rows

    @Test
    func `cursor card shows Bot and Models rows`() throws {
        let probe = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
        let cursorSnapshot = probe.parseUsageSummary(
            CursorUsageSummary(
                billingCycleStart: nil,
                billingCycleEnd: nil,
                membershipType: "pro",
                limitType: nil,
                isUnlimited: false,
                autoModelSelectedDisplayMessage: nil,
                namedModelSelectedDisplayMessage: nil,
                individualUsage: CursorIndividualUsage(
                    plan: CursorPlanUsage(
                        enabled: true,
                        used: 1500,
                        limit: 5000,
                        remaining: 3500,
                        breakdown: nil,
                        autoPercentUsed: nil,
                        apiPercentUsed: nil,
                        totalPercentUsed: 30.0),
                    onDemand: nil,
                    botUsage: CursorBotUsage(enabled: true, used: 7500, limit: 10000, remaining: 2500),
                    modelSplit: CursorModelSplit(cursorModelCents: 6800, nonCursorModelCents: 3200)),
                teamUsage: nil),
            userInfo: nil,
            rawJSON: nil)
        let snapshot = cursorSnapshot.toUsageSnapshot()
        let metadata = try #require(ProviderDefaults.metadata[.cursor])
        let now = Date(timeIntervalSince1970: 0)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .cursor,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let titles = model.metrics.map(\.title)
        #expect(titles.contains("Bot"))
        #expect(titles.contains("Models"))
        let bot = try #require(model.metrics.first(where: { $0.title == "Bot" }))
        #expect(bot.percent == 25.0)
        let models = try #require(model.metrics.first(where: { $0.title == "Models" }))
        #expect(abs(models.percent - 32.0) < 0.0001)

        // Rendered-card proof: the rows the SwiftUI card iterates render as "left" bars
        // (usage-left display) with known usage, so the card draws progress bars rather
        // than "Unavailable" placeholders.
        #expect(bot.id == "cursor-bot")
        #expect(bot.percentStyle == .left)
        #expect(bot.statusText == nil)
        #expect(models.id == "cursor-models")
        #expect(models.percentStyle == .left)
        #expect(models.statusText == nil)

        let usedModel = UsageMenuCardView.Model.make(.init(
            provider: .cursor,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let usedBot = try #require(usedModel.metrics.first(where: { $0.title == "Bot" }))
        #expect(usedBot.percentStyle == .used)
        #expect(usedBot.percent == 75.0)
        let usedModels = try #require(usedModel.metrics.first(where: { $0.title == "Models" }))
        #expect(usedModels.percentStyle == .used)
        #expect(abs(usedModels.percent - 68.0) < 0.0001)
    }
}
