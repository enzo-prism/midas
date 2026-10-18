import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MidasCloudUsagePresentationTests {
    private let now = Date(timeIntervalSince1970: 1_789_171_200)

    @Test func combinedHistoryRetainsBothAccountsWithoutReplacingSharedSpend() throws {
        var shared = self.presentation(tokens: 900, dollars: 77)
        shared.spend = MidasSpendPresentation(
            title: "Estimated inference spend",
            value: "$77.00",
            period: "September",
            detail: "Shared sessions, counted once.",
            updatedAt: self.now,
            amount: 77,
            currency: "USD",
            secondaryValue: nil,
            secondaryLabel: nil,
            isEstimate: true)
        let accounts = try self.accounts()
        let cloud = self.snapshot(tokens: 300, dollars: 6)
        let result = MidasCloudUsagePresentation.attachingAccountHistory(
            to: shared,
            accounts: accounts,
            tokenSnapshot: cloud,
            estimate: MidasCodexEstimate(rate: 2, detail: "Cloud rate"),
            usesSyncedUsage: true)

        #expect(result.spend?.amount == 77)
        #expect(result.spend?.period == "September")
        #expect(result.spend?.detail == "Shared sessions, counted once.")
        #expect(result.spend?.updatedAt == shared.spend?.updatedAt)
        #expect(result.cloudUsage?.tokens == 300)
        #expect(result.cloudUsage?.accompaniesSharedUsage == true)
        #expect(result.cloudUsage?.period == "Last 30 days · UTC")
        #expect(result.cloudUsage?.accounts.map(\.name) == ["first@example.com", "second@example.com"])
        #expect(result.cloudUsage?.accounts.map { $0.usage?.totalTokens } == [100, 200])
        #expect(MidasTotalSpend(presentations: [result]).totals.first?.amount == 77)
    }

    @Test func combinedHistoryRetainsPerAccountErrorsAndFreshness() throws {
        var accounts = try self.accounts()
        accounts[1] = MidasCloudUsagePresentation.Account(
            id: accounts[1].id,
            name: accounts[1].name,
            usage: accounts[1].usage,
            error: "History refresh failed")
        let result = MidasCloudUsagePresentation.attachingAccountHistory(
            to: self.presentation(tokens: 900, dollars: 77),
            accounts: accounts,
            tokenSnapshot: self.snapshot(tokens: 300, dollars: nil),
            estimate: nil,
            usesSyncedUsage: true)
        let cloud = try #require(result.cloudUsage)

        #expect(cloud.accounts[0].error == nil)
        #expect(cloud.accounts[1].error == "History refresh failed")
        #expect(cloud.accounts[0].usage?.fetchedAt == self.now)
        #expect(cloud.accounts[1].usage?.fetchedAt == self.now.addingTimeInterval(-3600))
        #expect(cloud.accounts[1].usage?.statsAsOf == "2026-09-11")
        #expect(cloud.coverage == "2 of 2 account histories · OpenAI-reported · 1 refresh failure")
        #expect(result.spend?.amount == 77)
        #expect(MidasTotalSpend(presentations: [result]).hasIncompleteCoverage)
    }

    @Test func missingCloudSnapshotNeverLabelsSharedTokensAsAccountReported() throws {
        let result = try MidasCloudUsagePresentation.attachingAccountHistory(
            to: self.presentation(tokens: 900, dollars: 77),
            accounts: self.accounts(),
            tokenSnapshot: nil,
            estimate: nil,
            usesSyncedUsage: true)

        #expect(result.spend?.amount == 77)
        #expect(result.cloudUsage?.tokens == nil)
        #expect(result.cloudUsage?.accounts.count == 2)
    }

    @Test func cloudHistoryCannotFillInMissingSharedSpend() throws {
        let result = try MidasCloudUsagePresentation.attachingAccountHistory(
            to: self.presentation(tokens: nil, dollars: nil),
            accounts: self.accounts(),
            tokenSnapshot: self.snapshot(tokens: 300, dollars: 6),
            estimate: MidasCodexEstimate(rate: 2, detail: "Cloud rate"),
            usesSyncedUsage: true)

        #expect(result.spend == nil)
        #expect(result.cloudUsage?.tokens == 300)
        #expect(MidasTotalSpend(presentations: [result]).totals.isEmpty)
    }

    @Test func localCloudModeRetainsItsExistingEstimatePolicy() throws {
        let result = try MidasCloudUsagePresentation.attachingAccountHistory(
            to: self.presentation(tokens: 900, dollars: 77),
            accounts: self.accounts(),
            tokenSnapshot: self.snapshot(tokens: 300, dollars: 6),
            estimate: MidasCodexEstimate(rate: 2, detail: "Cloud rate"),
            usesSyncedUsage: false)

        #expect(result.spend?.amount == 6)
        #expect(result.spend?.period == "Last 30 days")
        #expect(result.spend?.detail.hasPrefix("Cloud rate") == true)
        #expect(result.cloudUsage?.tokens == 300)
        #expect(result.cloudUsage?.accompaniesSharedUsage == false)
        #expect(result.cloudUsage?.hasEstimate == true)

        let tokensOnly = try MidasCloudUsagePresentation.attachingAccountHistory(
            to: result,
            accounts: self.accounts(),
            tokenSnapshot: self.snapshot(tokens: 300, dollars: nil),
            estimate: nil,
            usesSyncedUsage: false)
        #expect(tokensOnly.spend == nil)
        #expect(tokensOnly.cloudUsage?.tokens == 300)
        #expect(tokensOnly.cloudUsage?.hasEstimate == false)
    }

    private func presentation(tokens: Int?, dollars: Double?) -> MidasProviderPresentation {
        .make(
            provider: .codex,
            card: nil,
            snapshot: nil,
            tokenSnapshot: self.snapshot(tokens: tokens, dollars: dollars),
            isRefreshing: false,
            isStale: false)
    }

    private func snapshot(tokens: Int?, dollars: Double?) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: tokens,
            last30DaysCostUSD: dollars,
            historyDays: 30,
            costProvenance: .listPriceEstimate,
            daily: [],
            updatedAt: self.now)
    }

    private func accounts() throws -> [MidasCloudUsagePresentation.Account] {
        try [100, 200].enumerated().map { index, tokens in
            let profile: [String: Any] = [
                "stats": ["daily_usage_buckets": [["start_date": "2026-09-10", "tokens": tokens]]],
                "metadata": ["stats_as_of": "2026-09-11"],
            ]
            let usage = try CodexCloudAccountUsage.parse(
                profile: JSONSerialization.data(withJSONObject: profile),
                breakdown: Data(#"{"units":"percent","data":[]}"#.utf8),
                now: self.now.addingTimeInterval(Double(index) * -3600))
            return MidasCloudUsagePresentation.Account(
                id: "account-\(index)",
                name: index == 0 ? "first@example.com" : "second@example.com",
                usage: usage,
                error: nil)
        }
    }
}
