import CodexBarCore
import SwiftUI

struct MidasAccountLabelOption: Identifiable {
    let id: String
    let identity: String
    let defaultLabel: String
}

extension SettingsStore {
    func midasAccountLabelOptions(for provider: UsageProvider) -> [MidasAccountLabelOption] {
        let identities: [(id: String, identity: String)]
        var defaults: [String: String] = [:]
        if provider == .codex {
            identities = self.codexVisibleAccountProjection.visibleAccounts.map { ($0.id, $0.displayName) }
        } else {
            let accounts = self.tokenAccounts(for: provider)
            identities = accounts.map { ($0.id.uuidString, $0.externalIdentifier ?? $0.label) }
            for account in accounts where account.externalIdentifier != nil && !account.label.contains("@") {
                defaults[provider.rawValue + ":" + account.id.uuidString] = account.label
            }
        }
        let names = MidasAccountNames.resolve(identities: identities, provider: provider, aliases: defaults)
        return identities.map {
            MidasAccountLabelOption(id: $0.id, identity: $0.identity, defaultLabel: names[$0.id] ?? "Account")
        }
    }

    func midasAccountLabel(for provider: UsageProvider, accountID: String) -> String {
        self.midasAccountAliases[provider.rawValue + ":" + accountID] ?? ""
    }

    func setMidasAccountLabel(_ label: String, for provider: UsageProvider, accountID: String) {
        let key = provider.rawValue + ":" + accountID
        var aliases = self.midasAccountAliases
        // Keep spaces while typing a multiword label; presentation trims the final value.
        let value = String(label.prefix(40))
        aliases[key] = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        self.midasAccountAliases = aliases
    }
}

struct MidasAccountLabelsSection: View {
    @Bindable var settings: SettingsStore
    let provider: UsageProvider

    var body: some View {
        ProviderSettingsSection(title: "Account labels") {
            if self.settings.hidePersonalInfo {
                Text("Turn off Hide personal info to edit account labels.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(self.settings.midasAccountLabelOptions(for: self.provider)) { account in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(account.identity).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(account.identity)
                        HStack {
                            TextField(
                                "Display label",
                                text: Binding(
                                    get: { self.settings.midasAccountLabel(for: self.provider, accountID: account.id) },
                                    set: {
                                        self.settings.setMidasAccountLabel(
                                            $0,
                                            for: self.provider,
                                            accountID: account.id)
                                    }),
                                prompt: Text(account.defaultLabel))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Display label for " + account.identity)
                                .accessibilityIdentifier("midas-account-label-" + self.provider.rawValue + account.id)
                            Button("Reset") {
                                self.settings.setMidasAccountLabel("", for: self.provider, accountID: account.id)
                            }
                            .disabled(self.settings.midasAccountLabel(for: self.provider, accountID: account.id)
                                .isEmpty)
                            .help("Use the default account label")
                        }
                    }
                }
                Text("Shown in the menu and account details. Leave blank to use the default name.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
