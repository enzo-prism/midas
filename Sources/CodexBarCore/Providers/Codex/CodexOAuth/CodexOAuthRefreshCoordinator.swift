import Foundation

/// Serializes Codex OAuth token rotation per `auth.json`.
///
/// Refresh tokens are single-use: two concurrent refreshes of the same file spend the same token, and the loser
/// gets `refresh_token_reused`. Callers for one file join a single in-flight rotation, which runs in its own task so
/// a cancelled caller cannot drop a token the server has already rotated before it is saved.
public actor CodexOAuthRefreshCoordinator {
    public typealias Refresh = @Sendable (CodexOAuthCredentials) async throws -> CodexOAuthCredentials

    public static let shared = CodexOAuthRefreshCoordinator()

    private let refresh: Refresh
    private var inFlight: [String: Task<CodexOAuthCredentials, Error>] = [:]

    public init(refresh: @escaping Refresh = { try await CodexTokenRefresher.refresh($0) }) {
        self.refresh = refresh
    }

    /// Loads the credentials for `env`, rotating them first when the access token is about to expire.
    public func validCredentials(env: [String: String]) async throws -> CodexOAuthCredentials {
        let credentials = try CodexOAuthCredentialsStore.load(env: env)
        guard credentials.needsRefresh, !credentials.refreshToken.isEmpty else { return credentials }

        let key = CodexOAuthCredentialsStore.authFilePath(env: env).standardizedFileURL.path
        if let running = self.inFlight[key] {
            return try await running.value
        }
        let refresh = self.refresh
        let task = Task { try await Self.rotate(env: env, refresh: refresh) }
        self.inFlight[key] = task
        defer {
            if self.inFlight[key] == task { self.inFlight[key] = nil }
        }
        return try await task.value
    }

    private static func rotate(env: [String: String], refresh: Refresh) async throws -> CodexOAuthCredentials {
        // Re-read under the single flight: an earlier rotation, or the Codex CLI, may already have refreshed the file.
        let current = try CodexOAuthCredentialsStore.load(env: env)
        guard current.needsRefresh, !current.refreshToken.isEmpty else { return current }
        do {
            let refreshed = try await refresh(current)
            try CodexOAuthCredentialsStore.save(refreshed, env: env)
            return refreshed
        } catch CodexTokenRefresher.RefreshError.reused {
            // Another client spent this token after we read it. Adopt its result if it has saved one.
            if let latest = try? CodexOAuthCredentialsStore.load(env: env),
               latest.refreshToken != current.refreshToken,
               !latest.needsRefresh
            {
                return latest
            }
            throw CodexTokenRefresher.RefreshError.reused
        }
    }
}
