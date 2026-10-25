import Foundation

/// Meta provider (Muse Code, powered by Muse Spark).
///
/// Plan usage (current window + weekly, with resets) comes from Meta's provider
/// itself: Midas asks the Muse host over MSP (`muse serve`) for its
/// last-observed subscription usage, sending one minimal prompt at most once
/// an hour in a dedicated "Midas usage check" session when nothing has been
/// observed yet. Token totals for spend still come from the local Muse
/// session log (`~/.local/share/muse/sessions/**/session.jsonl`). No browser
/// cookies or passwords are touched. An optional `META_API_KEY` (Meta Model
/// API, `dev.meta.ai`) can be stored alongside; the subscription windows above
/// always describe the Muse Code plan, not pay-as-you-go API usage.
public enum MetaProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .meta,
            metadata: ProviderMetadata(
                id: .meta,
                displayName: "Meta",
                sessionLabel: "Current usage",
                weeklyLabel: "Weekly limit",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Meta usage",
                cliName: "meta",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://dev.meta.ai/usage",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .meta,
                iconResourceName: "ProviderIcon-meta",
                color: ProviderColor(red: 0 / 255, green: 100 / 255, blue: 255 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "No Muse usage found in local session logs yet." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [MetaSubscriptionFetchStrategy(), MetaLocalFetchStrategy()]
                })),
            cli: ProviderCLIConfig(
                name: "meta",
                aliases: ["muse", "muse-spark"],
                versionDetector: nil))
    }
}

/// Primary Meta strategy: real subscription windows from the Muse host,
/// combined with the local log's token totals. Falls back to the local-only
/// strategy when the probe cannot run or Meta reports nothing.
struct MetaSubscriptionFetchStrategy: ProviderFetchStrategy {
    let id: String = "meta.subscription"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        MetaUsageProbe.locateMuseBinary() != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let now = Date()
        let since = Calendar.current.date(
            byAdding: .day,
            value: -(max(1, min(365, context.costUsageHistoryDays)) - 1),
            to: now) ?? now
        let summary = MuseSessionLogScanner.loadSummary(since: since, until: now, now: now)
        let usage = try await Self.subscriptionUsage(now: now)
        let snapshot = MetaUsageSnapshot(summary: summary, usage: usage).toUsageSnapshot()
        return self.makeResult(usage: snapshot, sourceLabel: "muse-usage")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        true
    }

    /// Fresh cache needs no probe. A missing or stale cache probes once; an
    /// exhausted plan becomes a blocked reading that lasts until its reset. Any
    /// other failure is recorded so the next probe waits out the same hourly
    /// budget, and keeps the stale reading rather than losing the plan windows.
    static func subscriptionUsage(
        now: Date,
        cacheRoot: URL? = nil,
        probe: (String?) async throws -> (usage: MetaSubscriptionUsage, sessionID: String?) = {
            try await MetaUsageProbe.fetchUsage(probeSessionID: $0)
        }) async throws -> MetaSubscriptionUsage
    {
        let cached = MetaSubscriptionUsageCache.load(cacheRoot: cacheRoot)
        if let cached, MetaSubscriptionUsageCache.isFresh(cached, now: now), let usage = cached.usage {
            return usage
        }
        let lastKnown = cached?.usage.flatMap { $0.isCurrent(now: now) ? $0 : nil }
        if let cached, MetaSubscriptionUsageCache.isBackingOff(cached, now: now) {
            if let lastKnown {
                return lastKnown
            }
            throw MetaUsageProbeError.noUsageObserved
        }
        do {
            let probed = try await probe(cached?.probeSessionID)
            MetaSubscriptionUsageCache.save(
                MetaSubscriptionUsageCache.Payload(
                    usage: probed.usage,
                    probeSessionID: probed.sessionID ?? cached?.probeSessionID),
                cacheRoot: cacheRoot)
            return probed.usage
        } catch {
            let failure = error as? MetaUsageProbeFailure
            let sessionID = failure?.sessionID ?? cached?.probeSessionID
            if case let .quotaExhausted(resetsAt)? = failure?.error {
                let usage = MetaSubscriptionUsage.blocked(until: resetsAt, observedAt: now, previous: cached?.usage)
                MetaSubscriptionUsageCache.save(
                    MetaSubscriptionUsageCache.Payload(usage: usage, probeSessionID: sessionID),
                    cacheRoot: cacheRoot)
                return usage
            }
            if ProcessInfo.processInfo.environment["MIDAS_META_PROBE_DEBUG"] == "1" {
                FileHandle.standardError.write(Data("meta probe failed: \(error)\n".utf8))
            }
            MetaSubscriptionUsageCache.save(
                MetaSubscriptionUsageCache.Payload(usage: cached?.usage, probeSessionID: sessionID, lastFailureAt: now),
                cacheRoot: cacheRoot)
            if let lastKnown {
                return lastKnown
            }
            throw error
        }
    }
}

