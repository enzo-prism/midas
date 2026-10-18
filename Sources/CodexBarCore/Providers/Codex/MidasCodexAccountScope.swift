import Foundation

/// An optional local display scope. Credentials remain in their original account stores.
public enum MidasCodexAccountScope {
    private static let unavailableSource = CodexActiveSource.managedAccount(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)

    public static func applying(
        email: String?, to snapshot: CodexAccountReconciliationSnapshot) -> CodexAccountReconciliationSnapshot
    {
        guard let email = CodexIdentityResolver.normalizeEmail(email) else { return snapshot }
        let accounts = snapshot.storedAccounts.filter {
            CodexIdentityResolver.normalizeEmail(snapshot.runtimeEmail(for: $0)) == email
        }
        let live = snapshot.liveSystemAccount.flatMap {
            CodexIdentityResolver.normalizeEmail($0.email) == email ? $0 : nil
        }
        let active = accounts.first { .managedAccount(id: $0.id) == snapshot.activeSource } ?? accounts.first
        // Prefer an isolated managed home. An unavailable filter must never fall back to ambient auth.
        let source = active.map { CodexActiveSource.managedAccount(id: $0.id) }
            ?? (live == nil ? self.unavailableSource : .liveSystem)
        let ids = Set(accounts.map(\.id))
        return CodexAccountReconciliationSnapshot(
            storedAccounts: accounts,
            activeStoredAccount: active,
            liveSystemAccount: live,
            matchingStoredAccountForLiveSystemAccount: snapshot.matchingStoredAccountForLiveSystemAccount.flatMap {
                live != nil && ids.contains($0.id) ? $0 : nil
            },
            activeSource: source,
            hasUnreadableAddedAccountStore: snapshot.hasUnreadableAddedAccountStore,
            storedAccountRuntimeIdentities: snapshot.storedAccountRuntimeIdentities.filter { ids.contains($0.key) },
            storedAccountRuntimeEmails: snapshot.storedAccountRuntimeEmails.filter { ids.contains($0.key) })
    }
}
