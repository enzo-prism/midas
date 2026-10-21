import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct MidasMenuBarAccountRefreshTests {
    @Test func pinnedTokenAccountRefreshesWithoutTrackingAllOrChangingActiveAccount() throws {
        let (settings, defaults, suite, store) = try self.makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = self.tokenAccounts()
        #expect(!store.shouldFetchAllTokenAccounts(provider: .openai, accounts: accounts))
        settings.setMidasMenuBarAccountID(accounts[7].id.uuidString, for: .openai)
        #expect(store.shouldFetchAllTokenAccounts(provider: .openai, accounts: accounts))
        #expect(!settings.midasTrackAllAccounts)
        #expect(settings.multiAccountMenuLayout == .segmented)
        #expect(settings.selectedTokenAccount(for: .openai) == nil)
        settings.setMidasMenuBarAccountID(nil, for: .openai)
        #expect(!store.shouldFetchAllTokenAccounts(provider: .openai, accounts: accounts))
    }

    @Test func survivingPinnedTokenAccountKeepsRefreshing() throws {
        let (settings, defaults, suite, store) = try self.makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = self.tokenAccounts()[0]
        #expect(!store.shouldFetchAllTokenAccounts(provider: .openai, accounts: [account]))
        settings.setMidasMenuBarAccountID(account.id.uuidString, for: .openai)
        #expect(store.shouldFetchAllTokenAccounts(provider: .openai, accounts: [account]))
        #expect(!store.shouldFetchAllTokenAccounts(provider: .openai, accounts: []))
        #expect(store.limitedTokenAccounts([account], selected: account, provider: .openai).count == 1)
    }

    @Test func survivingPinnedCodexAccountKeepsRefreshing() throws {
        let (settings, defaults, suite, store) = try self.makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!store.shouldFetchCodexAccountSnapshots(accountCount: 1))
        settings.setMidasMenuBarAccountID("managed:fixture", for: .codex)
        #expect(store.shouldFetchCodexAccountSnapshots(accountCount: 1))
        #expect(!store.shouldFetchCodexAccountSnapshots(accountCount: 0))
        settings.setMidasMenuBarAccountID(nil, for: .codex)
        #expect(!store.shouldFetchCodexAccountSnapshots(accountCount: 1))
        settings.midasCodexAccountEmailFilter = "fixture@example.com"
        #expect(store.shouldFetchCodexAccountSnapshots(accountCount: 1))
    }

    @Test func refreshLimitKeepsBothActiveAndPinnedTokenAccounts() throws {
        let (settings, defaults, suite, store) = try self.makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = self.tokenAccounts()
        settings.setMidasMenuBarAccountID(accounts[7].id.uuidString, for: .openai)
        let limited = store.limitedTokenAccounts(accounts, selected: accounts[6], provider: .openai)
        #expect(limited.count == UsageStore.tokenAccountMenuSnapshotLimit)
        #expect(limited.contains { $0.id == accounts[6].id })
        #expect(limited.contains { $0.id == accounts[7].id })
        #expect(Set(limited.map(\.id)).count == limited.count)
    }

    @Test func refreshLimitKeepsBothActiveAndPinnedCodexAccounts() throws {
        let (settings, defaults, suite, store) = try self.makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = (0..<8).map { index in
            CodexVisibleAccount(
                id: "fixture-\(index)",
                email: "account\(index)@example.com",
                storedAccountID: nil,
                selectionSource: .liveSystem,
                isActive: index == 6,
                isLive: index == 6,
                canReauthenticate: false,
                canRemove: false)
        }
        settings.setMidasMenuBarAccountID(accounts[7].id, for: .codex)
        let limited = store.limitedCodexVisibleAccounts(accounts, activeVisibleAccountID: accounts[6].id)
        #expect(limited.count == UsageStore.tokenAccountMenuSnapshotLimit)
        #expect(limited.contains { $0.id == accounts[6].id })
        #expect(limited.contains { $0.id == accounts[7].id })
        #expect(Set(limited.map(\.id)).count == limited.count)
        #expect(settings.codexActiveSource == .liveSystem)
    }

    private func tokenAccounts() -> [ProviderTokenAccount] {
        (0..<8).map { index in
            ProviderTokenAccount(
                id: UUID(), label: "Fixture \(index)", token: "fixture-\(index)", addedAt: 0, lastUsed: nil)
        }
    }

    private func makeStore() throws -> (SettingsStore, UserDefaults, String, UsageStore) {
        let suite = "MidasMenuBarAccountRefreshTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite, reset: false),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.multiAccountMenuLayout = .segmented
        settings.midasTrackAllAccounts = false
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        return (settings, defaults, suite, store)
    }
}
