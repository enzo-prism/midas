import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct MetaProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .meta

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "muse-log" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.metaAPIKey
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        // Local Muse session logs are the primary source; they need no credentials.
        // The API key is optional (Meta Model API) and also marks availability.
        if ProviderTokenResolver.metaToken(environment: context.environment) != nil {
            return true
        }
        if !context.settings.metaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return FileManager.default.fileExists(
            atPath: MuseSessionLogScanner.defaultSessionsRoot().path)
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "meta-api-key",
                title: "API key (optional)",
                subtitle: "Usage comes from local Muse logs. Optional META_API_KEY for the Meta Model API.",
                kind: .secure,
                placeholder: "metask_...",
                binding: context.stringBinding(\.metaAPIKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
