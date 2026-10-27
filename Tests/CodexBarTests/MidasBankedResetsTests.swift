import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MidasBankedResetsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(count: Int?) -> UsageSnapshot {
        UsageSnapshot(
            primary: nil,
            secondary: nil,
            codexResetCredits: count.map { .countOnly(availableCount: $0, updatedAt: self.now) },
            updatedAt: self.now)
    }

    private func presentation(
        count: Int?,
        provider: UsageProvider = .codex,
        stale: Bool = false,
        refreshing: Bool = false) -> MidasProviderPresentation
    {
        MidasProviderPresentation.make(
            provider: provider,
            card: nil,
            snapshot: self.snapshot(count: count),
            tokenSnapshot: nil,
            isRefreshing: refreshing,
            isStale: stale)
    }

    @Test(arguments: [0, 3, 7])
    func snapshotCountSurvivesWithoutCardOrQuotaWindows(count: Int) {
        let result = self.presentation(count: count)
        #expect(result.resetCreditsText == "\(count) unused")
        #expect(MidasBankedResetsState.value(result) == "\(count) unused")
        #expect(result.hero == nil)
        #expect(result.metrics.isEmpty)
        if count == 0 {
            #expect(result.resetCreditsHelp == "You have no rate limit resets")
        } else {
            #expect(result.resetCreditsHelp?.contains("expiry times unavailable") == true)
        }
    }

    @Test func missingCountIsUnavailableNotZero() {
        let result = self.presentation(count: nil)
        #expect(result.resetCreditsText == nil)
        #expect(result.resetCreditsHelp == nil)
        #expect(MidasBankedResetsState.value(result) == "Unavailable")
        #expect(MidasBankedResetsState.value(self.presentation(count: nil, refreshing: true)) == "Refreshing…")
    }

    @Test func unusedCreditDoesNotBecomeUsableReset() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            codexResetCredits: .countOnly(
                availableCount: 1, updatedAt: self.now, applicableAvailableCount: 0),
            updatedAt: self.now)
        let result = MidasProviderPresentation.make(
            provider: .codex,
            card: nil,
            snapshot: snapshot,
            tokenSnapshot: nil,
            isRefreshing: false,
            isStale: false)
        #expect(MidasBankedResetsState.value(result) == "0 usable now")
        #expect(result.resetCreditsHelp?.contains("1 unused reset credit") == true)
        #expect(result.resetCreditsHelp?.contains("0 apply") == true)
    }

    @Test func retainedCountDisclosesStalenessAndSurvivesRefresh() {
        #expect(MidasBankedResetsState.value(self.presentation(count: 3, stale: true)) == "3 unused · last known")
        #expect(MidasBankedResetsState.value(self.presentation(count: 0, stale: true)) == "0 unused · last known")
        #expect(MidasBankedResetsState.value(self.presentation(count: 7, refreshing: true)) == "7 unused")
    }

    @Test func anotherProviderCannotBorrowCodexResetCount() {
        let result = self.presentation(count: 7, provider: .claude)
        #expect(result.resetCreditsText == nil)
        #expect(result.resetCreditsHelp == nil)
    }

    @Test func perAccountEntriesKeepDistinctResetCounts() {
        for (id, count) in [("first", 3), ("second", 7)] {
            let account = CodexVisibleAccount(
                id: id,
                email: "\(id)@example.com",
                storedAccountID: nil,
                selectionSource: .liveSystem,
                isActive: false,
                isLive: false,
                canReauthenticate: false,
                canRemove: false)
            let usage = MidasCodexAccountPolicy.usage(
                for: account,
                entry: CodexAccountUsageSnapshot(
                    account: account,
                    snapshot: self.snapshot(count: count),
                    error: nil,
                    sourceLabel: "oauth"),
                providerSnapshot: self.snapshot(count: 99),
                providerError: nil,
                refreshGuard: nil)
            let result = MidasProviderPresentation.make(
                provider: .codex,
                card: nil,
                snapshot: usage.snapshot,
                tokenSnapshot: nil,
                isRefreshing: false,
                isStale: false)
            #expect(result.resetCreditsText == "\(count) unused")
        }
    }
}
