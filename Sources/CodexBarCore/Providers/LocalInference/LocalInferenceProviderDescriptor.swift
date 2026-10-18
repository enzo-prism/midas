import Foundation

/// Numeric runtime measurements received from an opted-in private collector.
/// This source has no provider login or quota. Verified model rates provide a hosted-value comparison.
public enum LocalInferenceProviderDescriptor {
    public static let descriptor = ProviderDescriptor(
        id: .localInference,
        metadata: ProviderMetadata(
            id: .localInference,
            displayName: "DGX Spark",
            sessionLabel: "Recorded tokens",
            weeklyLabel: "Recorded activity",
            opusLabel: nil,
            supportsOpus: false,
            supportsCredits: false,
            creditsHint: "",
            toggleTitle: "Show DGX Spark",
            cliName: "local-inference",
            defaultEnabled: false,
            isPrimaryProvider: false,
            usesAccountFallback: false,
            dashboardURL: nil,
            statusPageURL: nil),
        branding: ProviderBranding(
            iconStyle: .combined,
            iconResourceName: "ProviderIcon-nvidia",
            color: ProviderColor(red: 0.463, green: 0.725, blue: 0)),
        tokenCost: ProviderTokenCostConfig(
            supportsTokenCost: false,
            noDataMessage: { "Connect the DGX Spark collector in Settings → Sync." }),
        fetchPlan: ProviderFetchPlan(
            sourceModes: [.auto],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [] })),
        cli: ProviderCLIConfig(name: "local-inference", versionDetector: nil))
}
