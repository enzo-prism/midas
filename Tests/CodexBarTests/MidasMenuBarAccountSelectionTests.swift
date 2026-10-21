import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MidasMenuBarAccountSelectionTests {
    @Test func selectingSecondAccountUsesItsQuotaAndPreservesAggregateSpend() {
        let aggregate = self.item(
            remaining: 80,
            amount: 1234)
        let accounts = self.accounts()
        let projected = self.project(
            aggregate,
            accounts: accounts,
            id: "business")
        let ring = self.ring(projected)
        #expect(ring.orbitRemainingPercent == 23)
        #expect(projected.spend?.amount == aggregate.spend?.amount)
        #expect(self.ring(aggregate).title == ring.title)
        #expect(ring.accessibilityLabel.contains("Business"))
        #expect(ring.tooltip.contains("Business"))
        #expect(accounts.first?.isPrimary == true)
        #expect(accounts.last?.isPrimary == false)
    }

    @Test func missingSelectedAccountNeverFallsBackToPrimary() {
        let projected = self.project(
            self.item(
                remaining: 80,
                amount: 1234),
            accounts: self.accounts(),
            id: "removed")
        #expect(projected.hero == nil)
        #expect(projected.orbitQuota == nil)
        #expect(self.ring(projected).orbitRemainingPercent == nil)
        #expect(projected.error != nil)
        #expect(self.ring(projected).accessibilityLabel.contains("Selected account unavailable"))
        #expect(projected.spend?.amount == 1234)
    }

    @Test func unavailableSelectedAccountNeverBorrowsHealthyPrimaryQuota() {
        let unavailable = MidasAccountPresentation(
            id: "business",
            isPrimary: false,
            presentation: .make(
                provider: .codex,
                card: nil,
                snapshot: nil,
                tokenSnapshot: nil,
                isRefreshing: false,
                isStale: true),
            displayName: "Business")
        let projected = self.project(
            self.item(remaining: 80),
            accounts: [self.accounts()[0], unavailable],
            id: "business")
        #expect(self.ring(projected).orbitRemainingPercent == nil)
        #expect(projected.isStale)
        #expect(self.ring(projected).tooltip.contains("Business"))
    }

    @Test func selectedAccountRefreshErrorIsPreservedWithoutBorrowingAnotherQuota() {
        let failed = MidasProviderPresentation(
            provider: .codex,
            name: "Codex",
            account: "",
            plan: nil,
            hero: nil,
            metrics: [],
            resetCreditsText: nil,
            resetCreditsHelp: nil,
            freshness: "Refresh failed",
            error: "Sign in again",
            placeholder: "Usage unavailable",
            notes: [],
            financialSummary: nil,
            financialLabel: nil,
            isRefreshing: false,
            isStale: true,
            updatedAt: nil)
        let accounts = [self.accounts()[0], MidasAccountPresentation(
            id: "business",
            isPrimary: false,
            presentation: failed,
            displayName: "Business")]
        let projected = self.project(
            self.item(
                remaining: 80,
                amount: 1234),
            accounts: accounts,
            id: "business")
        #expect(projected.error == "Sign in again")
        #expect(self.ring(projected).attention)
        #expect(self.ring(projected).orbitRemainingPercent == nil)
        #expect(projected.spend?.amount == 1234)
    }

    @Test func accountIdentityIsRedactedAndProviderIdentityIsSiloed() {
        let projected = MidasMenuBarAccountSelection.project(
            providerPresentation: self.item(remaining: 80),
            accounts: self.accounts(),
            selectedAccountID: "business",
            hidePersonalInfo: true)
        let ring = self.ring(projected)
        #expect(!ring.accessibilityLabel.contains("Business"))
        #expect(ring.accessibilityLabel.contains("Account 2"))
        #expect(projected.account.isEmpty)
        let wrongProvider = MidasAccountPresentation(
            id: "business",
            isPrimary: false,
            presentation: .make(
                provider: .claude,
                card: nil,
                snapshot: nil,
                tokenSnapshot: nil,
                isRefreshing: false,
                isStale: false),
            displayName: "Other provider")
        let guarded = self.project(
            self.item(remaining: 80),
            accounts: [wrongProvider],
            id: "business")
        #expect(guarded.hero == nil)
        #expect(!self.ring(guarded).tooltip.contains("Other provider"))
    }

    @Test func unpinnedSelectionUsesPrimaryAndAccountlessProvidersStayUnchanged() {
        let accounts = Array(self.accounts().reversed())
        let selected = MidasMenuBarAccountSelection.selectedAccount(
            accounts: accounts,
            selectedAccountID: nil)
        #expect(selected?.id == "personal")
        let aggregate = self.item(
            remaining: 80,
            amount: 1234)
        let unchanged = self.project(
            aggregate,
            accounts: [],
            id: nil)
        #expect(unchanged.name == aggregate.name)
        #expect(unchanged.spend?.amount == aggregate.spend?.amount)
        #expect(self.ring(unchanged).orbitRemainingPercent == 80)
    }

    private func accounts() -> [MidasAccountPresentation] {
        [
            .init(
                id: "personal",
                isPrimary: true,
                presentation: self.item(remaining: 80),
                displayName: "Personal"),
            .init(
                id: "business",
                isPrimary: false,
                presentation: self.item(remaining: 23),
                displayName: "Business"),
        ]
    }

    private func project(
        _ aggregate: MidasProviderPresentation,
        accounts: [MidasAccountPresentation],
        id: String?)
        -> MidasProviderPresentation
    {
        MidasMenuBarAccountSelection.project(
            providerPresentation: aggregate,
            accounts: accounts,
            selectedAccountID: id,
            hidePersonalInfo: false)
    }

    private func ring(_ item: MidasProviderPresentation) -> MidasMenuBarPresentation {
        .init(
            mode: .orbit,
            presentations: [item],
            focusProvider: .codex,
            refreshingProviders: [],
            hideSpend: false)
    }

    private func item(
        remaining: Double,
        amount: Double? = nil) -> MidasProviderPresentation
    {
        .make(
            provider: .codex,
            card: nil,
            snapshot: UsageSnapshot(
                primary: nil,
                secondary: RateWindow(
                    usedPercent: 100 - remaining,
                    windowMinutes: 10080,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: Date()),
            tokenSnapshot: amount.map {
                CostUsageTokenSnapshot(
                    sessionTokens: nil,
                    sessionCostUSD: nil,
                    last30DaysTokens: nil,
                    last30DaysCostUSD: $0,
                    costProvenance: .listPriceEstimate,
                    daily: [],
                    updatedAt: Date())
            },
            isRefreshing: false,
            isStale: false)
    }
}
