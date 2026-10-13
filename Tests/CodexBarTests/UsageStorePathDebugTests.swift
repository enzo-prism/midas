import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageStorePathDebugTests {
    @Test
    func `refresh path debug info populates snapshot`() async throws {
        let suite = "UsageStorePathDebugTests-path"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore())
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let snapshot = PathDebugSnapshot(
            codexBinary: "/fixture/bin/codex",
            claudeBinary: nil,
            effectivePATH: "/fixture/bin",
            loginShellPATH: nil)
        store._test_pathDebugSnapshotOverride = { snapshot }

        await store.refreshPathDebugInfo()

        #expect(store.pathDebugInfo == snapshot)
        #expect(store.timerTask == nil)
        #expect(store.tokenTimerTask == nil)
    }

    @Test
    func `automatic startup skips background work in tests`() throws {
        let suite = "UsageStorePathDebugTests-automatic-startup"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore())
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: [:])

        #expect(!store.startupBehavior.automaticallyStartsBackgroundWork)
        #expect(store.timerTask == nil)
        #expect(store.tokenTimerTask == nil)
        #expect(!settings.providerDetectionCompleted)
        #expect(!settings.costUsageEnabled)
    }

    @Test
    func `deepseek debug log includes selected token account`() async throws {
        let suite = "UsageStorePathDebugTests-deepseek-debug-token-account"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore())
        settings.addTokenAccount(provider: .deepseek, label: "Primary", token: "sk-deepseek-test")
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])

        let debugLog = await store.debugLog(for: UsageProvider.deepseek)

        #expect(debugLog == "DEEPSEEK_API_KEY=present source=settings-token-account")
    }

    @Test
    func `meta debug log reports key status and sessions root`() async throws {
        let suite = "UsageStorePathDebugTests-meta-debug-log"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore())
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])

        let debugLog = await store.debugLog(for: UsageProvider.meta)

        #expect(debugLog.contains("META_API_KEY="))
        #expect(debugLog.contains("sessionsRoot="))
        #expect(debugLog.contains("model="))
    }
}
