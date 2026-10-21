import CodexBarCore
import Testing
@testable import CodexBar

struct MidasMenuBarAccountLabelTests {
    @Test func aliasRetainsAccountIdentityAndPrivacyHidesIt() {
        let account = self.account(name: "Business", identity: "work@example.com")
        #expect(MidasMenuBarAccountLabel.title(account) == "Business (work@example.com)")
        let hidden = self.account(name: "Account 2", identity: "work@example.com")
        #expect(MidasMenuBarAccountLabel.title(hidden, hidePersonalInfo: true) == "Account 2")
    }

    @Test func identicalNameIsNotRepeatedAndMissingNamesStayReadable() {
        #expect(MidasMenuBarAccountLabel.title(self.account(name: "work@example.com", identity: "work@example.com"))
            == "work@example.com")
        #expect(MidasMenuBarAccountLabel.title(self.account(name: nil, identity: "")) == "Account")
    }

    private func account(name: String?, identity: String) -> MidasAccountPresentation {
        let presentation = MidasProviderPresentation(
            provider: .codex,
            name: "Codex",
            account: identity,
            plan: nil,
            hero: nil,
            metrics: [],
            resetCreditsText: nil,
            resetCreditsHelp: nil,
            freshness: "",
            error: nil,
            placeholder: nil,
            notes: [],
            financialSummary: nil,
            financialLabel: nil,
            isRefreshing: false,
            isStale: false,
            updatedAt: nil)
        return MidasAccountPresentation(id: "fixture", isPrimary: false, presentation: presentation, displayName: name)
    }
}
