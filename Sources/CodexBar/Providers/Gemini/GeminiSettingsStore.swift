import CodexBarCore
import Foundation

extension SettingsStore {
    var geminiUsageDataSource: GeminiUsageDataSource {
        get {
            let source = self.configSnapshot.providerConfig(for: .gemini)?.source
            return Self.geminiUsageDataSource(from: source)
        }
        set {
            let source: ProviderSourceMode? = switch newValue {
            case .auto: .auto
            case .cli: .cli
            case .oauth: .oauth
            case .api: .api
            }
            self.updateProviderConfig(provider: .gemini) { entry in
                entry.source = source
            }
            self.logProviderModeChange(provider: .gemini, field: "usageSource", value: newValue.rawValue)
        }
    }

    var geminiAccountEmail: String {
        get {
            self.configSnapshot.providerConfig(for: .gemini)?.sanitizedAccountEmail ?? ""
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self.updateProviderConfig(provider: .gemini) { entry in
                entry.accountEmail = trimmed.isEmpty ? nil : trimmed
            }
        }
    }

    func upsertGeminiOAuthAccount(_ credentials: AntigravityOAuthCredentials) {
        guard let token = try? AntigravityOAuthCredentialsStore.tokenAccountValue(for: credentials) else { return }
        let trimmedEmail = credentials.resolvedAccountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = (trimmedEmail?.isEmpty == false) ? trimmedEmail : nil
        let data = self.tokenAccountsData(for: .gemini)
        let label = email ?? "Google Account \((data?.accounts.count ?? 0) + 1)"
        if let email,
           let data,
           let index = data.accounts.firstIndex(where: { account in
               account.externalIdentifier?.caseInsensitiveCompare(email) == .orderedSame
           })
        {
            let account = data.accounts[index]
            self.updateTokenAccount(
                provider: .gemini,
                accountID: account.id,
                label: label,
                token: token,
                externalIdentifier: .some(email))
            self.setActiveTokenAccountIndex(index, for: .gemini)
        } else {
            self.addTokenAccount(
                provider: .gemini,
                label: label,
                token: token,
                externalIdentifier: email)
        }
        if let email, self.geminiAccountEmail.isEmpty {
            self.geminiAccountEmail = email
        }
    }
}

extension SettingsStore {
    private static func geminiUsageDataSource(from source: ProviderSourceMode?) -> GeminiUsageDataSource {
        guard let source else { return .auto }
        switch source {
        case .auto, .web:
            return .auto
        case .cli:
            return .cli
        case .oauth:
            return .oauth
        case .api:
            return .api
        }
    }
}
