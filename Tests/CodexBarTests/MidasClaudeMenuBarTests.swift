import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MidasClaudeMenuBarTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test
    func `orbit uses total weekly allowance and ignores exhausted session and model limits`() throws {
        let model = try self.orbit(sessionUsed: 100, weeklyUsed: 40, scopedUsed: 100)
        #expect(model.orbitRemainingPercent == 60)
        #expect(!model.attention)
        #expect(model.accessibilityLabel.contains("60 percent remaining, Weekly limit"))
        #expect(!model.accessibilityLabel.contains("5-hour"))
        #expect(!model.accessibilityLabel.contains("Model"))
        #expect(!model.tooltip.contains("Model"))
    }

    @Test
    func `orbit does not substitute session or scoped quota when weekly is missing`() throws {
        let model = try self.orbit(sessionUsed: 20, weeklyUsed: nil, scopedUsed: 80)
        #expect(model.orbitRemainingPercent == nil)
        #expect(model.accessibilityLabel.contains("weekly quota unavailable"))
        #expect(!model.attention)
    }

    @Test
    func `orbit does not infer all-model weekly allowance from ambiguous primary fallback`() throws {
        let model = try self.orbit(sessionUsed: 65, weeklyUsed: nil, scopedUsed: 100, primaryMinutes: 10080)
        #expect(model.orbitRemainingPercent == nil)
        #expect(!model.attention)
    }

    @Test
    func `orbit still warns when total weekly allowance is low`() throws {
        let model = try self.orbit(sessionUsed: 0, weeklyUsed: 95, scopedUsed: 0)
        #expect(model.orbitRemainingPercent == 5)
        #expect(model.attention)
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
    func `orbit rejects nonfinite weekly allowance`(used: Double) throws {
        let model = try self.orbit(sessionUsed: 20, weeklyUsed: used, scopedUsed: 0)
        #expect(model.orbitRemainingPercent == nil)
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
    func `orbit rejects nonfinite primary weekly fallback`(used: Double) throws {
        let model = try self.orbit(sessionUsed: used, weeklyUsed: nil, scopedUsed: 0, primaryMinutes: 10080)
        #expect(model.orbitRemainingPercent == nil)
    }

    private func orbit(
        sessionUsed: Double,
        weeklyUsed: Double?,
        scopedUsed: Double,
        primaryMinutes: Int = 300) throws -> MidasMenuBarPresentation
    {
        func window(_ used: Double, minutes: Int) -> RateWindow {
            RateWindow(usedPercent: used, windowMinutes: minutes, resetsAt: nil, resetDescription: nil)
        }
        let snapshot = UsageSnapshot(
            primary: window(sessionUsed, minutes: primaryMinutes),
            secondary: weeklyUsed.map { window($0, minutes: 10080) },
            extraRateWindows: [NamedRateWindow(
                id: "claude-weekly-scoped-example",
                title: "Example Model only",
                window: window(scopedUsed, minutes: 10080))],
            updatedAt: self.now)
        let card = try UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: #require(ProviderDefaults.metadata[.claude]),
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
            showOptionalCreditsAndExtraUsage: false,
            hidePersonalInfo: false,
            now: self.now))
        let item = MidasProviderPresentation.make(
            provider: .claude,
            card: card,
            snapshot: snapshot,
            tokenSnapshot: nil,
            isRefreshing: false,
            isStale: false)
        return MidasMenuBarPresentation(
            mode: .orbit,
            presentations: [item],
            focusProvider: .claude,
            refreshingProviders: [],
            hideSpend: true,
            now: self.now)
    }
}
