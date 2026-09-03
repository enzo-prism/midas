import CodexBarMacroSupport
import Foundation

/// Meta provider (Muse Code, powered by Muse Spark).
///
/// Primary data source is the local Muse session log
/// (`~/.local/share/muse/sessions/**/session.jsonl`), which records per-response
/// `model_completed` token usage. No browser cookies or passwords are touched.
/// An optional `META_API_KEY` (Meta Model API, `dev.meta.ai`) can be stored for
/// future API-backed quota; the local log remains the usage source of truth.
@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum MetaProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .meta,
            metadata: ProviderMetadata(
                id: .meta,
                displayName: "Meta",
                sessionLabel: "Today",
                weeklyLabel: "7-day",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Meta usage",
                cliName: "meta",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://dev.meta.ai/docs",
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
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [MetaLocalFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "meta",
                aliases: ["muse", "muse-spark"],
                versionDetector: nil))
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

/// Snapshot mapping for the Meta provider menu card.
public struct MetaUsageSnapshot: Sendable {
    public let summary: MetaUsageSummary

    public init(summary: MetaUsageSummary) {
        self.summary = summary
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let todayTokens = self.summary.today.totalTokens
        let weekTokens = self.summary.last7Days.totalTokens
        let model = self.summary.modelsUsed.first
        return UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 24 * 60,
                resetsAt: nil,
                resetDescription: "\(Self.formatTokens(todayTokens)) today"),
            secondary: RateWindow(
                usedPercent: 0,
                windowMinutes: 7 * 24 * 60,
                resetsAt: nil,
                resetDescription: "\(Self.formatTokens(weekTokens)) last 7d"),
            tertiary: nil,
            updatedAt: self.summary.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .meta,
                accountEmail: nil,
                accountOrganization: model,
                loginMethod: "local"))
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
