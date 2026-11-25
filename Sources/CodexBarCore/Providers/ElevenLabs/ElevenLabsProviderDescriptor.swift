import Foundation

public enum ElevenLabsProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .elevenlabs,
            metadata: ProviderMetadata(
                id: .elevenlabs,
                displayName: "ElevenLabs",
                sessionLabel: "Credits",
                weeklyLabel: "Voices",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show ElevenLabs usage",
                cliName: "elevenlabs",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://elevenlabs.io/app/developers/usage",
                subscriptionDashboardURL: "https://elevenlabs.io/app/subscription",
                statusPageURL: nil,
                statusLinkURL: "https://status.elevenlabs.io"),
            branding: ProviderBranding(
                iconStyle: .elevenlabs,
                iconResourceName: "ProviderIcon-elevenlabs",
                color: ProviderColor(red: 0.92, green: 0.92, blue: 0.90)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "ElevenLabs cost history is not available via API yet." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "elevenlabs",
                aliases: ["11labs", "eleven"],
                versionDetector: nil))
    }

    /// Auto prefers an API key when one is configured (one HTTPS request), then the signed-in
    /// ElevenLabs CLI, which needs no key in Midas.
    static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        switch context.sourceMode {
        case .auto:
            [ElevenLabsAPIFetchStrategy(), ElevenLabsCLIFetchStrategy()]
        case .api:
            [ElevenLabsAPIFetchStrategy()]
        case .cli:
            [ElevenLabsCLIFetchStrategy()]
        case .web, .oauth:
            []
        }
    }
}

struct ElevenLabsAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "elevenlabs.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        // In API mode stay available so a missing key surfaces as setup guidance.
        context.sourceMode == .api || Self.resolveToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveToken(environment: context.env) else {
            throw ElevenLabsUsageError.missingCredentials
        }
        let usage = try await ElevenLabsUsageFetcher.fetchUsage(
            apiKey: apiKey,
            environment: context.env)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        // A chosen token account is an explicit identity; never swap in the CLI's account.
        guard context.sourceMode == .auto, context.selectedTokenAccountID == nil else { return false }
        guard let error = error as? ElevenLabsUsageError else { return false }
        return error == .missingCredentials || error == .invalidAPIKey
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.elevenLabsToken(environment: environment)
    }
}

struct ElevenLabsCLIFetchStrategy: ProviderFetchStrategy {
    let id: String = "elevenlabs.cli"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        _ = context
        // Stay available so a missing or signed-out CLI surfaces as actionable setup guidance.
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let usage = try await ElevenLabsCLIProbe().fetch(environment: context.env)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "cli")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
