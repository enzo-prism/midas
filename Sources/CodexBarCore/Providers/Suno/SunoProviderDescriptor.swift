import Foundation

public enum SunoProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .suno,
            metadata: ProviderMetadata(
                id: .suno,
                displayName: "Suno",
                sessionLabel: "Credits",
                weeklyLabel: "Downloads",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Suno usage",
                cliName: "suno",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://suno.com/account",
                subscriptionDashboardURL: "https://suno.com/account",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .suno,
                iconResourceName: "ProviderIcon-suno",
                color: ProviderColor(red: 0.92, green: 0.92, blue: 0.90)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Suno reports credits and downloads, not spend history." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [SunoCLIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "suno",
                aliases: [],
                versionDetector: nil))
    }
}

struct SunoCLIFetchStrategy: ProviderFetchStrategy {
    let id: String = "suno.cli"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        _ = context
        // Stay available so a missing or signed-out CLI surfaces as actionable setup guidance.
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let usage = try await SunoCLIProbe().fetch(environment: context.env)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "cli")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
