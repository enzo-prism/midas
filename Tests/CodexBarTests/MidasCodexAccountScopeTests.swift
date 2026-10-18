import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct MidasCodexAccountScopeTests {
    @Test func scopeSelectsMatchingAccountAndLeavesOriginalUnchanged() {
        let first = Self.account("first@example.com")
        let second = Self.account("second@example.com")
        let original = Self.snapshot(accounts: [first, second], active: second)
        let filtered = MidasCodexAccountScope.applying(email: " FIRST@EXAMPLE.COM ", to: original)
        #expect(filtered.storedAccounts.map(\.id) == [first.id])
        #expect(filtered.activeSource == .managedAccount(id: first.id))
        #expect(filtered.activeStoredAccount?.id == first.id)
        #expect(original.storedAccounts.count == 2)
        #expect(MidasCodexAccountScope.applying(email: nil, to: original) == original)
    }

    @Test func missingOrChangedRuntimeIdentityFailsClosed() {
        let first = Self.account("first@example.com")
        let original = Self.snapshot(accounts: [first], active: first, runtimeEmail: "second@example.com")
        let filtered = MidasCodexAccountScope.applying(email: "first@example.com", to: original)
        #expect(filtered.storedAccounts.isEmpty)
        #expect(filtered.liveSystemAccount == nil)
        #expect(filtered.activeStoredAccount == nil)
        #expect(filtered.activeSource != .liveSystem)
        let settings = CodexProviderSettingsBuilder.make(input: .init(
            usageDataSource: .auto,
            cookieSource: .off,
            manualCookieHeader: nil,
            reconciliationSnapshot: filtered,
            resolvedActiveSource: CodexActiveSourceResolver.resolve(from: filtered)))
        #expect(settings.managedAccountTargetUnavailable)
    }

    private static func account(_ email: String) -> ManagedCodexAccount {
        ManagedCodexAccount(
            id: UUID(),
            email: email,
            managedHomePath: "/synthetic/\(email)",
            createdAt: 0,
            updatedAt: 0,
            lastAuthenticatedAt: nil)
    }

    private static func snapshot(
        accounts: [ManagedCodexAccount],
        active: ManagedCodexAccount,
        runtimeEmail: String? = nil) -> CodexAccountReconciliationSnapshot
    {
        CodexAccountReconciliationSnapshot(
            storedAccounts: accounts,
            activeStoredAccount: active,
            liveSystemAccount: nil,
            matchingStoredAccountForLiveSystemAccount: nil,
            activeSource: .managedAccount(id: active.id),
            hasUnreadableAddedAccountStore: false,
            storedAccountRuntimeEmails: runtimeEmail.map { [active.id: $0] } ?? [:])
    }
}
