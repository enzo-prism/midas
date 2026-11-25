import CodexBarCore
import Foundation

extension SettingsStore {
    var elevenLabsAPIKey: String {
        get { self.configSnapshot.providerConfig(for: .elevenlabs)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .elevenlabs) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .elevenlabs, field: "apiKey", value: newValue)
        }
    }

    var elevenLabsUsageDataSource: ProviderSourceMode {
        get { self.configSnapshot.providerConfig(for: .elevenlabs)?.source ?? .auto }
        set {
            self.updateProviderConfig(provider: .elevenlabs) { entry in
                entry.source = newValue == .auto ? nil : newValue
            }
            self.logProviderModeChange(provider: .elevenlabs, field: "source", value: newValue.rawValue)
        }
    }
}
