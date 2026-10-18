import CodexBarCore
import Foundation
import Observation

extension UsageStore {
    func startMidasUsageSync() {
        self.midasUsageSync.makeLocalUsage = { [weak self] workspace, now in
            guard let self else { return MidasUsageSyncLocalUsage() }
            return try await self.makeMidasSyncUsage(workspace: workspace, now: now)
        }
        self.midasUsageSync.start()
        self.observeMidasSyncForWidgets()
    }

    func observeMidasSyncForWidgets() {
        withObservationTracking {
            _ = self.midasUsageSync.snapshots
            _ = self.midasUsageSync.isEnabled
            _ = self.midasUsageSync.includesSyncedUsage
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeMidasSyncForWidgets()
                self.persistWidgetSnapshot(reason: "usage-sync")
            }
        }
    }

    static func isRunningTestsProcess() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        if environment["XCTestSessionIdentifier"] != nil { return true }
        if environment["SWIFT_TESTING_ENABLED"] != nil || environment["SWIFT_TESTING"] != nil { return true }
        return CommandLine.arguments.contains { argument in
            argument.contains("xctest") || argument.contains("swift-testing")
        }
    }

    var midasDisplayTimeZone: TimeZone {
        self.midasUsageSync.isEnabled && self.midasUsageSync.includesSyncedUsage
            && (self.midasUsageSync.hasConnection || !self.midasUsageSync.snapshots.isEmpty)
            ? MidasSpendPeriod.utc : .current
    }

    static let midasSyncProviders: Set<UsageProvider> = [.codex, .claude, .cursor, .meta, .localInference]

    func usesSyncedUsage(for provider: UsageProvider) -> Bool {
        self.midasUsageSync.isEnabled && self.midasUsageSync.includesSyncedUsage
            && (self.midasUsageSync.hasConnection || !self.midasUsageSync.snapshots.isEmpty)
            && Self.midasSyncProviders.contains(provider)
    }

    /// All spend surfaces use one scope. Never combine Codex cloud totals with local session events.
    func displayTokenSnapshot(for provider: UsageProvider) -> CostUsageTokenSnapshot? {
        if self.usesSyncedUsage(for: provider) { return self.midasUsageSync.snapshots[provider] }
        let projected = self.tokenSnapshot(fromProviderSnapshot: self.snapshot(for: provider), provider: provider)
        if Self.tokenCostRequiresProviderSnapshot(provider) { return projected }
        return projected ?? self.tokenSnapshot(for: provider)
    }

    func midasProvidersForUsageDisplay() -> [UsageProvider] {
        let local = self.enabledProvidersForDisplay()
        guard self.midasUsageSync.isEnabled, self.midasUsageSync.includesSyncedUsage else { return local }
        let remote = Self.midasSyncProviders.filter { self.midasUsageSync.snapshots[$0] != nil }
        return local + remote.filter { !local.contains($0) }.sorted { $0.rawValue < $1.rawValue }
    }

    /// Combined totals have one shared source set, independent of each Mac's provider display preferences.
    func midasProvidersForTotalDisplay() -> [UsageProvider] {
        let combined = self.midasUsageSync.isEnabled && self.midasUsageSync.includesSyncedUsage
            && (self.midasUsageSync.hasConnection || !self.midasUsageSync.snapshots.isEmpty)
        return MidasRecordedTokenTotal.providersForTotal(
            local: self.enabledProvidersForDisplay(),
            shared: Array(self.midasUsageSync.snapshots.keys),
            combined: combined)
    }

    func spendReportingTimeZone(for provider: UsageProvider, snapshot: CostUsageTokenSnapshot?) -> TimeZone {
        if self.usesSyncedUsage(for: provider) { return MidasSpendPeriod.utc }
        return MidasMonthlySpend.reportingTimeZone(
            provider: provider,
            codexCloudEnabled: self.settings.midasCloudUsageEnabled,
            provenance: snapshot?.costProvenance ?? .unknown)
    }

    /// Sharing always includes every stored account's logs. Display and quota-account selection
    /// must not change the numeric history other devices receive; the exporter also scans ambient logs.
    var midasCodexSyncAdditionalSessionsRoots: [URL] {
        let roots = self.settings.codexAccountReconciliationSnapshot.storedAccounts.map { account in
            URL(fileURLWithPath: account.managedHomePath, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL
        }
        return Array(Set(roots)).sorted { $0.path < $1.path }
    }

    func makeMidasSyncUsage(workspace: MidasUsageSyncWorkspace, now: Date) async throws -> MidasUsageSyncLocalUsage {
        // Sync opt-in covers the supported numeric logs independently of provider display toggles.
        let enabled = self.enabledProvidersForBackgroundWork()
        let options = MidasUsageSyncExporter.Options(
            codexAdditionalSessionsRoots: self.midasCodexSyncAdditionalSessionsRoots)
        let exported = try await MidasUsageSyncExporter.export(
            workspace: workspace,
            providers: [.codex, .claude, .meta],
            now: now,
            options: options)
        let accountDays = enabled.contains(.cursor) ? self.midasCursorSyncDays(workspace: workspace) : []
        return MidasUsageSyncLocalUsage(
            events: exported.events, accountDays: accountDays, excludedRecords: exported.excludedRecords)
    }

    func midasCursorSyncDays(workspace: MidasUsageSyncWorkspace) -> [MidasUsageSyncAccountDay] {
        guard let account = self.cursorStatusAccountKey, self.cursorSpendMatchesCurrentAccount(),
              let snapshot = self.tokenSnapshots[.cursor], self.cursorSpendAccountKey == account
        else { return [] }
        let scope = workspace.opaqueID(provider: .cursor, components: ["cursor-account-history", account])
        return snapshot.daily.filter { MidasUsageSyncPublication.isDay($0.date) }.map { row in
            MidasUsageSyncAccountDay(
                accountScope: scope,
                provider: .cursor,
                day: row.date,
                observedAt: snapshot.updatedAt,
                values: MidasUsageSyncValues(
                    tokens: row.totalTokens,
                    requests: row.requestCount,
                    costUSD: row.costUSD,
                    apiEquivalentCostUSD: row.apiEquivalentCostUSD,
                    tokenMix: CostUsageTokenMix(
                        inputTokens: row.inputTokens,
                        outputTokens: row.outputTokens,
                        cacheReadTokens: row.cacheReadTokens,
                        cacheCreationTokens: row.cacheCreationTokens,
                        reasoningTokens: row.reasoningTokens),
                    provenance: snapshot.costProvenance,
                    unpricedRequests: row.unpricedRequestCount ?? 0,
                    estimatedRequests: row.estimatedRequestCount ?? 0))
        }
    }
}
