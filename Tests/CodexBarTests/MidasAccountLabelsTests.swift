import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MidasAccountLabelsTests {
    @Test func labelsPersistPerProviderAndResetWithoutChangingConnections() throws {
        let suite = "MidasAccountLabels-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = self.settings(defaults: defaults, suite: suite)
        let id = UUID()
        settings.addTokenAccount(provider: .claude, label: "Personal", token: "fixture-token")
        let connections = settings.tokenAccounts(for: .claude)
        settings.setMidasAccountLabel("Personal account", for: .codex, accountID: id.uuidString)
        settings.setMidasAccountLabel("Work account", for: .claude, accountID: id.uuidString)
        let restored = self.settings(defaults: defaults, suite: suite)
        #expect(restored.midasAccountLabel(for: .codex, accountID: id.uuidString) == "Personal account")
        #expect(restored.midasAccountLabel(for: .claude, accountID: id.uuidString) == "Work account")
        settings.setMidasAccountLabel("  \n ", for: .codex, accountID: id.uuidString)
        #expect(settings.midasAccountAliases["codex:" + id.uuidString] == nil)
        #expect(settings.midasAccountLabel(for: .claude, accountID: id.uuidString) == "Work account")
        #expect(settings.tokenAccounts(for: .claude).map(\.id) == connections.map(\.id))
        #expect(settings.tokenAccounts(for: .claude).map(\.token) == connections.map(\.token))
    }

    @Test func editingSupportsSpacesAndLimitsWholeCharacters() throws {
        let suite = "MidasAccountLabels-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = self.settings(defaults: defaults, suite: suite)
        settings.setMidasAccountLabel("Business ", for: .codex, accountID: "one")
        #expect(settings.midasAccountLabel(for: .codex, accountID: "one") == "Business ")
        settings.setMidasAccountLabel(String(repeating: "👩🏽‍💻", count: 45), for: .codex, accountID: "one")
        #expect(settings.midasAccountLabel(for: .codex, accountID: "one").count == 40)
    }

    @Test func explicitDuplicateLabelsRemainAsEnteredWhileAutomaticNamesDisambiguate() {
        let identities = [(id: "one", identity: "alex@one.example"), (id: "two", identity: "alex@two.example")]
        let custom = MidasAccountNames.resolve(
            identities: identities,
            provider: .codex,
            aliases: ["codex:one": "Personal", "codex:two": "Personal"])
        #expect(custom == ["one": "Personal", "two": "Personal"])
        let mixed = MidasAccountNames.resolve(
            identities: identities, provider: .codex, aliases: ["codex:one": "alex"])
        #expect(mixed == ["one": "alex", "two": "alex@two.example"])
    }

    @Test func savedAccountEditorKeepsIdentityAndOriginalNicknameSeparate() throws {
        let suite = "MidasAccountLabels-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = self.settings(defaults: defaults, suite: suite)
        settings.addTokenAccount(
            provider: .claude, label: "Personal", token: "fixture-token", externalIdentifier: "alex@example.com")
        let option = try #require(settings.midasAccountLabelOptions(for: .claude).first)
        #expect(option.identity == "alex@example.com")
        #expect(option.defaultLabel == "Personal")
        settings.setMidasAccountLabel("Research", for: .claude, accountID: option.id)
        #expect(settings.midasAccountLabelOptions(for: .claude).first?.defaultLabel == "Personal")
        #expect(settings.selectedTokenAccount(for: .claude)?.label == "Personal")
    }

    private func settings(defaults: UserDefaults, suite: String) -> SettingsStore {
        SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite, reset: false),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
    }
}
