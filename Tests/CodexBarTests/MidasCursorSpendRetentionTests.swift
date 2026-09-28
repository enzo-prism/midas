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

    @Test
    func `a report from another signed-in account is rejected`() {
        let store = Self.makeStore()
        store._setSnapshotForTesting(Self.usage(email: "me@example.com"), provider: .cursor)

        #expect(!store.acceptCursorSpendSnapshot(Self.spend(account: "other@example.com")))
        #expect(store.tokenSnapshots[.cursor] == nil)
        #expect(store.tokenErrors[.cursor]?.contains("different signed-in Cursor account") == true)
        #expect(store.cursorSpendAccountKey == nil)

        #expect(store.acceptCursorSpendSnapshot(Self.spend(account: "Me@Example.com")))
        #expect(store.cursorSpendAccountKey == "me@example.com")
    }

    @Test
    func `an estimate is dropped once usage reports a different account`() {
        let store = Self.makeStore()
        // Status has not answered yet, so the report's own account owns the estimate.
        #expect(store.acceptCursorSpendSnapshot(Self.spend(account: "me@example.com")))
        store._setTokenSnapshotForTesting(Self.spend(account: "me@example.com"), provider: .cursor)

        store._setSnapshotForTesting(Self.usage(email: "me@example.com"), provider: .cursor)
        store.dropCursorSpendFromAnotherAccount()
        #expect(store.tokenSnapshots[.cursor] != nil)

        store._setSnapshotForTesting(Self.usage(email: "someone-else@example.com"), provider: .cursor)
        store.dropCursorSpendFromAnotherAccount()
        #expect(store.tokenSnapshots[.cursor] == nil)
        #expect(store.cursorSpendAccountKey == nil)
    }

    @Test
    func `an unowned estimate is dropped once the account is known`() {
        let store = Self.makeStore()
        // Neither the report nor status knew the account; the value is shown but cannot be attributed later.
        #expect(store.acceptCursorSpendSnapshot(Self.spend(account: nil)))
        store._setTokenSnapshotForTesting(Self.spend(account: nil), provider: .cursor)
        #expect(store.cursorSpendMatchesCurrentAccount())

        store._setSnapshotForTesting(Self.usage(email: "me@example.com"), provider: .cursor)
        #expect(!store.cursorSpendMatchesCurrentAccount())
        store.dropCursorSpendFromAnotherAccount()
        #expect(store.tokenSnapshots[.cursor] == nil)
    }

    @Test
    func `a token account label is not treated as a Cursor account`() {
        let store = Self.makeStore()
        store._setSnapshotForTesting(Self.usage(email: "Work"), provider: .cursor)
        #expect(store.cursorStatusAccountKey == nil)
        #expect(store.acceptCursorSpendSnapshot(Self.spend(account: "work@example.com")))
        #expect(store.cursorSpendAccountKey == "work@example.com")
    }

    @Test
    func `switching accounts changes the cursor cost scope`() {
        let store = Self.makeStore()
        let unknown = store.tokenCostScope(for: .cursor).signature
        store._setSnapshotForTesting(Self.usage(email: "Me@Example.com"), provider: .cursor)
        let me = store.tokenCostScope(for: .cursor).signature
        store._setSnapshotForTesting(Self.usage(email: "other@example.com"), provider: .cursor)
        let other = store.tokenCostScope(for: .cursor).signature

        #expect(me == "cursor:me@example.com")
        #expect(Set([unknown, me, other]).count == 3)
        #expect(store.tokenCostScope(for: .codex).signature.hasPrefix("codex:"))
    }

    private static func spend(account: String? = nil) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 10,
            last30DaysCostUSD: 3.5,
            costProvenance: .listPriceEstimate,
            accountEmail: account,
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
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        // Never touch the real Cursor spend cache.
        store.cursorSpendCacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("midas-cursor-retention-\(UUID().uuidString)", isDirectory: true)
        return store
    }
}
