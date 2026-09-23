import CodexBarCore
import Foundation

extension SettingsStore {
    var anthropicAdminAPIKey: String {
        get { self.configSnapshot.providerConfig(for: .anthropic)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .anthropic) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .anthropic, field: "apiKey", value: newValue)
        }
    }
}
