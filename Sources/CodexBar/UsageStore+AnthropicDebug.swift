import CodexBarCore
import Foundation

extension UsageStore {
    func anthropicAPIKeyDebugContext(processEnvironment: [String: String]) -> APIKeyDebugContext {
        let config = self.settings.providerConfig(for: .anthropic)
        let environment = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: processEnvironment,
            provider: .anthropic,
            config: config)
        return APIKeyDebugContext(
            label: "ANTHROPIC_ADMIN_KEY",
            resolution: ProviderTokenResolver.anthropicAdminAPIResolution(environment: environment),
            configToken: config?.sanitizedAPIKey,
            hasEnvToken: AnthropicSettingsReader.adminAPIKey(environment: processEnvironment) != nil,
            hasTokenAccount: self.settings.selectedTokenAccount(for: .anthropic) != nil)
    }
}
