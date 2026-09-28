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

    @Test func cachedAccountUsageBecomesStaleAfterMissingTwoScheduledRefreshes() {
        let now = Date(timeIntervalSince1970: 10000)
        let cases: [(interval: TimeInterval?, age: TimeInterval, expected: Bool)] = [
            (300, 0, false), (300, 900, false), (300, 901, true), // short cadences keep the 15-minute floor
            (900, 1800, false), (900, 1801, true),
            (1800, 1800, false), (1800, 3600, false), (1800, 3601, true), // 30m is not stale mid-cycle
            (nil, 86400, false), // manual refresh has no schedule to miss
        ]
        for item in cases {
            let snapshot = UsageSnapshot(primary: nil, secondary: nil, updatedAt: now.addingTimeInterval(-item.age))
            #expect(MidasCodexAccountPolicy.isStale(
                snapshot: snapshot, error: nil, refreshInterval: item.interval, now: now) == item.expected)
        }
        for interval in [TimeInterval?.none, 300] {
            #expect(MidasCodexAccountPolicy.isStale(
                snapshot: nil, error: "Refresh failed", refreshInterval: interval, now: now))
            #expect(!MidasCodexAccountPolicy.isStale(snapshot: nil, error: nil, refreshInterval: interval, now: now))
        }
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

    @Test func sameManagedAccountCannotReuseUsageFromAConflictingWorkspace() {
        let accountID = UUID()
        func account(workspace: String) -> CodexVisibleAccount {
            CodexVisibleAccount(
                id: "managed@example.com",
                email: "managed@example.com",
                workspaceAccountID: workspace,
                authFingerprint: "same-fingerprint",
                storedAccountID: accountID,
                selectionSource: .managedAccount(id: accountID),
                isActive: false,
                isLive: false,
                canReauthenticate: true,
                canRemove: true)
        }
        let cached = account(workspace: "old-workspace")
        let visible = account(workspace: "new-workspace")
        let entry = CodexAccountUsageSnapshot(
            account: cached,
            snapshot: self.snapshot(cached),
            error: nil,
            sourceLabel: "oauth")
        #expect(!MidasCodexAccountPolicy.entryBelongs(to: visible, entry: entry))
        #expect(MidasCodexAccountPolicy.snapshot(for: visible, in: [entry.id: entry]) == nil)
        let usage = MidasCodexAccountPolicy.usage(
            for: visible,
            entry: entry,
            providerSnapshot: nil,
            providerError: nil,
            refreshGuard: nil)
        #expect(usage.snapshot == nil)
    }

    @Test func managedAccountEntryBindsWhenCachedWorkspaceIsMissingOnTheVisibleAccount() {
        let accountID = UUID()
        let cached = CodexVisibleAccount(
            id: "cached@example.com",
            email: "cached@example.com",
            workspaceAccountID: "acct-cached",
            authFingerprint: "same-fingerprint",
            storedAccountID: accountID,
            selectionSource: .managedAccount(id: accountID),
            isActive: false,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
        let visible = CodexVisibleAccount(
            id: "cached@example.com",
            email: "cached@example.com",
            workspaceAccountID: nil,
            authFingerprint: "same-fingerprint",
            storedAccountID: accountID,
            selectionSource: .managedAccount(id: accountID),
            isActive: false,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
        let entry = CodexAccountUsageSnapshot(
            account: cached,
            snapshot: self.snapshot(cached),
            error: nil,
            sourceLabel: "oauth")
        let usage = MidasCodexAccountPolicy.usage(
            for: visible,
            entry: entry,
            providerSnapshot: nil,
            providerError: nil,
            refreshGuard: nil)
        #expect(usage.snapshot?.primary?.usedPercent == 25)
        #expect(usage.error == nil)
        #expect(MidasCodexAccountPolicy.snapshot(for: visible, in: [entry.id: entry])?.id == entry.id)
    }
}
