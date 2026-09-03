import CodexBarCore
import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

extension UsageStore {
    /// Most refresh cycles produce a widget snapshot whose rendered content is identical to the
    /// previous one (only freshness stamps move). Re-persist anyway after this interval so the
    /// widget's relative "updated" label can't drift unboundedly while usage is idle.
    private static let widgetSnapshotMaxSkipInterval: TimeInterval = 15 * 60

    func persistWidgetSnapshot(reason: String) {
        let snapshot = self.makeWidgetSnapshot()
        if let last = self.lastScheduledWidgetSnapshot,
           snapshot.generatedAt.timeIntervalSince(last.generatedAt) < Self.widgetSnapshotMaxSkipInterval,
           snapshot.hasSameRenderedContent(as: last)
        {
            return
        }
        let previousTask = self.widgetSnapshotPersistTask
        self.widgetSnapshotPersistTask = Task { @MainActor in
            _ = await previousTask?.result

            let result: WidgetSnapshotStore.SaveResult
            if let override = self._test_widgetSnapshotSaveResultOverride {
                result = await override(snapshot)
            } else if let override = self._test_widgetSnapshotSaveOverride {
                await override(snapshot)
                result = .saved(path: "test-widget-snapshot-override")
            } else {
                result = await Task.detached(priority: .utility) {
                    WidgetSnapshotStore.save(snapshot)
                }.value
            }

            guard result.didSave else {
                CodexBarLog.logger(LogCategories.app).warning(
                    "Failed to persist widget snapshot",
                    metadata: [
                        "reason": reason,
                        "path": result.path,
                        "error": result.message ?? "unknown",
                    ])
                return
            }

            self.lastScheduledWidgetSnapshot = snapshot
            self.reloadWidgetTimelinesAfterSnapshotPersist()
        }
    }

    private func reloadWidgetTimelinesAfterSnapshotPersist() {
        if let override = self._test_widgetTimelineReloadOverride {
            override()
            return
        }

        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    private func makeWidgetSnapshot() -> WidgetSnapshot {
        let enabledProviders = self.enabledProviders()
        let entries = UsageProvider.allCases.compactMap { provider in
            self.makeWidgetEntry(for: provider)
        }
        return WidgetSnapshot(entries: entries, enabledProviders: enabledProviders, generatedAt: Date())
    }

    private func makeWidgetEntry(for provider: UsageProvider) -> WidgetSnapshot.ProviderEntry? {
        guard let snapshot = self.snapshots[provider] else { return nil }

        let tokenSnapshot = self.tokenSnapshot(fromProviderSnapshot: snapshot, provider: provider) ?? self
            .tokenSnapshots[provider]
        let dailyUsage = tokenSnapshot?.daily.map { entry in
            WidgetSnapshot.DailyUsagePoint(
                dayKey: entry.date,
                totalTokens: entry.totalTokens,
                costUSD: entry.costUSD)
        } ?? []

        let tokenUsage = Self.widgetTokenUsageSummary(from: tokenSnapshot, provider: provider)
        let usageRows = self.widgetUsageRows(provider: provider, snapshot: snapshot)

        let creditsRemaining: Double?
        let codeReviewRemaining: Double?
        if provider == .codex {
            let projection = self.codexConsumerProjection(
                surface: .widget,
                snapshotOverride: snapshot,
                now: snapshot.updatedAt)
            let displayOnlyExtrasHidden = projection.dashboardVisibility == .displayOnly
            creditsRemaining = displayOnlyExtrasHidden ? nil : projection.credits?.remaining
            codeReviewRemaining = displayOnlyExtrasHidden ? nil : projection.remainingPercent(for: .codeReview)
        } else {
            creditsRemaining = nil
            codeReviewRemaining = nil
        }

        return WidgetSnapshot.ProviderEntry(
            provider: provider,
            updatedAt: snapshot.updatedAt,
            primary: snapshot.primary,
            secondary: snapshot.secondary,
            tertiary: snapshot.tertiary,
            usageRows: usageRows,
            creditsRemaining: creditsRemaining,
            codeReviewRemainingPercent: codeReviewRemaining,
            tokenUsage: tokenUsage,
            dailyUsage: dailyUsage)
    }

    private nonisolated static func widgetTokenUsageSummary(
        from snapshot: CostUsageTokenSnapshot?,
        provider: UsageProvider) -> WidgetSnapshot.TokenUsageSummary?
    {
        guard let snapshot else { return nil }
        let fallbackTokens = snapshot.daily.compactMap(\.totalTokens).reduce(0, +)
        let monthTokensValue = snapshot.last30DaysTokens ?? (fallbackTokens > 0 ? fallbackTokens : nil)
        let sessionLabel = provider == .bedrock || provider == .mistral ? "Latest billing day" : "Today"
        let monthLabel = snapshot.historyLabel ?? (snapshot.historyDays == 1 ? "Today" : "\(snapshot.historyDays)d")
        return WidgetSnapshot.TokenUsageSummary(
            sessionCostUSD: snapshot.sessionCostUSD,
            sessionTokens: snapshot.sessionTokens,
            last30DaysCostUSD: snapshot.last30DaysCostUSD,
            last30DaysTokens: monthTokensValue,
            currencyCode: snapshot.currencyCode,
            sessionLabel: sessionLabel,
            last30DaysLabel: monthLabel)
    }

    private func widgetUsageRows(
        provider: UsageProvider,
        snapshot: UsageSnapshot) -> [WidgetSnapshot.WidgetUsageRowSnapshot]
    {
        let metadata = ProviderDefaults.metadata[provider]
        if provider == .codex {
            let projection = self.codexConsumerProjection(
                surface: .widget,
                snapshotOverride: snapshot,
                now: snapshot.updatedAt)
            return projection.visibleRateLanes.compactMap { lane in
                guard let window = projection.rateWindow(for: lane) else { return nil }
                let title = switch lane {
                case .session:
                    metadata?.sessionLabel ?? "Session"
                case .weekly:
                    metadata?.weeklyLabel ?? "Weekly"
                }
                return WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: lane.rawValue,
                    title: title,
                    percentLeft: window.remainingPercent)
            }
        }

        let primaryTitle: String = {
            if provider == .grok,
               let dyn = GrokProviderDescriptor.primaryLabel(window: snapshot.primary)
            {
                return dyn
            }
            return metadata?.sessionLabel ?? "Session"
        }()

        var rows: [WidgetSnapshot.WidgetUsageRowSnapshot] = [
            WidgetSnapshot.WidgetUsageRowSnapshot(
                id: "primary",
                title: primaryTitle,
                percentLeft: snapshot.primary?.remainingPercent),
            WidgetSnapshot.WidgetUsageRowSnapshot(
                id: "secondary",
                title: metadata?.weeklyLabel ?? "Weekly",
                percentLeft: snapshot.secondary?.remainingPercent),
        ]
        if metadata?.supportsOpus == true {
            rows.append(WidgetSnapshot.WidgetUsageRowSnapshot(
                id: "tertiary",
                title: metadata?.opusLabel ?? "Opus",
                percentLeft: snapshot.tertiary?.remainingPercent))
        }
        return rows.filter { $0.percentLeft != nil }
    }
}
