import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ClaudeAccountSignInModelTests {
    @Test
    func `session cookie requires exact Claude domain and secure transport`() {
        #expect(ClaudeAccountSignInModel.sessionHeader(from: [Self.cookie(domain: ".claude.ai")]) != nil)
        #expect(ClaudeAccountSignInModel.sessionHeader(from: [Self.cookie(domain: "evilclaude.ai")]) == nil)
        #expect(ClaudeAccountSignInModel.sessionHeader(from: [Self.cookie(domain: "claude.ai.evil.test")]) == nil)
        #expect(ClaudeAccountSignInModel.sessionHeader(from: [Self.cookie(domain: "claude.ai", secure: false)]) == nil)
    }

    @Test
    func `ambiguous and expired session cookies are rejected`() {
        #expect(ClaudeAccountSignInModel.sessionHeader(from: [
            Self.cookie(domain: "claude.ai", value: "test-session-one"),
            Self.cookie(domain: ".claude.ai", value: "test-session-two"),
        ]) == nil)
        #expect(ClaudeAccountSignInModel.sessionHeader(from: [
            Self.cookie(domain: "claude.ai", expires: Date(timeIntervalSince1970: 1)),
        ]) == nil)
    }

    @Test
    func `verified identity comes from verifier rather than nickname`() async {
        let model = ClaudeAccountSignInModel(verifyIdentity: { _ in "  fixture@example.com  " })
        model.nickname = "Business"
        await model.verify(cookieHeader: "sessionKey=test-session")
        #expect(model.verifiedEmail == "fixture@example.com")
        #expect(model.nickname == "Business")
        #expect(!model.isVerifying)
        model.clearVerification()
        #expect(model.verifiedEmail == nil)
    }

    @Test
    func `missing identity and failures cannot be saved`() async {
        let missing = ClaudeAccountSignInModel(verifyIdentity: { _ in nil })
        await missing.verify(cookieHeader: "sessionKey=test-session")
        #expect(missing.verifiedEmail == nil)
        #expect(missing.notice != nil)
        let failed = ClaudeAccountSignInModel(verifyIdentity: { _ in
            throw NSError(domain: "private-credential-fixture", code: 1)
        })
        await failed.verify(cookieHeader: "sessionKey=test-session")
        #expect(failed.verifiedEmail == nil)
        #expect(failed.notice?.contains("private-credential-fixture") == false)
    }

    @Test
    func `cancelled verification cannot restore cleared identity`() async {
        let model = ClaudeAccountSignInModel(verifyIdentity: { _ in
            try await Task.sleep(for: .milliseconds(20))
            return "fixture@example.com"
        })
        let task = Task { await model.verify(cookieHeader: "sessionKey=test-session") }
        await Task.yield()
        model.clearVerification()
        task.cancel()
        await task.value
        #expect(model.verifiedEmail == nil)
        #expect(!model.isVerifying)
    }

    @Test
    func `failed checked save retains verified session for retry without exposing error`() async {
        let model = ClaudeAccountSignInModel(verifyIdentity: { _ in "fixture@example.com" })
        model.nickname = "  Personal  "
        await model.verify(cookieHeader: "sessionKey=test-session")
        let failed = model.save { _, _, _ in
            throw NSError(domain: "private-save-fixture", code: 1)
        }
        #expect(!failed)
        #expect(model.verifiedEmail == "fixture@example.com")
        #expect(model.notice?.contains("private-save-fixture") == false)
        var saved = false
        let retried = model.save { label, token, email in
            #expect(label == "Personal")
            #expect(token == "sessionKey=test-session")
            #expect(email == "fixture@example.com")
            saved = true
        }
        #expect(retried)
        #expect(saved)
        #expect(model.verifiedEmail == nil)
        #expect(!model.save { _, _, _ in Issue.record("Cleared credential must not save again") })
    }

    @Test(arguments: [false, true])
    func `checked account save enables Claude and failed save restores disabled state`(blockWrite: Bool) async throws {
        let suite = "ClaudeAccountSignInModelTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let configStore = testConfigStore(suiteName: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: configStore.fileURL.deletingLastPathComponent())
        }
        try configStore.save(CodexBarConfig(providers: [ProviderConfig(id: .claude, enabled: false)]))
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        if blockWrite {
            try FileManager.default.removeItem(at: configStore.fileURL)
            try FileManager.default.createDirectory(at: configStore.fileURL, withIntermediateDirectories: false)
        }
        let model = ClaudeAccountSignInModel(verifyIdentity: { _ in "fixture@example.com" })
        await model.verify(cookieHeader: "sessionKey=test-session")
        #expect(model.save(to: settings) == !blockWrite)
        #expect(settings.configSnapshot.providerConfig(for: .claude)?.enabled == !blockWrite)
        if blockWrite {
            #expect(settings.tokenAccounts(for: .claude).isEmpty)
            #expect(model.verifiedEmail == "fixture@example.com")
            #expect(model.notice != nil)
        } else {
            let loadedConfig = try configStore.load()
            let persisted = try #require(loadedConfig)
            #expect(persisted.providerConfig(for: .claude)?.enabled == true)
            #expect(persisted.providerConfig(for: .claude)?.tokenAccounts?.accounts.first?
                .externalIdentifier == "fixture@example.com")
            #expect(model.verifiedEmail == nil)
        }
    }

    private static func cookie(
        domain: String,
        value: String = "test-session",
        secure: Bool = true,
        expires: Date? = nil) -> HTTPCookie
    {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: domain,
            .path: "/",
            .name: "sessionKey",
            .value: value,
        ]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }
}
