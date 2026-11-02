import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ProviderToggleStoreTests {
    @Test
    func `defaults match metadata`() throws {
        let defaults = try #require(TestUserDefaults.suite("ProviderToggleStoreTests-defaults"))
        defaults.removePersistentDomain(forName: TestUserDefaults.domain("ProviderToggleStoreTests-defaults"))
        let store = ProviderToggleStore(userDefaults: defaults)
        let registry = ProviderRegistry.shared
        let codexMeta = try #require(registry.metadata[.codex])
        let claudeMeta = try #require(registry.metadata[.claude])

        #expect(store.isEnabled(metadata: codexMeta))
        #expect(!store.isEnabled(metadata: claudeMeta))
    }

    @Test
    func `persists changes`() throws {
        let suite = "ProviderToggleStoreTests-persist"
        let defaultsA = try #require(TestUserDefaults.suite(suite))
        defaultsA.removePersistentDomain(forName: TestUserDefaults.domain(suite))
        let storeA = ProviderToggleStore(userDefaults: defaultsA)
        let registry = ProviderRegistry.shared
        let claudeMeta = try #require(registry.metadata[.claude])

        storeA.setEnabled(true, metadata: claudeMeta)

        let defaultsB = try #require(TestUserDefaults.suite(suite))
        let storeB = ProviderToggleStore(userDefaults: defaultsB)
        #expect(storeB.isEnabled(metadata: claudeMeta))
    }

    @Test
    func `purges legacy keys`() throws {
        let suite = "ProviderToggleStoreTests-purge"
        let defaults = try #require(TestUserDefaults.suite(suite))
        defaults.removePersistentDomain(forName: TestUserDefaults.domain(suite))
        defaults.set(false, forKey: "showCodexUsage")
        defaults.set(true, forKey: "showClaudeUsage")

        let store = ProviderToggleStore(userDefaults: defaults)
        store.purgeLegacyKeys()

        #expect(defaults.object(forKey: "showCodexUsage") == nil)
        #expect(defaults.object(forKey: "showClaudeUsage") == nil)
    }
}
