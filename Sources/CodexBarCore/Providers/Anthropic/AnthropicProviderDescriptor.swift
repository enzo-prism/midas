import CodexBarMacroSupport
import Foundation

/// Anthropic API Platform organization spend (Claude Console), separate from Claude subscription limits.
@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum AnthropicProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .anthropic,
            metadata: ProviderMetadata(
                id: .anthropic,
                displayName: "Anthropic",
                sessionLabel: "Spend",
                weeklyLabel: "Tokens",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Anthropic API usage",
                cliName: "anthropic",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://console.anthropic.com/usage",
                statusPageURL: "https://status.claude.com/"),
            branding: ProviderBranding(
                iconStyle: .claude,
                iconResourceName: "ProviderIcon-claude",
                color: ProviderColor(red: 0.72, green: 0.40, blue: 0.29)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "Anthropic usage needs an Admin API key for organization usage." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [AnthropicAdminAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "anthropic",
                aliases: ["anthropic-api"],
                versionDetector: nil))
    }
}

struct AnthropicAdminAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "anthropic.admin-api"
    let kind: ProviderFetchKind = .apiToken
    let usageFetcher: @Sendable (String, Int) async throws -> ClaudeAdminAPIUsageSnapshot

    init(
        usageFetcher: @escaping @Sendable (String, Int) async throws -> ClaudeAdminAPIUsageSnapshot = { apiKey, days in
            try await ClaudeAdminAPIUsageFetcher.fetchUsage(
                apiKey: apiKey,
                organizationURL: ClaudeAdminAPIUsageFetcher.organizationURL,
                historyDays: days)
        })
    {
        self.usageFetcher = usageFetcher
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        AnthropicSettingsReader.adminAPIKey(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = AnthropicSettingsReader.adminAPIKey(environment: context.env) else {
            throw AnthropicSettingsError.missingToken
        }
        let usage = try await self.usageFetcher(apiKey, context.costUsageHistoryDays)
        return self.makeResult(
            usage: usage.toUsageSnapshot(provider: .anthropic),
            sourceLabel: "admin-api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
