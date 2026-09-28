import Foundation
import Testing
@testable import CodexBarCore

struct CodexOAuthRefreshCoordinatorTests {
    private actor Calls {
        private(set) var tokens: [String] = []

        func record(_ token: String) {
            self.tokens.append(token)
        }
    }

    private struct Home {
        let url: URL
        var env: [String: String] {
            ["CODEX_HOME": self.url.path]
        }

        var authURL: URL {
            self.url.appendingPathComponent("auth.json")
        }

        /// Writes credentials that need rotation: an opaque access token and no `last_refresh`.
        func writeExpired(refreshToken: String) throws {
            let json = #"{"tokens":{"access_token":"old-access","refresh_token":"\#(refreshToken)"}}"#
            try Data(json.utf8).write(to: self.authURL)
        }

        func stored() throws -> CodexOAuthCredentials {
            try CodexOAuthCredentialsStore.load(env: self.env)
        }
    }

    private func makeHome() throws -> Home {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-refresh-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Home(url: url)
    }

    private static func rotated(_ credentials: CodexOAuthCredentials, to token: String) -> CodexOAuthCredentials {
        CodexOAuthCredentials(
            accessToken: "access-\(token)",
            refreshToken: token,
            idToken: nil,
            accountId: credentials.accountId,
            lastRefresh: Date())
    }

    @Test
    func `concurrent callers share one rotation`() async throws {
        let home = try self.makeHome()
        defer { try? FileManager.default.removeItem(at: home.url) }
        try home.writeExpired(refreshToken: "refresh-1")
        let calls = Calls()
        let coordinator = CodexOAuthRefreshCoordinator { credentials in
            await calls.record(credentials.refreshToken)
            try await Task.sleep(for: .milliseconds(100))
            return Self.rotated(credentials, to: "refresh-2")
        }

        let results = try await withThrowingTaskGroup(of: CodexOAuthCredentials.self) { group in
            for _ in 0..<5 {
                group.addTask { try await coordinator.validCredentials(env: home.env) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(await calls.tokens == ["refresh-1"])
        #expect(results.map(\.refreshToken) == Array(repeating: "refresh-2", count: 5))
        #expect(try home.stored().refreshToken == "refresh-2")
    }

    @Test
    func `rotated credentials are not refreshed again`() async throws {
        let home = try self.makeHome()
        defer { try? FileManager.default.removeItem(at: home.url) }
        try home.writeExpired(refreshToken: "refresh-1")
        let calls = Calls()
        let coordinator = CodexOAuthRefreshCoordinator { credentials in
            await calls.record(credentials.refreshToken)
            return Self.rotated(credentials, to: "refresh-2")
        }

        _ = try await coordinator.validCredentials(env: home.env)
        let second = try await coordinator.validCredentials(env: home.env)

        #expect(await calls.tokens == ["refresh-1"])
        #expect(second.refreshToken == "refresh-2")
    }

    @Test
    func `cancelled caller still saves the rotated token`() async throws {
        let home = try self.makeHome()
        defer { try? FileManager.default.removeItem(at: home.url) }
        try home.writeExpired(refreshToken: "refresh-1")
        let calls = Calls()
        let coordinator = CodexOAuthRefreshCoordinator { credentials in
            await calls.record(credentials.refreshToken)
            // Model the server having rotated the token while the caller is cancelled.
            try? await Task.sleep(for: .milliseconds(150))
            return Self.rotated(credentials, to: "refresh-2")
        }

        let caller = Task { try await coordinator.validCredentials(env: home.env) }
        try await Task.sleep(for: .milliseconds(30))
        caller.cancel()
        _ = try? await caller.value

        #expect(try home.stored().refreshToken == "refresh-2")
        _ = try await coordinator.validCredentials(env: home.env)
        #expect(await calls.tokens == ["refresh-1"])
    }

    @Test
    func `reused token adopts credentials another client already saved`() async throws {
        let home = try self.makeHome()
        defer { try? FileManager.default.removeItem(at: home.url) }
        try home.writeExpired(refreshToken: "refresh-1")
        let coordinator = CodexOAuthRefreshCoordinator { credentials in
            // The Codex CLI rotates and saves first, so the server rejects our copy of the token.
            try CodexOAuthCredentialsStore.save(Self.rotated(credentials, to: "cli-refresh"), env: home.env)
            throw CodexTokenRefresher.RefreshError.reused
        }

        let credentials = try await coordinator.validCredentials(env: home.env)

        #expect(credentials.refreshToken == "cli-refresh")
        #expect(try home.stored().refreshToken == "cli-refresh")
    }

    @Test
    func `reused token without a newer saved token still fails`() async throws {
        let home = try self.makeHome()
        defer { try? FileManager.default.removeItem(at: home.url) }
        try home.writeExpired(refreshToken: "refresh-1")
        let coordinator = CodexOAuthRefreshCoordinator { _ in
            throw CodexTokenRefresher.RefreshError.reused
        }

        await #expect(throws: CodexTokenRefresher.RefreshError.self) {
            try await coordinator.validCredentials(env: home.env)
        }
        #expect(try home.stored().refreshToken == "refresh-1")
    }

    @Test
    func `separate auth files rotate independently`() async throws {
        let first = try self.makeHome()
        let second = try self.makeHome()
        defer {
            try? FileManager.default.removeItem(at: first.url)
            try? FileManager.default.removeItem(at: second.url)
        }
        try first.writeExpired(refreshToken: "first-1")
        try second.writeExpired(refreshToken: "second-1")
        let calls = Calls()
        let coordinator = CodexOAuthRefreshCoordinator { credentials in
            await calls.record(credentials.refreshToken)
            try await Task.sleep(for: .milliseconds(50))
            return Self.rotated(credentials, to: credentials.refreshToken.replacingOccurrences(of: "-1", with: "-2"))
        }

        async let a = coordinator.validCredentials(env: first.env)
        async let b = coordinator.validCredentials(env: second.env)
        let (firstResult, secondResult) = try await (a, b)

        #expect(firstResult.refreshToken == "first-2")
        #expect(secondResult.refreshToken == "second-2")
        #expect(await Set(calls.tokens) == ["first-1", "second-1"])
    }
}
