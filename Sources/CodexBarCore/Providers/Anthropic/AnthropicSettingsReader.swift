import Foundation

/// Reads the Anthropic Admin API key. Uses the same environment names as Claude's Admin API source.
public enum AnthropicSettingsReader {
    public static let adminAPIKeyEnvironmentKey = ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey
    public static let apiKeyEnvironmentKeys = ClaudeAdminAPISettingsReader.apiKeyEnvironmentKeys

    public static func adminAPIKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard var token = ClaudeAdminAPISettingsReader.apiKey(environment: environment) else { return nil }
        if token.lowercased().hasPrefix("bearer ") {
            token = String(token.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return token.isEmpty ? nil : token
    }
}

public enum AnthropicSettingsError: LocalizedError, Sendable {
    case missingToken

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "Anthropic Admin API key not configured. Set ANTHROPIC_ADMIN_KEY or add an Admin API key in Settings."
        }
    }
}
