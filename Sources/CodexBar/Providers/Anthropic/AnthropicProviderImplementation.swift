import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct AnthropicProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .anthropic

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.anthropicAdminAPIKey
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if AnthropicSettingsReader.adminAPIKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings.anthropicAdminAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "anthropic-admin-api-key",
                title: "Admin API key",
                subtitle: "Stored in ~/.codexbar/config.json. Reads organization cost and usage reports; " +
                    "ANTHROPIC_ADMIN_KEY also works. Claude subscription limits stay in the Claude provider.",
                kind: .secure,
                placeholder: "sk-ant-admin...",
                binding: context.stringBinding(\.anthropicAdminAPIKey),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "anthropic-open-admin-keys",
                        title: "Open Admin keys",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://console.anthropic.com/settings/admin-keys") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                    ProviderSettingsActionDescriptor(
                        id: "anthropic-open-billing",
                        title: "Open billing",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://console.anthropic.com/settings/billing") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
