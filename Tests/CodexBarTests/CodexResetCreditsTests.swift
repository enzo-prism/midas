import Foundation
import Testing
@testable import CodexBarCore

struct CodexResetCreditsTests {
    private static let dedicatedResponseJSON = """
    {
      "credits": [
        {
          "id": "RateLimitResetCredit_aaa",
          "reset_type": "codex_rate_limits",
          "is_supported_by_plan": true,
          "status": "available",
          "granted_at": "2026-09-04T02:38:09.384821Z",
          "expires_at": "2026-10-04T02:38:09.384821Z",
          "redeem_started_at": null,
          "redeemed_at": null,
          "title": "Full reset",
          "description": "Thanks for using Codex! You've been granted one free rate limit reset."
        },
        {
          "id": "RateLimitResetCredit_spent",
          "reset_type": "codex_rate_limits",
          "is_supported_by_plan": true,
          "status": "redeemed",
          "granted_at": "2026-08-01T00:00:00Z",
          "expires_at": "2026-09-01T00:00:00Z",
          "title": "Full reset",
          "description": "Spent credit."
        }
      ],
      "available_count": 1,
      "total_earned_count": 0,
      "immediate_reset_purchase_eligible": false,
      "history_enabled": false
    }
    """

    private static let usageBodyJSON = """
    {
      "plan_type": "pro",
      "rate_limit": {
        "primary_window": {
          "used_percent": 13,
          "reset_at": 1789050865,
          "limit_window_seconds": 604800
        },
        "secondary_window": null
      },
      "rate_limit_reset_credits": {
        "available_count": 1,
        "applicable_available_count": 0
      }
    }
    """

