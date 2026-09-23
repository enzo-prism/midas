#if os(macOS)
import Foundation
import Security
import Testing
@testable import CodexBarCore

@Suite
struct KeychainCacheLegacyAdoptionTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "KeychainCacheLegacyAdoptionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test
    func `reads the inherited CodexBar cache service and returns its data`() {
        let defaults = self.makeDefaults()
        var requested: [(String, String)] = []
        let data = KeychainCacheStore
            .adoptLegacyItem(account: "cookie.cursor", defaults: defaults) { service, account in
                requested.append((service, account))
                return (errSecSuccess, Data("legacy".utf8))
            }
        #expect(data == Data("legacy".utf8))
        #expect(requested.count == 1)
        #expect(requested.first?.0 == "com.steipete.codexbar.cache")
        #expect(requested.first?.1 == "cookie.cursor")
    }

    @Test
    func `attempts each account only once so a denied prompt never repeats`() {
        let defaults = self.makeDefaults()
        var reads = 0
        let deny: (String, String) -> (status: OSStatus, data: Data?) = { _, _ in
            reads += 1
            return (errSecAuthFailed, nil)
        }
        #expect(KeychainCacheStore
            .adoptLegacyItem(account: "cookie.cursor", defaults: defaults, readLegacy: deny) == nil)
        #expect(KeychainCacheStore
            .adoptLegacyItem(account: "cookie.cursor", defaults: defaults, readLegacy: deny) == nil)
        #expect(reads == 1)

        _ = KeychainCacheStore.adoptLegacyItem(account: "cookie.codex", defaults: defaults, readLegacy: deny)
        #expect(reads == 2)
    }

    @Test
    func `retries when the keychain is temporarily locked`() {
        let defaults = self.makeDefaults()
        var reads = 0
        let locked: (String, String) -> (status: OSStatus, data: Data?) = { _, _ in
            reads += 1
            return (errSecInteractionNotAllowed, nil)
        }
        _ = KeychainCacheStore.adoptLegacyItem(account: "cookie.cursor", defaults: defaults, readLegacy: locked)
        let data = KeychainCacheStore.adoptLegacyItem(account: "cookie.cursor", defaults: defaults) { _, _ in
            reads += 1
            return (errSecSuccess, Data("legacy".utf8))
        }
        #expect(reads == 2)
        #expect(data == Data("legacy".utf8))
    }

    @Test
    func `missing legacy item is recorded and not read again`() {
        let defaults = self.makeDefaults()
        var reads = 0
        let missing: (String, String) -> (status: OSStatus, data: Data?) = { _, _ in
            reads += 1
            return (errSecItemNotFound, nil)
        }
        #expect(KeychainCacheStore
            .adoptLegacyItem(account: "cookie.grok", defaults: defaults, readLegacy: missing) == nil)
        #expect(KeychainCacheStore
            .adoptLegacyItem(account: "cookie.grok", defaults: defaults, readLegacy: missing) == nil)
        #expect(reads == 1)
    }
}
#endif
