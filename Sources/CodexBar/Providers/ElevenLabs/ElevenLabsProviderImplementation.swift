import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct ElevenLabsProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .elevenlabs

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.elevenLabsAPIKey
        _ = settings.elevenLabsUsageDataSource
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        context.settings.elevenLabsUsageDataSource
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        let source = context.settings.elevenLabsUsageDataSource
        if source != .cli {
            if ElevenLabsSettingsReader.apiKey(environment: context.environment) != nil {
                return true
            }
            if !context.settings.elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            if !context.settings.tokenAccounts(for: .elevenlabs).isEmpty {
                return true
            }
        }
        if source == .api {
            return false
        }
        // No shell probing here: this runs on the main actor during menu builds.
        return BinaryLocator.resolveElevenLabsBinary(
            env: context.environment,
            commandV: BinaryLocator.noShellCommandV,
            aliasResolver: BinaryLocator.noShellAlias) != nil
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let sourceBinding = Binding(
            get: { context.settings.elevenLabsUsageDataSource.rawValue },
            set: { raw in
                context.settings.elevenLabsUsageDataSource = ProviderSourceMode(rawValue: raw) ?? .auto
            })
        return [
            ProviderSettingsPickerDescriptor(
                id: "elevenlabs-usage-source",
                title: "Usage source",
                subtitle: "Auto uses an API key when one is set, otherwise the signed-in ElevenLabs CLI.",
                binding: sourceBinding,
                options: [
                    ProviderSettingsPickerOption(id: ProviderSourceMode.auto.rawValue, title: "Auto"),
                    ProviderSettingsPickerOption(id: ProviderSourceMode.cli.rawValue, title: "ElevenLabs CLI"),
                    ProviderSettingsPickerOption(id: ProviderSourceMode.api.rawValue, title: "API key"),
                ],
                isVisible: nil,
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "elevenlabs-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. Get your key from elevenlabs.io/app/settings/api-keys.",
                kind: .secure,
                placeholder: "xi-...",
                binding: context.stringBinding(\.elevenLabsAPIKey),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "elevenlabs-open-api-keys",
                        title: "Open ElevenLabs API Keys",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://elevenlabs.io/app/settings/api-keys") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: {
                    context.settings.elevenLabsUsageDataSource != .cli
                },
                onActivate: nil),
        ]
    }
}
