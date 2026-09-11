import CodexBarCore
import Foundation

/// Prior-period (days 31–60) spend backing the Overview header's "vs prior 30d"
/// comparison. Fetched as a 60-day token snapshot per provider and sliced to the
/// older half, so the current-30d cards stay untouched. Refreshes at most twice
/// a day per provider: the prior window slides one day at a time, so hourly
/// refetches would just re-scan logs for the same answer.
extension UsageStore {
    static let priorSpendFetchTTL: TimeInterval = 12 * 60 * 60
    private static let priorSpendFetchTimeout: TimeInterval = 10 * 60
    private static let priorSpendHistoryDays = 60

    func refreshPriorSpendSequence(providers: [UsageProvider], force: Bool = false) async {
        for provider in providers {
            if Task.isCancelled { break }
            await self.refreshPriorSpend(provider, force: force)
        }
    }

    func refreshPriorSpend(_ provider: UsageProvider, force: Bool = false) async {
        guard !(provider == .codex && self.settings.midasCloudUsageEnabled) else { return }
        guard ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.supportsTokenCost else { return }
        let now = Date()
        if !force,
           let last = self.lastPriorSpendFetchAt[provider],
           now.timeIntervalSince(last) < Self.priorSpendFetchTTL
        {
            return
        }
        self.lastPriorSpendFetchAt[provider] = now
        do {
            let environment = provider == .bedrock
                ? ProviderRegistry.makeEnvironment(
                    base: self.environmentBase,
                    provider: provider,
                    settings: self.settings,
                    tokenOverride: nil)
                : self.environmentBase
            let costScope = self.tokenCostScope(for: provider)
            let zaiRegion: ZaiAPIRegion? = provider == .zai ? self.settings.zaiAPIRegion : nil
            let timeoutSeconds = Self.priorSpendFetchTimeout
            let snapshot = try await withThrowingTaskGroup(of: CostUsageTokenSnapshot.self) { group in
                group.addTask(priority: .utility) {
                    try await self.costUsageFetcher.loadTokenSnapshot(
                        provider: provider,
                        environment: environment,
                        now: now,
                        forceRefresh: force,
                        allowVertexClaudeFallback: !self.isEnabled(.claude),
                        codexHomePath: costScope.codexHomePath,
                        codexAdditionalHomePaths: costScope.additionalHomes,
                        historyDays: Self.priorSpendHistoryDays,
                        zaiAPIRegion: zaiRegion,
                        cursorSettings: self.cursorCostSettings(for: provider))
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    throw CostUsageError.timedOut(seconds: Int(timeoutSeconds))
                }
                defer { group.cancelAll() }
                guard let snapshot = try await group.next() else { throw CancellationError() }
                return snapshot
            }
            let prior = OverviewSpendSummary.priorPeriodCost(daily: snapshot.daily)
            self.priorSpendTotals[provider] = [snapshot.currencyCode: prior]
            self.priorSpendFullWindow[provider] = OverviewSpendSummary.hasFullPriorWindow(daily: snapshot.daily)
        } catch {
            if error is CancellationError { return }
            // A failed fetch must not consume the TTL: clear the stamp so the
            // next cycle retries instead of hiding the comparison for 12h.
            self.lastPriorSpendFetchAt.removeValue(forKey: provider)
            self.tokenCostLogger
                .error("prior spend failed provider=\(provider.rawValue) error=\(error.localizedDescription)")
        }
    }

    /// Prior-period costs aligned with `overviewSpendSummary(providers:)`: one
    /// entry per provider that has prior data, plus the count of providers with
    /// a full prior window for the partial marker.
    func priorSpendCosts(providers: [UsageProvider])
    -> (costs: [(currencyCode: String, amount: Double)], fullWindowCount: Int) {
        var costs: [(currencyCode: String, amount: Double)] = []
        var fullWindowCount = 0
        for provider in providers {
            guard let totals = self.priorSpendTotals[provider] else { continue }
            for (code, amount) in totals {
                costs.append((code, amount))
            }
            if self.priorSpendFullWindow[provider] == true { fullWindowCount += 1 }
        }
        return (costs, fullWindowCount)
    }
}
