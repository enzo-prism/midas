import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexAccountProviderIdentityReconciliationTests {
    @Test
    func `same provider account id with different email does not merge live and managed rows`() {
        let stored = ManagedCodexAccount(
            id: UUID(),
            email: "mi.chaelfmk5542@gmail.com",
            providerAccountID: "team-4107",
            workspaceLabel: "4107",
            workspaceAccountID: "team-4107",
            managedHomePath: "/tmp/managed-a",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let live = ObservedSystemCodexAccount(
            email: "mich.aelfmk5542@gmail.com",
            workspaceLabel: "4107",
            workspaceAccountID: "team-4107",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "team-4107"))
        let snapshot = CodexAccountReconciliationSnapshot(
            storedAccounts: [stored],
            activeStoredAccount: stored,
            liveSystemAccount: live,
            matchingStoredAccountForLiveSystemAccount: nil,
            activeSource: .managedAccount(id: stored.id),
            hasUnreadableAddedAccountStore: false,
            storedAccountRuntimeIdentities: [stored.id: .providerAccount(id: "team-4107")],
            storedAccountRuntimeEmails: [stored.id: "mi.chaelfmk5542@gmail.com"])

        let resolution = CodexActiveSourceResolver.resolve(from: snapshot)
        let projection = CodexVisibleAccountProjection.make(from: snapshot)

        #expect(resolution.resolvedSource == .managedAccount(id: stored.id))
        #expect(projection.visibleAccounts.count == 2)
        #expect(projection.visibleAccounts.map(\.email).sorted() == [
            "mi.chaelfmk5542@gmail.com",
            "mich.aelfmk5542@gmail.com",
        ])
        #expect(projection.activeVisibleAccountID == "mi.chaelfmk5542@gmail.com")
        #expect(projection.liveVisibleAccountID == "mich.aelfmk5542@gmail.com")
    }

    @Test
    func `all account mode keeps dedicated credentials for the live account`() {
        let stored = ManagedCodexAccount(
            id: UUID(),
            email: "mi.chaelfmk5542@gmail.com",
            providerAccountID: "team-4107",
            workspaceLabel: "4107",
            workspaceAccountID: "team-4107",
            managedHomePath: "/tmp/managed-a",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let live = ObservedSystemCodexAccount(
            email: "mi.chaelfmk5542@gmail.com",
            workspaceLabel: "4107",
            workspaceAccountID: "team-4107",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "team-4107"))
        let snapshot = CodexAccountReconciliationSnapshot(
            storedAccounts: [stored],
            activeStoredAccount: stored,
            liveSystemAccount: live,
            matchingStoredAccountForLiveSystemAccount: stored,
            activeSource: .managedAccount(id: stored.id),
            hasUnreadableAddedAccountStore: false,
            storedAccountRuntimeIdentities: [stored.id: .providerAccount(id: "team-4107")],
            storedAccountRuntimeEmails: [stored.id: "mi.chaelfmk5542@gmail.com"])

        let projection = CodexVisibleAccountProjection.make(from: snapshot, preferManagedAccounts: true)

        #expect(CodexActiveSourceResolver.resolve(
            from: snapshot, preferManagedAccounts: true).resolvedSource == .managedAccount(id: stored.id))
        #expect(projection.visibleAccounts.count == 1)
        #expect(projection.visibleAccounts.first?.selectionSource == .managedAccount(id: stored.id))
        #expect(projection.visibleAccounts.first?.isActive == true)
        #expect(projection.visibleAccounts.first?.isLive == true)
    }
}
