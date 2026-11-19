import Foundation

public enum GeminiUsageDataSource: String, CaseIterable, Identifiable, Sendable {
    case auto
    case cli
    case oauth
    case api

    public var id: String {
        self.rawValue
    }

    public var displayName: String {
        switch self {
        case .auto: "Auto"
        case .cli: "Antigravity (local)"
        case .oauth: "Google OAuth"
        case .api: "Gemini CLI"
        }
    }
}

public enum GeminiSettingsReader {
    public static let accountEmailEnvironmentKey = "CODEXBAR_GEMINI_ACCOUNT_EMAIL"
    public static let fallbackAccountEmailEnvironmentKey = "GEMINI_ACCOUNT_EMAIL"
    public static let oauthCredentialsEnvironmentKey = "GEMINI_OAUTH_CREDENTIALS_JSON"

    public static func pinnedAccountEmail(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        for key in [self.accountEmailEnvironmentKey, self.fallbackAccountEmailEnvironmentKey] {
            if let value = cleanedEmail(environment[key]) {
                return value
            }
        }
        return nil
    }

    public static func selectedOAuthAccountEmail(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        guard let value = environment[self.oauthCredentialsEnvironmentKey],
              let credentials = AntigravityOAuthCredentialsStore.credentials(fromTokenAccountValue: value)
        else {
            return nil
        }
        return Self.cleanedEmail(credentials.resolvedAccountEmail)
    }

    /// Preferred Google account email to enforce across Gemini fetch strategies.
    /// An explicitly selected OAuth token account takes precedence over the configured pinned email.
    public static func expectedAccountEmail(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.selectedOAuthAccountEmail(environment: environment)
            ?? self.pinnedAccountEmail(environment: environment)
    }

    public static func cleanedEmail(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}

public enum GeminiAccountMatcher {
    public static func validate(reportedEmail: String?, expectedEmail: String?) throws {
        guard let expected = GeminiSettingsReader.cleanedEmail(expectedEmail) else { return }
        guard let found = GeminiSettingsReader.cleanedEmail(reportedEmail),
              found.caseInsensitiveCompare(expected) == .orderedSame
        else {
            throw GeminiStatusProbeError.accountMismatch(
                expected: expected,
                found: GeminiSettingsReader.cleanedEmail(reportedEmail))
        }
    }
}
