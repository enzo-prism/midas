import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Verified Ultra accounts (the renamed Max 20x plan) have no 5-hour limit since 2026-10-30.
struct ClaudeUltraNoFiveHourLimitTests {
    private static let now = Date(timeIntervalSince1970: 1_793_000_000)

    // MARK: - Plan names

    @Test
    func `max 20x tier resolves to ultra and max 5x stays max`() {
        #expect(ClaudePlan.oauthLoginMethod(rateLimitTier: "default_claude_max_20x") == "Claude Ultra")
        #expect(ClaudePlan.oauthLoginMethod(rateLimitTier: "default_claude_max_5x") == "Claude Max")
        #expect(ClaudePlan.oauthLoginMethod(rateLimitTier: "default_claude_ultra") == "Claude Ultra")
        #expect(
            ClaudePlan.oauthLoginMethod(subscriptionType: "max", rateLimitTier: "default_claude_max_20x")
                == "Claude Ultra")
        #expect(
            ClaudePlan.oauthLoginMethod(subscriptionType: "max", rateLimitTier: "default_claude_max_5x")
                == "Claude Max")
        #expect(ClaudePlan.webLoginMethod(rateLimitTier: "default_claude_max_20x", billingType: nil) == "Claude Ultra")
        #expect(ClaudePlan.fromCompatibilityLoginMethod("Max 20x") == .ultra)
        #expect(ClaudePlan.fromCompatibilityLoginMethod("Claude Ultra") == .ultra)
        #expect(ClaudePlan.fromCompatibilityLoginMethod("Max 5x") == .max)
    }

    // MARK: - OAuth

    @Test
    func `oauth null five hour leaves weekly in the weekly slot only`() throws {
        let json = """
        {
          "five_hour": null,
          "seven_day": { "utilization": 49.0, "resets_at": "2026-11-06T07:00:00+00:00" },
          "seven_day_sonnet": { "utilization": 12.0, "resets_at": "2026-11-06T07:00:00+00:00" }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(
            Data(json.utf8),
            rateLimitTier: "default_claude_max_20x",
            subscriptionType: "max")
        #expect(snap.primary == nil)
        #expect(snap.secondary?.usedPercent == 49)
        #expect(snap.secondary?.windowMinutes == 7 * 24 * 60)
        #expect(snap.opus?.usedPercent == 12)
        #expect(snap.loginMethod == "Claude Ultra")
    }

    @Test
    func `oauth limits list without a session entry means no five hour limit`() throws {
        let json = """
        {
          "five_hour": { "utilization": 0.0, "resets_at": null },
          "seven_day": { "utilization": 49.0, "resets_at": "2026-11-06T07:00:00+00:00" },
          "limits": [
            {
              "kind": "weekly_all", "group": "weekly", "percent": 49,
              "resets_at": "2026-11-06T07:00:00+00:00", "scope": null, "is_active": false
            },
            {
              "kind": "weekly_scoped", "group": "weekly", "percent": 20,
              "resets_at": "2026-11-06T07:00:00+00:00",
              "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
              "is_active": false
            }
          ]
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.primary == nil)
        #expect(snap.secondary?.usedPercent == 49)
        #expect(snap.extraRateWindows.contains { $0.id == "claude-weekly-scoped-fable" })
    }

    @Test
    func `oauth limits list with a session entry keeps the five hour limit`() throws {
        let json = """
        {
          "five_hour": { "utilization": 0.0, "resets_at": null },
          "seven_day": { "utilization": 9.0, "resets_at": "2026-11-06T07:00:00+00:00" },
          "limits": [
            { "kind": "session", "group": "session", "percent": 0, "resets_at": null, "is_active": false },
            { "kind": "weekly_all", "group": "weekly", "percent": 9, "resets_at": null, "is_active": false }
          ]
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(
            Data(json.utf8),
            rateLimitTier: "default_claude_max_5x")
        #expect(snap.primary?.usedPercent == 0)
        #expect(snap.primary?.windowMinutes == 300)
    }

    @Test
    func `oauth zero stub hides the session on ultra but not on max`() throws {
        let json = """
        {
          "five_hour": { "utilization": 0.0, "resets_at": null },
          "seven_day": { "utilization": 49.0, "resets_at": "2026-11-06T07:00:00+00:00" }
        }
        """
        let ultra = try ClaudeUsageFetcher._mapOAuthUsageForTesting(
            Data(json.utf8),
            rateLimitTier: "default_claude_max_20x")
        #expect(ultra.primary == nil)
        #expect(ultra.secondary?.usedPercent == 49)

        // An idle Max session reads the same way and is still a real 5-hour limit.
        let max = try ClaudeUsageFetcher._mapOAuthUsageForTesting(
            Data(json.utf8),
            rateLimitTier: "default_claude_max_5x")
        #expect(max.primary?.usedPercent == 0)
    }

    @Test
    func `oauth temporary limit on an unverified ultra account still shows`() throws {
        let json = """
        {
          "five_hour": { "utilization": 31.0, "resets_at": "2026-11-02T05:10:00+00:00" },
          "seven_day": { "utilization": 49.0, "resets_at": "2026-11-06T07:00:00+00:00" }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(
            Data(json.utf8),
            rateLimitTier: "default_claude_max_20x")
        #expect(snap.primary?.usedPercent == 31)
        #expect(snap.primary?.resetsAt != nil)
    }

    @Test
    func `oauth enterprise spend limit still fills the primary slot`() throws {
        let json = """
        {
          "five_hour": null,
          "seven_day": null,
          "extra_usage": { "is_enabled": true, "monthly_limit": 100000, "used_credits": 25000, "utilization": 25 }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.primaryWindowKind == .spendLimit)
        #expect(snap.primary?.usedPercent == 25)
    }

    // MARK: - Web

    @Test
    func `web limits list without a session entry reports no session`() throws {
        let json = """
        {
          "five_hour": null,
          "seven_day": { "utilization": 49, "resets_at": "2026-11-06T07:00:00.000Z" },
          "limits": [
            { "kind": "weekly_all", "group": "weekly", "percent": 49, "resets_at": "2026-11-06T07:00:00.000Z" }
          ]
        }
        """
        let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(Data(json.utf8))
        #expect(parsed.sessionPercentUsed == nil)
        #expect(parsed.sessionLimitListed == false)
        #expect(parsed.weeklyPercentUsed == 49)
    }

    @Test
    func `web fractional five hour utilization is read`() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2026-11-02T05:10:00.000Z" },
          "seven_day": { "utilization": 49, "resets_at": "2026-11-06T07:00:00.000Z" }
        }
        """
        let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(Data(json.utf8))
        #expect(parsed.sessionPercentUsed == 12.5)
        #expect(parsed.sessionLimitListed == nil)
    }

    // MARK: - CLI

    @Test
    func `cli usage panel without a session row keeps weekly values in place`() throws {
        let text = """
        Settings  Status  Config  Usage

        Current week (all models)
        ██████████████████████▌                            45% used
        Resets Nov 6, 12am (America/Los_Angeles)

        Current week (Sonnet only)
        ████                                               8% used
        Resets Nov 6, 12am (America/Los_Angeles)
        """
        let snap = try ClaudeStatusProbe.parse(text: text)
        #expect(snap.sessionPercentLeft == nil)
        #expect(snap.primaryResetDescription == nil)
        #expect(snap.weeklyPercentLeft == 55)
        #expect(snap.opusPercentLeft == 92)
    }

    @Test
    func `cli usage panel accepts the five hour limit row label`() throws {
        let text = """
        Settings  Status  Config  Usage

        5-hour limit
        ███████                                            14% used
        Resets 5:10am (America/Los_Angeles)

        Current week (all models)
        ██████████████████████▌                            45% used
        Resets Nov 6, 12am (America/Los_Angeles)
        """
        let snap = try ClaudeStatusProbe.parse(text: text)
        #expect(snap.sessionPercentLeft == 86)
        #expect(snap.weeklyPercentLeft == 55)
    }

    // MARK: - App surfaces

    private func weekly(_ used: Double) -> RateWindow {
        RateWindow(
            usedPercent: used,
            windowMinutes: 7 * 24 * 60,
            resetsAt: Self.now.addingTimeInterval(86400),
            resetDescription: nil)
    }

    @Test
    func `legacy claude icon fills its main bar with the weekly limit`() {
        let snapshot = UsageSnapshot(primary: nil, secondary: self.weekly(49), updatedAt: Self.now)
        let remaining = IconRemainingResolver.resolvedRemaining(snapshot: snapshot, style: .claude)
        #expect(remaining.primary == 51)
        #expect(remaining.secondary == nil)
        let used = IconRemainingResolver.resolvedPercents(snapshot: snapshot, style: .claude, showUsed: true)
        #expect(used.primary == 49)
    }

    @Test
    func `overview shows the weekly limit alone and explains why`() throws {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: self.weekly(49),
            updatedAt: Self.now,
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Claude Ultra"))
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
            now: Self.now))
        let presentation = MidasProviderPresentation.make(
            provider: .claude,
            card: card,
            snapshot: snapshot,
            tokenSnapshot: nil,
            isRefreshing: false,
            isStale: false)

        let overview = MidasAccountQuotaLayout.overviewMetrics(presentation)
        #expect(overview.map(\.title) == [MidasClaudeLimits.weeklyTitle])
        #expect(overview.first?.valueText == "51% left")
        #expect(overview.first?.helpText == MidasClaudeLimits.noFiveHourLimitHelp)
        #expect(presentation.hero?.title == MidasClaudeLimits.weeklyTitle)
    }
}
