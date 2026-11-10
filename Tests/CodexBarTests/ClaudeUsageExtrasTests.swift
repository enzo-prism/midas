import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeUsageExtrasTests {
    private static let now = Date(timeIntervalSince1970: 1_794_000_000) // 2026-11-06T18:40:00Z

    /// Shape of a live Ultra account's `usage?cedar_ember=1` response, with synthetic values.
    private static let payload = """
    {
      "five_hour": null,
      "seven_day": { "utilization": 30, "resets_at": "2026-11-13T23:00:00.342669+00:00" },
      "extra_usage": {
        "is_enabled": false, "monthly_limit": 200000, "used_credits": 0, "currency": "USD",
        "disabled_reason": "out_of_credits"
      },
      "limits": [
        { "kind": "weekly_all", "group": "weekly", "percent": 30, "severity": "normal",
          "resets_at": "2026-11-13T22:59:59.876770+00:00", "scope": null, "is_active": true },
        { "kind": "weekly_scoped", "group": "weekly", "percent": 2, "severity": "normal",
          "resets_at": "2026-11-13T22:59:59.876928+00:00",
          "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null }, "is_active": false }
      ],
      "spend": {
        "used": { "amount_minor": 0, "currency": "USD", "exponent": 2 },
        "limit": { "amount_minor": 200000, "currency": "USD", "exponent": 2 },
        "enabled": false, "disabled_reason": "out_of_credits", "balance": null, "auto_reload": null
      },
      "seven_day_breakdown": {
        "rows": [
          { "key": "claude_code", "display_name": "Claude Code", "percent": 93 },
          { "key": "chat", "display_name": "Chats", "percent": 0 },
          { "key": "claude_duet", "display_name": "Claude Duet", "percent": 7 }
        ]
      },
      "weekly_scoped_shares": [
        { "limit_index": 1, "used_percent_of_weekly": 1, "allowance_percent_of_weekly": 50 }
      ],
      "cedar_ember": {
        "eligible": true,
        "grants": [
          { "id": "grant-secret-1", "label": "Free limit reset", "resets_total": 1, "resets_left": 1,
            "starts_at": "2026-10-21T00:45:00+00:00", "ends_at": "2026-12-16T04:59:00+00:00",
            "clears": ["seven_day", "seven_day_overage_included"], "paused": false, "usable_now": true,
            "type": "weekly" },
          { "id": "grant-secret-2", "label": "Launch offer", "resets_total": 2, "resets_left": 2,
            "starts_at": "2026-11-01T18:00:00+00:00", "ends_at": "2027-03-09T07:59:00+00:00",
            "clears": ["seven_day_overage_included"], "paused": false, "usable_now": false, "type": "full" },
          { "id": "grant-secret-3", "resets_total": 1, "resets_left": 0,
            "ends_at": "2027-03-09T07:59:00+00:00", "clears": ["seven_day_overage_included"],
            "paused": false, "usable_now": false, "type": "full" },
          { "id": "grant-secret-4", "resets_left": 1, "ends_at": "2026-11-01T00:00:00+00:00",
            "clears": ["five_hour"], "paused": false },
          { "id": "grant-secret-5", "resets_left": 1, "clears": ["seven_day"], "paused": true },
          { "id": "grant-secret-6", "resets_left": 1, "starts_at": "2027-01-01T00:00:00+00:00",
            "clears": ["seven_day"], "paused": false }
        ]
      }
    }
    """

    @Test
    func `web usage response carries limit resets by kind with expiries`() throws {
        let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(Data(Self.payload.utf8))
        let resets = try #require(parsed.extras?.limitResets)

        #expect(parsed.weeklyPercentUsed == 30)
        #expect(resets.eligible)
        // Used-up, expired, paused and not-yet-started grants are held back.
        #expect(resets.availableCount(at: Self.now) == 3)
        #expect(resets.usableNowCount(at: Self.now) == 1)
        let summary = resets.summaryByKind(at: Self.now)
        #expect(summary.map(\.kind) == [.weekly, .scopedModel])
        #expect(summary.map(\.count) == [1, 2])
        #expect(resets.soonestExpiry(at: Self.now) == ISO8601DateFormatter().date(from: "2026-12-16T04:59:00Z"))
        #expect(ClaudeUsageExtrasFormatting.limitResetsCountText(resets, now: Self.now)
            == "3 available · 1 usable now")
        let help = ClaudeUsageExtrasFormatting.limitResetsHelpText(resets, now: Self.now)
        #expect(help.contains("1 Weekly reset, expires "))
        #expect(help.contains("2 Fable resets, expires "))
        // The Fable resets expire next year, so the year is spelled out.
        #expect(help.contains(", 2027"))
        #expect(!help.contains(", 2026"))
    }

    @Test
    func `credits state, product breakdown and scoped share become detail lines`() throws {
        let extras = try #require(ClaudeUsageExtrasParser.parse(data: Data(Self.payload.utf8)))

        #expect(extras.credits == ClaudeUsageCreditsState(
            enabled: false,
            disabledReason: "out_of_credits",
            currencyCode: "USD"))
        #expect(ClaudeUsageExtrasFormatting.noteLines(extras) == [
            "Usage credits: off (out of credits)",
            "Fable can use up to 50% of the weekly limit (1% used so far)",
            "This week by product: Claude Code 93% · Claude Duet 7%",
        ])
    }

    @Test
    func `credits line reports balance and auto reload when present`() {
        let credits = ClaudeUsageExtrasParser.credits(
            spend: [
                "enabled": true,
                "balance": ["amount_minor": 2550, "currency": "USD", "exponent": 2],
                "auto_reload": ["enabled": true],
            ] as [String: Any],
            extraUsage: nil)
        #expect(credits?.balance == 25.5)
        #expect(credits.flatMap(ClaudeUsageExtrasFormatting.creditsText)
            == "Usage credits: on · $25.50 balance · auto-reload on")
    }

    @Test
    func `saved resets never survive a cached or synced snapshot`() throws {
        let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(Self.payload.utf8))
        let live = try #require(usage.extras)
        #expect(live.limitResets != nil)

        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: usage.secondary,
            claudeUsageExtras: live,
            updatedAt: Self.now)
        let data = try JSONEncoder().encode(snapshot)
        let json = try #require(String(bytes: data, encoding: .utf8))
        #expect(!json.contains("grant-secret"))
        #expect(!json.contains("resetsLeft"))

        let restored = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        #expect(restored.claudeUsageExtras?.limitResets == nil)
        #expect(restored.claudeUsageExtras?.credits == live.credits)
        #expect(restored.claudeUsageExtras?.productBreakdown == live.productBreakdown)
    }

    @Test
    func `responses without the new blocks report no extras`() throws {
        let json = #"{"five_hour":{"utilization":9},"seven_day":{"utilization":4}}"#
        let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(Data(json.utf8))
        #expect(parsed.extras == nil)
        #expect(ClaudeUsageExtrasParser.parse(data: Data("not json".utf8)) == nil)
        #expect(ClaudeUsageExtrasParser.parse(json: ["cedar_ember": NSNull(), "spend": "x"]) == nil)
    }

    @Test
    func `only opt-in rejections are retried without the limit reset request`() {
        for status in [400, 403, 404, 422, 500, 503] {
            #expect(ClaudeOAuthUsageFetcher.shouldRetryWithoutLimitResets(statusCode: status))
        }
        for status in [200, 401, 429] {
            #expect(!ClaudeOAuthUsageFetcher.shouldRetryWithoutLimitResets(statusCode: status))
            #expect(!ClaudeWebAPIFetcher.shouldRetryWithoutLimitResets(statusCode: status))
        }
        #expect(ClaudeWebAPIFetcher.shouldRetryWithoutLimitResets(statusCode: 422))
    }

    @Test
    func `reset kind follows the windows a grant clears`() {
        #expect(ClaudeUsageExtrasParser.kind(clears: ["seven_day", "seven_day_overage_included"], type: "weekly")
            == .weekly)
        #expect(ClaudeUsageExtrasParser.kind(clears: ["seven_day_overage_included"], type: "full") == .scopedModel)
        #expect(ClaudeUsageExtrasParser.kind(clears: ["five_hour"], type: nil) == .fiveHour)
        #expect(ClaudeUsageExtrasParser.kind(clears: nil, type: "weekly") == .weekly)
        #expect(ClaudeUsageExtrasParser.kind(clears: [], type: "mystery") == .other)
    }
}
