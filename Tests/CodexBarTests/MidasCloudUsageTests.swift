import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MidasCloudUsageTests {
    private let now = Date(timeIntervalSince1970: 1_789_171_200) // 2026-09-12 00:00 UTC

    private func usage(
        _ tokens: Int,
        date: String = "2026-09-10",
        asOf: Date? = nil) throws -> CodexCloudAccountUsage
    {
        let profile: [String: Any] = [
            "stats": ["daily_usage_buckets": [["start_date": date, "tokens": tokens]]],
            "metadata": ["stats_as_of": "2026-09-11"],
        ]
        let breakdown: [String: Any] = [
            "units": "percent",
            "data": [["date": date, "models": [["model": "gpt-5", "credits": 42.0]]]],
        ]
        return try CodexCloudAccountUsage.parse(
            profile: JSONSerialization.data(withJSONObject: profile),
            breakdown: JSONSerialization.data(withJSONObject: breakdown),
            now: asOf ?? self.now)
    }

    @MainActor @Test func refreshPublishesFetchedAccountHistory() async throws {
        let suite = "MidasCloudRefresh-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(
                suiteName: suite,
                reset: false),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings._test_managedCodexAccountStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "test@example.com",
            authFingerprint: "test",
            codexHomePath: "/nonexistent",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-test"))
        settings.costUsageEnabled = true
        settings.midasCloudUsageEnabled = true
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._test_widgetSnapshotSaveOverride = { _ in }
        let usage = try self.usage(
            1_000_000,
            date: CodexCloudAccountUsage.window(now: Date()).end,
            asOf: Date())
        #expect(settings.codexVisibleAccountProjection.visibleAccounts.count == 1)
        await store.refreshMidasCloudUsage(
            force: true,
            loader: { _, _ in usage })
        #expect(store.midasCloudAccounts.count == 1)
        #expect(store.tokenSnapshots[.codex]?.last30DaysTokens == 1_000_000)
        #expect(store.lastTokenFetchScope[.codex]?.hasPrefix("cloud:") == true)
        #expect(store.midasCloudErrors.isEmpty)
        settings.midasCodexEstimateMode = .custom
        settings.midasCloudUSDPerMillionTokens = 2
        store.repriceMidasCloudUsage()
        #expect(store.tokenSnapshots[.codex]?.last30DaysCostUSD == 2)
        #expect(store.tokenSnapshots[.codex]?.updatedAt == usage.fetchedAt)
        settings.midasCodexEstimateMode = .tokensOnly
        store.repriceMidasCloudUsage()
        #expect(store.tokenSnapshots[.codex]?.last30DaysCostUSD == nil)
        let date = Date()
        store.midasCodexCalibrationScope = store.tokenCostScope(for: .codex).signature
        store.midasCodexCalibration = MidasCodexCalibration(
            rate: 0.75,
            pricedTokens: 1_000_000,
            observedTokens: 1_000_000,
            sampledAt: date,
            lastUsageDay: CodexCloudAccountUsage.window(now: date).end)
        settings.midasCodexEstimateMode = .automatic
        store.repriceMidasCloudUsage()
        #expect(store.tokenSnapshots[.codex]?.last30DaysCostUSD == 0.75)
        #expect(store.tokenSnapshots[.codex]?.last30DaysTokens == 1_000_000)
        #expect(store.tokenSnapshots[.codex]?.updatedAt == usage.fetchedAt)
        #expect(settings.midasCloudUSDPerMillionTokens == 2)
        store.midasCodexCalibrationScope = "old scope"
        store.repriceMidasCloudUsage()
        #expect(store.tokenSnapshots[.codex]?.last30DaysCostUSD == nil)
        settings.midasCalibrationSharingEnabled = true
        let scope = try #require(store.midasCalibrationPortableScope)
        store.midasSharedCalibration = MidasCalibrationExchange.Record(
            deviceID: UUID(),
            scope: scope,
            calibration: MidasCodexCalibration(
                rate: 1.25,
                pricedTokens: 2_000_000,
                observedTokens: 2_000_000,
                sampledAt: date,
                lastUsageDay: CodexCloudAccountUsage.window(now: date).end))
        store.repriceMidasCloudUsage()
        #expect(store.tokenSnapshots[.codex]?.last30DaysCostUSD == 1.25)
        #expect(store.tokenSnapshots[.codex]?.last30DaysTokens == 1_000_000)
        settings.midasCodexEstimateMode = .custom
        store.repriceMidasCloudUsage()
        #expect(store.tokenSnapshots[.codex]?.last30DaysCostUSD == 2)
        settings.midasCodexEstimateMode = .automatic
        settings.midasCalibrationSharingEnabled = false
        store.repriceMidasCloudUsage()
        #expect(store.tokenSnapshots[.codex]?.last30DaysCostUSD == nil)
    }

    @Test func cloudTokensCombineWithoutPricingPercentages() throws {
        let first = try self.usage(1_000_000)
        let second = try self.usage(2_000_000)
        let snapshot = UsageStore.cloudTokenSnapshot(
            accounts: [first, second],
            rate: 0,
            now: self.now)
        #expect(snapshot.last30DaysTokens == 3_000_000)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.daily.first?.modelBreakdowns == nil)
        #expect(first.modelUnits == "percent")
        #expect(first.models.first?.value == 42)
    }

    @Test func explicitRatePricesCombinedCloudTokensOnce() throws {
        let accounts = try [self.usage(1_000_000), self.usage(2_000_000)]
        let snapshot = UsageStore.cloudTokenSnapshot(
            accounts: accounts,
            rate: 0.75,
            now: self.now)
        #expect(snapshot.last30DaysCostUSD == 2.25)
        #expect(snapshot.daily.first?.costUSD == 2.25)
        #expect(snapshot.costProvenance == .unknown)
    }

    @Test func missingHistoryIsNotZeroAndOldDaysAreExcluded() throws {
        let old = try self.usage(
            500,
            date: "2026-01-01")
        #expect(old.totalTokens == nil)
        let snapshot = UsageStore.cloudTokenSnapshot(
            accounts: [old],
            rate: 1,
            now: self.now)
        #expect(snapshot.last30DaysTokens == nil)
        #expect(snapshot.last30DaysCostUSD == nil)
    }

    @Test func negativeTokensAreRejected() {
        #expect(throws: (any Error).self) { try self.usage(-1) }
    }

    @Test func inclusiveThirtyDayWindowUsesUTC() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-11T23:30:00Z"))
        let range = CodexCloudAccountUsage.window(now: now)
        #expect(range.start == "2026-08-13")
        #expect(range.end == "2026-09-11")
    }
}
