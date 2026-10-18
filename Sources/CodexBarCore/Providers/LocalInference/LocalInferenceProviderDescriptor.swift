import Foundation

/// Numeric runtime measurements received from an opted-in private collector.
/// This source has no provider login, quota, or assumed API price.
public enum LocalInferenceProviderDescriptor {
    public static let descriptor = ProviderDescriptor(
        id: .localInference,
        metadata: ProviderMetadata(
            id: .localInference,
            displayName: "Local inference",
            sessionLabel: "Recorded tokens",
            weeklyLabel: "Recorded activity",
            opusLabel: nil,
            supportsOpus: false,
            supportsCredits: false,
            creditsHint: "",
            toggleTitle: "Show local inference",
            cliName: "local-inference",
            defaultEnabled: false,
            isPrimaryProvider: false,
            usesAccountFallback: false,
            dashboardURL: nil,
            statusPageURL: nil),
        branding: ProviderBranding(
            iconStyle: .combined,
            iconResourceName: "ProviderIcon-ollama",
            color: ProviderColor(red: 0.65, green: 0.65, blue: 0.65)),
        tokenCost: ProviderTokenCostConfig(
            supportsTokenCost: false,
            noDataMessage: { "Connect a local inference collector in Settings → Sync." }),
        fetchPlan: ProviderFetchPlan(
            sourceModes: [.auto],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [] })),
        cli: ProviderCLIConfig(name: "local-inference", versionDetector: nil))
}
