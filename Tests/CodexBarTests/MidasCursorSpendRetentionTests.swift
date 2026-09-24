import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// A failed or slow cursor.com refresh keeps the last Cursor estimate (labeled last known) instead of blanking it.
@MainActor
struct MidasCursorSpendRetentionTests {
    private struct TransientError: Error {}

    @Test
    func `failures keep the last cursor estimate unless its source is off or the account changed`() {
        let store = Self.makeStore()
        #expect(store.keepsLastKnownCursorSpend(provider: .cursor, error: TransientError()) == false)

        store._setTokenSnapshotForTesting(Self.spend(), provider: .cursor)
        #expect(store.keepsLastKnownCursorSpend(provider: .cursor, error: TransientError()))
        #expect(store.keepsLastKnownCursorSpend(provider: .codex, error: TransientError()) == false)
        #expect(store.keepsLastKnownCursorSpend(
            provider: .cursor,
            error: CostUsageError.sourceDisabled(.cursor)) == false)

        store.cursorSpendAccountKey = "me@example.com"
        store._setSnapshotForTesting(Self.usage(email: "Me@Example.com"), provider: .cursor)
        #expect(store.keepsLastKnownCursorSpend(provider: .cursor, error: TransientError()))
        store._setSnapshotForTesting(Self.usage(email: "someone-else@example.com"), provider: .cursor)
        #expect(store.keepsLastKnownCursorSpend(provider: .cursor, error: TransientError()) == false)
    }

    private static func spend() -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 10,
            last30DaysCostUSD: 3.5,
            costProvenance: .listPriceEstimate,
            daily: [CostUsageDailyReport.Entry(
                date: "2026-09-23",
                inputTokens: 5,
                outputTokens: 5,
                totalTokens: 10,
                costUSD: 3.5,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: Date())
    }

    private static func usage(email: String) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .cursor,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: nil))
    }

    private static func makeStore() -> UsageStore {
        let suite = "MidasCursorSpendRetentionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        settings.providerDetectionCompleted = true
        return UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }
}
