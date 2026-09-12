import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MidasCalibrationScopeTests {
    private func account(email: String, workspace: String? = nil) -> CodexVisibleAccount {
        CodexVisibleAccount(
            id: UUID().uuidString,
            email: email,
            workspaceAccountID: workspace,
            storedAccountID: UUID(),
            selectionSource: .liveSystem,
            isActive: false,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
    }

    @Test func independentLoginsAndAccountOrderHaveSameScope() {
        let first = [self.account(email: "one@example.com"), self.account(email: "two@example.com")]
        let second = [self.account(email: "TWO@example.com"), self.account(email: " one@example.com ")]
        #expect(UsageStore.calibrationPortableScope(accounts: first) == UsageStore
            .calibrationPortableScope(accounts: second))
        #expect(UsageStore.calibrationPortableScope(accounts: first)?.count == 64)
    }

    @Test func accountAndWorkspaceChangesAreIsolated() {
        let first = UsageStore.calibrationPortableScope(accounts: [self.account(email: "one@example.com")])
        #expect(first != UsageStore.calibrationPortableScope(accounts: [self.account(email: "two@example.com")]))
        #expect(first != UsageStore.calibrationPortableScope(accounts: [self.account(
            email: "one@example.com",
            workspace: "workspace-two")]))
        #expect(UsageStore.calibrationPortableScope(accounts: []) == nil)
        #expect(UsageStore.calibrationPortableScope(accounts: [self.account(email: "unknown")]) == nil)
    }
}
