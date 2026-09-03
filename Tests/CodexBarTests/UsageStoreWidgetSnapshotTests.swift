import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageStoreWidgetSnapshotTests {
    @Test
    func `widget snapshot includes antigravity tertiary usage row`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-antigravity-tertiary"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 30, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .antigravity,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Pro"))

        store._setSnapshotForTesting(snapshot, provider: .antigravity)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "antigravity-tertiary-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .antigravity })
        #expect(entry.usageRows?.map(\.id) == ["primary", "secondary", "tertiary"])
        #expect(entry.usageRows?.map(\.title) == ["Claude", "Gemini Pro", "Gemini Flash"])
        #expect(entry.usageRows?.compactMap(\.percentLeft) == [90, 80, 70])
    }

    @Test
    func `widget snapshot persist skips when rendered content is unchanged`() async throws {
        let (store, _) = try Self.makeStore(suite: "UsageStoreWidgetSnapshotTests-dedup-skip")

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store._setSnapshotForTesting(Self.snapshot(provider: .antigravity, usedPercent: 10), provider: .antigravity)
        store.persistWidgetSnapshot(reason: "initial")
        await store.widgetSnapshotPersistTask?.value
        #expect(widgetSnapshots.count == 1)

        // Same data fetched again: only the freshness stamp differs, so no new save/reload.
        store._setSnapshotForTesting(Self.snapshot(provider: .antigravity, usedPercent: 10), provider: .antigravity)
        store.persistWidgetSnapshot(reason: "unchanged-refetch")
        await store.widgetSnapshotPersistTask?.value
        #expect(widgetSnapshots.count == 1)

        store._setSnapshotForTesting(Self.snapshot(provider: .antigravity, usedPercent: 25), provider: .antigravity)
        store.persistWidgetSnapshot(reason: "changed")
        await store.widgetSnapshotPersistTask?.value
        #expect(widgetSnapshots.count == 2)
    }

    @Test
    func `widget snapshot persist resumes after max skip interval`() async throws {
        let (store, _) = try Self.makeStore(suite: "UsageStoreWidgetSnapshotTests-dedup-cap")

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store._setSnapshotForTesting(Self.snapshot(provider: .antigravity, usedPercent: 10), provider: .antigravity)
        store.persistWidgetSnapshot(reason: "initial")
        await store.widgetSnapshotPersistTask?.value
        #expect(widgetSnapshots.count == 1)

        // Backdate the last scheduled snapshot past the skip cap; identical content must persist again.
        let last = try #require(store.lastScheduledWidgetSnapshot)
        store.lastScheduledWidgetSnapshot = WidgetSnapshot(
            entries: last.entries,
            enabledProviders: last.enabledProviders,
            generatedAt: last.generatedAt.addingTimeInterval(-16 * 60))
        store.persistWidgetSnapshot(reason: "stale-cap")
        await store.widgetSnapshotPersistTask?.value
        #expect(widgetSnapshots.count == 2)
    }

    @Test
    func `widget snapshot save failure does not update dedupe baseline or reload timelines`() async throws {
        let (store, _) = try Self.makeStore(suite: "UsageStoreWidgetSnapshotTests-save-failure")

        var attempts = 0
        var reloads = 0
        store._test_widgetSnapshotSaveResultOverride = { snapshot in
            attempts += 1
            return .failed(
                path: "/tmp/widget-snapshot-\(snapshot.generatedAt.timeIntervalSince1970).json",
                message: "disk full")
        }
        store._test_widgetTimelineReloadOverride = { reloads += 1 }
        defer {
            store._test_widgetSnapshotSaveResultOverride = nil
            store._test_widgetTimelineReloadOverride = nil
        }

        store._setSnapshotForTesting(Self.snapshot(provider: .antigravity, usedPercent: 10), provider: .antigravity)
        store.persistWidgetSnapshot(reason: "first-failure")
        await store.widgetSnapshotPersistTask?.value
        #expect(attempts == 1)
        #expect(reloads == 0)
        #expect(store.lastScheduledWidgetSnapshot == nil)

        store._setSnapshotForTesting(Self.snapshot(provider: .antigravity, usedPercent: 10), provider: .antigravity)
        store.persistWidgetSnapshot(reason: "retry-after-failure")
        await store.widgetSnapshotPersistTask?.value
        #expect(attempts == 2)
        #expect(reloads == 0)
        #expect(store.lastScheduledWidgetSnapshot == nil)
    }

    @Test
    func `widget snapshot save success after failure updates dedupe baseline and reloads timelines`() async throws {
        let (store, _) = try Self.makeStore(suite: "UsageStoreWidgetSnapshotTests-save-recovers")

        var attempts = 0
        var reloads = 0
        store._test_widgetSnapshotSaveResultOverride = { _ in
            attempts += 1
            return attempts == 1
                ? .failed(path: "/tmp/widget-snapshot.json", message: "disk full")
                : .saved(path: "/tmp/widget-snapshot.json")
        }
        store._test_widgetTimelineReloadOverride = { reloads += 1 }
        defer {
            store._test_widgetSnapshotSaveResultOverride = nil
            store._test_widgetTimelineReloadOverride = nil
        }

        store._setSnapshotForTesting(Self.snapshot(provider: .antigravity, usedPercent: 10), provider: .antigravity)
        store.persistWidgetSnapshot(reason: "failure")
        await store.widgetSnapshotPersistTask?.value
        #expect(store.lastScheduledWidgetSnapshot == nil)

        store.persistWidgetSnapshot(reason: "success")
        await store.widgetSnapshotPersistTask?.value
        #expect(attempts == 2)
        #expect(reloads == 1)
        #expect(store.lastScheduledWidgetSnapshot != nil)
    }

    private static func makeStore(suite: String) throws -> (UsageStore, SettingsStore) {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        return (store, settings)
    }

    private static func snapshot(provider: UsageProvider, usedPercent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: usedPercent, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 30, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: provider,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Pro"))
    }
}