struct MetaLocalFetchStrategy: ProviderFetchStrategy {
    let id: String = "meta.local"
    let kind: ProviderFetchKind = .localProbe

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let now = Date()
        let since = Calendar.current.date(
            byAdding: .day,
            value: -(max(1, min(365, context.costUsageHistoryDays)) - 1),
            to: now) ?? now
        let apiKey = MetaSettingsReader.apiKey(environment: context.env)
        do {
            let summary = MuseSessionLogScanner.loadSummary(since: since, until: now, now: now)
            guard summary.sessionsWithData > 0 else {
                throw MetaUsageError.noLocalData
            }
            MetaAPIKeyUsageTracker.recordSuccess(
                apiKey: apiKey,
                usage: summary.last30Days,
                requests: summary.sessionsWithData,
                at: now)
            let usage = MetaUsageSnapshot(summary: summary).toUsageSnapshot()
            return self.makeResult(usage: usage, sourceLabel: "muse-log")
        } catch {
            MetaAPIKeyUsageTracker.recordFailure(apiKey: apiKey, error: error, at: now)
            throw error
        }
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

public enum MetaUsageError: LocalizedError, Sendable {
    case noLocalData

    public var errorDescription: String? {
        switch self {
        case .noLocalData:
            "No Muse usage found. Run `muse` once so ~/.local/share/muse/sessions/ has data."
        }
    }
}

/// Snapshot mapping for the Meta provider menu card. With real subscription
/// usage, primary/secondary are Meta's own current and weekly windows; without
/// it they stay token-description windows and the activity snapshot drives the
/// fallback bars.
public struct MetaUsageSnapshot: Sendable {
    public let summary: MetaUsageSummary
    public let usage: MetaSubscriptionUsage?

    public init(summary: MetaUsageSummary, usage: MetaSubscriptionUsage? = nil) {
        self.summary = summary
        self.usage = usage
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let todayTokens = self.summary.today.totalTokens
        let weekTokens = self.summary.last7Days.totalTokens
        let model = self.summary.modelsUsed.first
        let primary: RateWindow
        let secondary: RateWindow
        if let usage {
            primary = RateWindow(
                usedPercent: min(100, max(0, usage.windowUsedPercent)),
                windowMinutes: usage.windowDurationMins,
                resetsAt: usage.windowResetsAt,
                resetDescription: nil)
            secondary = RateWindow(
                usedPercent: min(100, max(0, usage.weeklyUsedPercent)),
                windowMinutes: 7 * 24 * 60,
                resetsAt: usage.weeklyResetsAt,
                resetDescription: nil)
        } else {
            primary = RateWindow(
                usedPercent: 0,
                windowMinutes: 24 * 60,
                resetsAt: nil,
                resetDescription: "\(Self.formatTokens(todayTokens)) today")
            secondary = RateWindow(
                usedPercent: 0,
                windowMinutes: 7 * 24 * 60,
                resetsAt: nil,
                resetDescription: "\(Self.formatTokens(weekTokens)) last 7d")
        }
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            metaActivity: MetaActivitySnapshot(summary: self.summary),
            metaUsage: self.usage,
            updatedAt: self.summary.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .meta,
                accountEmail: nil,
                accountOrganization: model,
                loginMethod: self.usage == nil ? "local" : "muse-usage"))
    }

    static func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1000 {
            return String(format: "%.1fk", Double(value) / 1000)
        }
        return "\(value)"
    }
}
