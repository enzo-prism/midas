import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MidasUsageSyncDisplayTests {
    @Test func sharedScopeReplacesCloudTotalsAndUsesUTC() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        let local = Self.snapshot(tokens: 900, cost: 90)
        let shared = Self.snapshot(tokens: 30, cost: 3)
        store._setTokenSnapshotForTesting(local, provider: .codex)
        store.midasUsageSync.snapshots[.codex] = shared
        #expect(store.displayTokenSnapshot(for: .codex) == local)
        store.midasUsageSync.folderURL = URL(fileURLWithPath: "/synthetic-shared-folder")
        store.midasUsageSync.isEnabled = true
        #expect(store.displayTokenSnapshot(for: .codex) == shared)
        #expect(store.spendReportingTimeZone(for: .codex, snapshot: shared) == MidasSpendPeriod.utc)
        store.midasUsageSync.folderURL = nil
        #expect(store.displayTokenSnapshot(for: .codex) == shared)
        #expect(store.midasDisplayTimeZone == MidasSpendPeriod.utc)
        store.midasUsageSync.includesSyncedUsage = false
        #expect(store.displayTokenSnapshot(for: .codex) == local)
        #expect(!store.usesSyncedUsage(for: .codex))
    }

    @Test func missingSharedHistoryDoesNotFallBackToOverlappingLocalTotals() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        store._setTokenSnapshotForTesting(Self.snapshot(tokens: 900, cost: 90), provider: .codex)
        store.midasUsageSync.folderURL = URL(fileURLWithPath: "/synthetic-shared-folder")
        store.midasUsageSync.isEnabled = true
        #expect(store.displayTokenSnapshot(for: .codex) == nil)
    }

    @Test func sharedSparkMeasurementsReceiveTrustedDisplayValueWithoutMutatingLedger() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        let raw = CostUsageTokenSnapshot(
            sessionTokens: 100,
            sessionCostUSD: nil,
            last30DaysTokens: 100,
            last30DaysCostUSD: nil,
            daily: [CostUsageDailyReport.Entry(
                date: "2026-10-15",
                inputTokens: 80,
                outputTokens: 20,
                cacheReadTokens: 40,
                totalTokens: 100,
                requestCount: 1,
                costUSD: nil,
                modelsUsed: [DGXSparkPricing.modelID],
                modelBreakdowns: [CostUsageDailyReport.ModelBreakdown(
                    modelName: DGXSparkPricing.modelID,
                    costUSD: nil,
                    totalTokens: 100,
                    requestCount: 1,
                    inputTokens: 80,
                    outputTokens: 20,
                    cacheReadTokens: 40)],
                unpricedRequestCount: 1)],
            updatedAt: Date())
        store.midasUsageSync.snapshots[.localInference] = raw
        store.midasUsageSync.folderURL = URL(fileURLWithPath: "/synthetic-shared-folder")
        store.midasUsageSync.isEnabled = true
        let display = try #require(store.displayTokenSnapshot(for: .localInference))
        #expect(display.last30DaysCostUSD == 0.00002)
        #expect(display.last30DaysAPIEquivalentCostUSD == nil)
        #expect(display.daily.first?.apiEquivalentCostUSD == nil)
        #expect(display.costProvenance == .listPriceEstimate)
        #expect(store.midasUsageSync.snapshots[.localInference] == raw)
        #expect(store.displayTokenSnapshot(for: .localInference) == display)
    }

    @Test func cursorHistoryRequiresVerifiedOwnerAndSharesOpaqueAccount() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        let workspace = MidasUsageSyncWorkspace()
        store._setTokenSnapshotForTesting(Self.snapshot(tokens: 20, cost: 2), provider: .cursor)
        #expect(store.midasCursorSyncDays(workspace: workspace).isEmpty)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .cursor,
                    accountEmail: "PERSON@EXAMPLE.COM",
                    accountOrganization: nil,
                    loginMethod: nil)),
            provider: .cursor)
        store.cursorSpendAccountKey = "person@example.com"
        let rows = store.midasCursorSyncDays(workspace: workspace)
        #expect(rows.count == 1)
        let encoded = try #require(String(bytes: JSONEncoder().encode(rows), encoding: .utf8))
        #expect(!encoded.contains("example.com"))
        #expect(rows.first?.values.tokens == 20)
        store.cursorSpendAccountKey = "different@example.com"
        #expect(store.midasCursorSyncDays(workspace: workspace).isEmpty)
    }

    @Test func sharedMonthLabelsAndChoicesUseUTCAtMonthBoundaries() throws {
        let boundary = try #require(ISO8601DateFormatter().date(from: "2026-10-01T01:00:00Z"))
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(MidasSpendPeriod.currentMonth.label(reportingTimeZone: losAngeles, now: boundary) == "September")
        #expect(MidasSpendPeriod.currentMonth
            .label(reportingTimeZone: MidasSpendPeriod.utc, now: boundary) == "October")
        #expect(MidasSpendPeriodChoices.recordedMonths(
            dates: ["2026-09-30"], now: boundary, timeZone: MidasSpendPeriod.utc) == ["2026-09"])
        #expect(MidasSpendPeriodChoices.recordedMonths(
            dates: ["2026-09-30"], now: boundary, timeZone: losAngeles).isEmpty)
    }

    private static func snapshot(tokens: Int, cost: Double) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: tokens,
            sessionCostUSD: cost,
            last30DaysTokens: tokens,
            last30DaysCostUSD: cost,
            costProvenance: .listPriceEstimate,
            daily: [CostUsageDailyReport.Entry(
                date: "2026-10-12",
                inputTokens: tokens,
                outputTokens: 0,
                totalTokens: tokens,
                costUSD: cost,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: Date())
    }

    @MainActor
    private struct Fixture {
        let suite = "MidasUsageSyncDisplayTests-" + UUID().uuidString
        let store: UsageStore

        init() {
            let defaults = UserDefaults(suiteName: self.suite)!
            let settings = SettingsStore(
                userDefaults: defaults,
                configStore: testConfigStore(suiteName: self.suite),
                zaiTokenStore: NoopZaiTokenStore(),
                syntheticTokenStore: NoopSyntheticTokenStore())
            settings.refreshFrequency = .manual
            settings.statusChecksEnabled = false
            settings.providerDetectionCompleted = true
            self.store = UsageStore(
                fetcher: UsageFetcher(),
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings,
                startupBehavior: .testing,
                environmentBase: [:])
        }

        func cleanup() {
            UserDefaults(suiteName: self.suite)?.removePersistentDomain(forName: self.suite)
        }
    }
}