    private static func credentials() -> CodexOAuthCredentials {
        CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())
    }

    @Test
    func `unrecognized dedicated payload cannot replace usage count with zero`() {
        for json in ["{}", #"{"credits":"broken"}"#] {
            #expect(throws: DecodingError.self) {
                try CodexOAuthUsageFetcher._decodeResetCreditsResponseForTesting(Data(json.utf8))
            }
        }
    }

    @Test
    func `missing dedicated count uses usage count and reports missing expiries`() throws {
        let json = #"{"credits":[{"id":"one","status":"available"},"broken"]}"#
        let response = try CodexOAuthUsageFetcher._decodeResetCreditsResponseForTesting(Data(json.utf8))
        let now = Date()
        let snapshot = CodexResetCreditsSnapshot.fromResponse(
            response,
            fallbackAvailableCount: 3,
            updatedAt: now)
        #expect(snapshot.availableCount == 3)
        #expect(snapshot.availableCredits.count == 1)
        #expect(CodexResetCreditFormatting.tooltipText(snapshot: snapshot, now: now)
            .contains("2 additional resets: expiry times unavailable"))
    }

    @Test
    func `reset only OAuth response remains usable without windows or monetary credits`() throws {
        let json = #"{"plan_type":"pro","rate_limit_reset_credits":{"available_count":2}}"#
        let result = try CodexOAuthFetchStrategy._mapResultForTesting(
            Data(json.utf8),
            credentials: Self.credentials())
        #expect(result.usage.primary == nil)
        #expect(result.credits == nil)
        #expect(result.usage.codexResetCredits?.availableCount == 2)
    }

    @Test
    func `decodes dedicated reset credits response with expiries`() throws {
        let response = try CodexOAuthUsageFetcher._decodeResetCreditsResponseForTesting(
            Data(Self.dedicatedResponseJSON.utf8))
        #expect(response.availableCount == 1)
        #expect(response.credits.count == 2)
        let first = try #require(response.credits.first)
        #expect(first.id == "RateLimitResetCredit_aaa")
        #expect(first.isAvailable)
        #expect(first.title == "Full reset")
        #expect(first.expiresAt != nil)
        #expect(first.grantedAt != nil)
    }

    @Test
    func `malformed credit entry does not drop siblings`() throws {
        let json = """
        {
          "credits": [
            { "id": "good", "status": "available", "expires_at": "2026-10-04T02:38:09Z" },
            "not-an-object",
            { "id": "also-good", "status": "available" }
          ],
          "available_count": 2
        }
        """
        let response = try CodexOAuthUsageFetcher._decodeResetCreditsResponseForTesting(Data(json.utf8))
        #expect(response.credits.count == 2)
        #expect(response.credits.map(\.id).sorted() == ["also-good", "good"])
    }

    @Test
    func `snapshot prefers dedicated available count and sorts soonest first`() throws {
        let response = try CodexOAuthUsageFetcher._decodeResetCreditsResponseForTesting(
            Data(Self.dedicatedResponseJSON.utf8))
        let snapshot = CodexResetCreditsSnapshot.fromResponse(response, updatedAt: Date())
        #expect(snapshot.availableCount == 1)
        #expect(snapshot.hasPerCreditExpiries)
        // Spent credits are excluded from the redeemable set.
        #expect(snapshot.availableCredits.count == 1)
        #expect(snapshot.availableCredits.first?.id == "RateLimitResetCredit_aaa")
        #expect(snapshot.soonestExpiry != nil)
    }

    @Test
    func `usage body summary decodes counts`() throws {
        let usage = try CodexOAuthUsageFetcher._decodeUsageResponseForTesting(Data(Self.usageBodyJSON.utf8))
        let summary = try #require(usage.rateLimitResetCredits)
        #expect(summary.availableCount == 1)
        #expect(summary.applicableAvailableCount == 0)
    }

    @Test
    func `fromOAuth falls back to usage body count when dedicated fetch is unavailable`() throws {
        let mapped = try CodexOAuthFetchStrategy._mapUsageForTesting(
            Data(Self.usageBodyJSON.utf8),
            credentials: Self.credentials())
        let snapshot = try #require(mapped)
        let resetCredits = try #require(snapshot.codexResetCredits)
        #expect(resetCredits.availableCount == 1)
        #expect(resetCredits.hasPerCreditExpiries == false)
        #expect(resetCredits.credits.isEmpty)
        // Primary/weekly mapping is unchanged by the fallback: the lone 7-day
        // primary window normalizes to the weekly lane.
        #expect(snapshot.secondary?.usedPercent == 13)
    }

    @Test
    func `fromOAuth keeps nil reset state when usage body reports no counts`() throws {
        let json = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {
              "used_percent": 13,
              "reset_at": 1789050865,
              "limit_window_seconds": 604800
            }
          }
        }
        """
        let mapped = try CodexOAuthFetchStrategy._mapUsageForTesting(
            Data(json.utf8),
            credentials: Self.credentials())
        let snapshot = try #require(mapped)
        #expect(snapshot.codexResetCredits == nil)
    }

    @Test
    func `explicit reset snapshot passes through fromOAuth with expiries`() throws {
        let usage = try CodexOAuthUsageFetcher._decodeUsageResponseForTesting(Data(Self.usageBodyJSON.utf8))
        let response = try CodexOAuthUsageFetcher._decodeResetCreditsResponseForTesting(
            Data(Self.dedicatedResponseJSON.utf8))
        let now = Date()
        let resetCredits = CodexResetCreditsSnapshot.fromResponse(response, updatedAt: now)
        let reconciled = CodexReconciledState.fromOAuth(
            response: usage,
            credentials: Self.credentials(),
            resetCredits: resetCredits,
            updatedAt: now)
        let state = try #require(reconciled)
        let snapshot = state.toUsageSnapshot()
        #expect(snapshot.codexResetCredits?.hasPerCreditExpiries == true)
        #expect(snapshot.codexResetCredits?.availableCredits.count == 1)
    }

    @Test
    func `reset credits survive a usage snapshot encode decode round trip`() throws {
        let response = try CodexOAuthUsageFetcher._decodeResetCreditsResponseForTesting(
            Data(Self.dedicatedResponseJSON.utf8))
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let original = UsageSnapshot(
            primary: nil,
            secondary: nil,
            codexResetCredits: CodexResetCreditsSnapshot.fromResponse(response, updatedAt: now),
            updatedAt: now,
            identity: nil)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(original))
        let resetCredits = try #require(decoded.codexResetCredits)
        #expect(resetCredits.availableCount == 1)
        #expect(resetCredits.hasPerCreditExpiries)
        #expect(resetCredits.availableCredits.first?.id == "RateLimitResetCredit_aaa")
    }

    @Test
    func `expiry urgency honors the 48 hour and 7 day boundaries`() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        func snapshot(expiringIn seconds: TimeInterval) -> CodexResetCreditsSnapshot {
            let credit = CodexResetCredit(
                id: "c",
                status: "available",
                expiresAt: now.addingTimeInterval(seconds))
            return CodexResetCreditsSnapshot(
                credits: [credit],
                availableCount: 1,
                hasPerCreditExpiries: true,
                updatedAt: now)
        }
        #expect(snapshot(expiringIn: 3600).expiryUrgency(now: now) == .imminent)
        #expect(snapshot(expiringIn: 3 * 24 * 3600).expiryUrgency(now: now) == .soon)
        #expect(snapshot(expiringIn: 30 * 24 * 3600).expiryUrgency(now: now) == .distant)
        let empty = CodexResetCreditsSnapshot(
            credits: [],
            availableCount: 0,
            hasPerCreditExpiries: true,
            updatedAt: now)
        #expect(empty.expiryUrgency(now: now) == .none)
    }

    @Test
    func `formatting covers count fallback and empty states`() {
        UsageFormatter.setLocaleProvider { Locale(identifier: "en_US_POSIX") }
        defer { UsageFormatter.clearLocaleProvider() }
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        #expect(CodexResetCreditFormatting.countText(availableCount: 1) == "1 available")
        #expect(CodexResetCreditFormatting.countText(availableCount: 0) == "0 available")

        let fallback = CodexResetCreditsSnapshot.countOnly(availableCount: 2, updatedAt: now)
        #expect(CodexResetCreditFormatting.soonestDetail(snapshot: fallback, now: now) == "Expiry times unavailable")
        let fallbackTooltip = CodexResetCreditFormatting.tooltipText(snapshot: fallback, now: now)
        #expect(fallbackTooltip.contains("2 available"))
        #expect(fallbackTooltip.contains("expiry times unavailable"))

        let empty = CodexResetCreditsSnapshot(
            credits: [],
            availableCount: 0,
            hasPerCreditExpiries: true,
            updatedAt: now)
        #expect(CodexResetCreditFormatting.soonestDetail(snapshot: empty, now: now) == nil)
        #expect(CodexResetCreditFormatting.tooltipText(snapshot: empty, now: now) == "You have no rate limit resets")
    }

    @Test
    func `formatting lists each credit expiry soonest first`() throws {
        UsageFormatter.setLocaleProvider { Locale(identifier: "en_US_POSIX") }
        defer { UsageFormatter.clearLocaleProvider() }
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let soon = CodexResetCredit(
            id: "soon",
            status: "Available",
            expiresAt: now.addingTimeInterval(29 * 24 * 3600),
            title: "Full reset")
        let later = CodexResetCredit(
            id: "later",
            status: "available",
            expiresAt: now.addingTimeInterval(60 * 24 * 3600),
            title: "Full reset")
        let snapshot = CodexResetCreditsSnapshot(
            credits: [later, soon],
            availableCount: 2,
            hasPerCreditExpiries: true,
            updatedAt: now)
        // Status matching is case-insensitive and ordering is soonest first.
        #expect(snapshot.availableCredits.map(\.id) == ["soon", "later"])
        let detail = try #require(CodexResetCreditFormatting.soonestDetail(snapshot: snapshot, now: now))
        #expect(detail.hasPrefix("Soonest expires "))
        #expect(detail.contains("in 29d"))
        let tooltip = CodexResetCreditFormatting.tooltipText(snapshot: snapshot, now: now)
        let lines = tooltip.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("1. Expires "))
        #expect(lines[0].contains("in 29d"))
        #expect(lines[1].hasPrefix("2. Expires "))
    }

    @Test
    func `backfilling reset times preserves reset credits`() throws {
        let response = try CodexOAuthUsageFetcher._decodeResetCreditsResponseForTesting(
            Data(Self.dedicatedResponseJSON.utf8))
        let now = Date()
        let resetCredits = CodexResetCreditsSnapshot.fromResponse(response, updatedAt: now)
        // Fresh snapshot lacks a reset time, so the backfill rebuilds the
        // snapshot from cached data — reset credits must survive the rebuild.
        let fresh = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(
                usedPercent: 13,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil),
            codexResetCredits: resetCredits,
            updatedAt: now,
            identity: nil)
        let cached = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(
                usedPercent: 13,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(7200),
                resetDescription: nil),
            codexResetCredits: resetCredits,
            updatedAt: now,
            identity: nil)
        let backfilled = fresh.backfillingResetTimes(from: cached, now: now)
        #expect(backfilled.secondary?.resetsAt != nil)
        #expect(backfilled.codexResetCredits == resetCredits)
    }

    @Test
    func `reset credits endpoint resolves under the usage base URL`() {
        let defaultURL = CodexOAuthUsageFetcher._resolveResetCreditsURLForTesting(env: [:])
        #expect(defaultURL.absoluteString == "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")
    }
}
