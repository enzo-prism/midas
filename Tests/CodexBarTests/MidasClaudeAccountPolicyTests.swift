import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MidasClaudeAccountPolicyTests {
    private func account(
        id: UUID = UUID(),
        token: String = "sessionKey=fake",
        label: String = "Personal",
        email: String? = "personal@example.com",
        organization: String? = nil) -> ProviderTokenAccount
    {
        ProviderTokenAccount(
            id: id,
            label: label,
            token: token,
            addedAt: 0,
            lastUsed: nil,
            externalIdentifier: email,
            organizationID: organization)
    }

    private func usage(_ email: String?) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: "Pro"))
    }

    @Test func reconnectCannotReuseOldCredentialReading() {
        let original = self.account()
        let reconnected = self.account(id: original.id, token: "sessionKey=reconnected")
        let entry = TokenAccountUsageSnapshot(
            account: original,
            snapshot: self.usage("personal@example.com"),
            error: nil,
            sourceLabel: "web")
        #expect(!MidasTokenAccountPolicy.entryBelongs(to: reconnected, entry: entry))
        #expect(MidasTokenAccountPolicy.entryBelongs(to: original, entry: entry))
    }

    @Test func organizationChangeInvalidatesReadingButNicknameDoesNot() {
        let original = self.account(organization: "org-one")
        let renamed = self.account(id: original.id, label: "Home", organization: "org-one")
        let moved = self.account(id: original.id, organization: "org-two")
        #expect(MidasTokenAccountPolicy.sameConnection(original, renamed))
        #expect(!MidasTokenAccountPolicy.sameConnection(original, moved))
    }

    @Test func verifiedEmailCannotBeRelabeledAsAnotherAccount() {
        let personal = self.account()
        #expect(!MidasTokenAccountPolicy.identityMatches(self.usage("business@example.com"), account: personal))
        #expect(MidasTokenAccountPolicy.identityMatches(self.usage(" Personal@Example.COM "), account: personal))
    }

    @Test func manualEmailLabelAlsoGuardsIdentity() {
        let personal = self.account(label: "personal@example.com", email: nil)
        #expect(!MidasTokenAccountPolicy.identityMatches(self.usage("business@example.com"), account: personal))
        #expect(MidasTokenAccountPolicy.identityMatches(self.usage(nil), account: personal))
    }

    @Test func everyStoredClaudeAccountUsesIsolatedRefreshEvenWithoutTrackAll() {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.midasTrackAllAccounts = false
        store.settings.multiAccountMenuLayout = .segmented
        #expect(!store.shouldFetchAllTokenAccounts(provider: .claude, accounts: []))
        #expect(store.shouldFetchAllTokenAccounts(provider: .claude, accounts: [self.account()]))
        #expect(store.shouldFetchAllTokenAccounts(provider: .claude, accounts: [self.account(), self.account()]))
        #expect(!store.shouldFetchAllTokenAccounts(provider: .cursor, accounts: [self.account(), self.account()]))
    }

    @Test func distinctAccountsAreNeverTheSameConnection() {
        #expect(!MidasTokenAccountPolicy.sameConnection(self.account(), self.account()))
    }
}
