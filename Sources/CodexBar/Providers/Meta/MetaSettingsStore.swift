import CodexBarCore
import Foundation

extension SettingsStore {
    var metaAPIKey: String {
        get {
            self.configSnapshot.providerConfig(for: .meta)?.sanitizedAPIKey ?? ""
        }
        set {
            self.updateProviderConfig(provider: .meta) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .meta, field: "apiKey", value: newValue)
        }
    }
}
