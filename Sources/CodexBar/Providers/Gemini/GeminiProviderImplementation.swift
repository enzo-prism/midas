import CodexBarCore
import Foundation
import SwiftUI

struct GeminiProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .gemini
    let supportsLoginFlow: Bool = true

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.geminiUsageDataSource
        _ = settings.geminiAccountEmail
        _ = settings.tokenAccountsData(for: .gemini)
    }

    @MainActor
    func defaultSourceLabel(context: ProviderSourceLabelContext) -> String? {
        context.settings.geminiUsageDataSource.rawValue
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        switch context.settings.geminiUsageDataSource {
        case .auto: .auto
        case .cli: .cli
        case .oauth: .oauth
        case .api: .api
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let usageBinding = Binding(
            get: { context.settings.geminiUsageDataSource.rawValue },
            set: { raw in
                context.settings.geminiUsageDataSource = GeminiUsageDataSource(rawValue: raw) ?? .auto
            })
        let usageOptions = GeminiUsageDataSource.allCases.map {
            ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName)
        }
        return [
            ProviderSettingsPickerDescriptor(
                id: "gemini-usage-source",
                title: "Usage source",
                subtitle: "Auto checks Antigravity desktop first for shared five-hour and weekly Gemini limits.",
                binding: usageBinding,
                options: usageOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard context.settings.geminiUsageDataSource == .auto else { return nil }
                    let label = context.store.sourceLabel(for: .gemini)
                    return label == "auto" ? nil : label
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        let emailBinding = Binding(
            get: { context.settings.geminiAccountEmail },
            set: { context.settings.geminiAccountEmail = $0 })
        return [
            ProviderSettingsFieldDescriptor(
                id: "gemini-account-email",
                title: "Google account",
                subtitle: "Pin Gemini usage to one Google account email so other local sessions are ignored.",
                kind: .plain,
                placeholder: "name@gmail.com",
                binding: emailBinding,
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }

    @MainActor
    func settingsActions(context: ProviderSettingsContext) -> [ProviderSettingsActionsDescriptor] {
        let accountCount = context.settings.tokenAccounts(for: .gemini).count
        let loginTitle = accountCount > 0 ? "Add Google Account" : "Login with Google"
        return [
            ProviderSettingsActionsDescriptor(
                id: "gemini-oauth",
                title: "Google OAuth",
                subtitle: "Sign in with Google for background Gemini refreshes even when Antigravity is closed.",
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "gemini-oauth-login",
                        title: loginTitle,
                        style: .bordered,
                        isVisible: nil,
                        perform: {
                            await context.runLoginFlow()
                        }),
                ],
                isVisible: nil),
        ]
    }

    @MainActor
    func loginMenuAction(context _: ProviderMenuLoginContext) -> (label: String, action: MenuDescriptor.MenuAction)? {
        ("Add Account...", .switchAccount(.gemini))
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runGeminiLoginFlow()
        return false
    }
}
