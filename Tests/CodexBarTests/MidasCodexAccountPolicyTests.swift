import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MidasCodexAccountPolicyTests {
    private func account(_ id: String, active: Bool, workspace: String? = nil) -> CodexVisibleAccount {
        CodexVisibleAccount(
            id: id,
            email: "\(id)@example.com",
            workspaceAccountID: workspace,
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: active,
            isLive: true,
            canReauthenticate: false,
            canRemove: false)
    }

    private func scope(_ account: CodexVisibleAccount) -> CodexAccountScopedRefreshGuard {
        CodexAccountScopedRefreshGuard(
            source: account.selectionSource,
            identity: account.workspaceAccountID.map { .providerAccount(id: $0) }
                ?? CodexIdentityResolver.resolve(accountId: nil, email: account.email),
            accountKey: account.email)
    }

    private func snapshot(_ account: CodexVisibleAccount) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: account.email,
                accountOrganization: nil,
                loginMethod: nil))
    }

    @Test func selectedOnlyUsesProviderSnapshotForSingleOrMultipleAccounts() {
        let selected = self.account("selected", active: true)
        let other = self.account("other", active: false)
        for accounts in [[selected], [other, selected]] {
            let visible = MidasCodexAccountPolicy.visibleAccounts(accounts, trackAll: false, stacked: false)
            #expect(visible.map(\.id) == [selected.id])
            let usage = MidasCodexAccountPolicy.usage(
                for: selected,
                entry: nil,
                providerSnapshot: self.snapshot(selected),
                providerError: nil,
                refreshGuard: self.scope(selected))
            #expect(usage.snapshot?.primary?.usedPercent == 25)
            #expect(usage.error == nil)
        }
    }

    @Test func trackingAndStackedExposeBothAccountsButNeverBorrowActiveUsageForOtherAccount() {
        let selected = self.account("selected", active: true)
        let other = self.account("other", active: false)
        for (trackAll, stacked) in [(true, false), (false, true)] {
            let visible = MidasCodexAccountPolicy.visibleAccounts(
                [other, selected],
                trackAll: trackAll,
                stacked: stacked)
            #expect(visible.map(\.id) == [selected.id, other.id])
            let usage = MidasCodexAccountPolicy.usage(
                for: other,
                entry: nil,
                providerSnapshot: self.snapshot(selected),
                providerError: "Failure",
                refreshGuard: self.scope(selected))
            #expect(usage.snapshot == nil)
            #expect(usage.error == nil)
        }
    }

    @Test func switchedAccountAndWrongSnapshotIdentityCannotLeakIntoSelectedRow() {
        let selected = self.account("selected", active: true)
        let old = self.account("old", active: true)
        for (snapshot, scope) in [(self.snapshot(old), self.scope(old)), (self.snapshot(old), self.scope(selected))] {
            let usage = MidasCodexAccountPolicy.usage(
                for: selected,
                entry: nil,
                providerSnapshot: snapshot,
                providerError: "Old error",
                refreshGuard: scope)
            #expect(usage.snapshot == nil)
            #expect(usage.error == nil)
        }
        #expect(!MidasCodexAccountPolicy.canUseProviderSnapshot(for: selected, refreshGuard: nil))
        let workspace = self.account("selected", active: true, workspace: "different-workspace")
        #expect(!MidasCodexAccountPolicy.canUseProviderSnapshot(for: workspace, refreshGuard: self.scope(selected)))
    }

    @Test func obsoleteEntryCannotSupplyAnotherIdentityAfterAccountReplacement() {
        let selected = self.account("selected", active: true)
        let obsolete = self.account("selected", active: true, workspace: "old-workspace")
        let entry = CodexAccountUsageSnapshot(
            account: obsolete,
            snapshot: self.snapshot(obsolete),
            error: "Old error",
            sourceLabel: nil)
        let usage = MidasCodexAccountPolicy.usage(
            for: selected,
            entry: entry,
            providerSnapshot: nil,
            providerError: nil,
            refreshGuard: nil)
        #expect(usage.snapshot == nil)
        #expect(usage.error == nil)
    }

    @Test func accountEntryKeepsItsOwnErrorAndUsage() {
        let account = self.account("other", active: false)
        let entry = CodexAccountUsageSnapshot(
            account: account,
            snapshot: self.snapshot(account),
            error: "Refresh failed",
            sourceLabel: nil)
        let usage = MidasCodexAccountPolicy.usage(
            for: account,
            entry: entry,
            providerSnapshot: nil,
            providerError: nil,
            refreshGuard: nil)
        #expect(usage.snapshot?.primary?.usedPercent == 25)
        #expect(usage.error == "Refresh failed")
    }

    @Test func missingSnapshotIsWaitingOrRefreshingInsteadOfFailure() {
        for refreshing in [false, true] {
            let presentation = MidasProviderPresentation.make(
                provider: .codex,
                card: nil,
                snapshot: nil,
                tokenSnapshot: nil,
                isRefreshing: refreshing,
                isStale: false)
            #expect(MidasCodexAccountPolicy.emptyUsageText(presentation)
                == (refreshing ? "Refreshing…" : "Waiting for first update"))
        }
    }
}
