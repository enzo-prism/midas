import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ElevenLabsCLIProbeTests {
    private static let subscriptionBody = #"""
    {
      "tier": "pro",
      "character_count": 51500,
      "character_limit": 500000,
      "voice_slots_used": 6,
      "voice_limit": 30,
      "professional_voice_slots_used": 0,
      "professional_voice_limit": 1,
      "status": "active",
      "next_character_count_reset_unix": 1767225600
    }
    """#

    /// Captured from `elevenlabs user subscription get --format json` (CLI 1.12.2) after the OAuth
    /// session expired: exit code 2 with the error on stdout.
    private static let signedOutBody = #"""
    {
      "error": {
        "code": 401,
        "message": "Access denied. Authentication credentials are missing. \#
    Set keyring entry elevenlabs:OAuth (populated by `elevenlabs auth login`).",
        "reason": "authError"
      }
    }
    """#

    @Test
    func `parses the subscription body the CLI prints`() throws {
        let snapshot = try ElevenLabsCLIProbe.parse(
            stdout: Self.subscriptionBody,
            stderr: "",
            exitCode: 0,
            updatedAt: Date(timeIntervalSince1970: 1))
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.characterCount == 51500)
        #expect(snapshot.characterLimit == 500_000)
        #expect(abs((usage.primary?.usedPercent ?? 0) - 10.3) < 0.001)
        #expect(usage.primary?.resetDescription == "51,500 / 500,000 credits")
        #expect(usage.primary?.resetsAt == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(usage.loginMethod(for: .elevenlabs) == "Pro")
        #expect(usage.extraRateWindows?.map(\.id) == ["voice-slots", "professional-voices"])
    }

    @Test
    func `ignores notices printed around the JSON`() throws {
        let stdout = "Update available: 1.13.0\n\(Self.subscriptionBody)\n"
        let snapshot = try ElevenLabsCLIProbe.parse(
            stdout: stdout,
            stderr: "",
            exitCode: 0,
            updatedAt: Date())
        #expect(snapshot.characterCount == 51500)
    }

    @Test
    func `maps an expired OAuth session to signed out`() {
        #expect(throws: ElevenLabsUsageError.cliSignedOut) {
            try ElevenLabsCLIProbe.parse(
                stdout: Self.signedOutBody,
                stderr: "",
                exitCode: 2,
                updatedAt: Date())
        }
    }

    @Test
    func `maps an auth error written to stderr to signed out`() {
        #expect(throws: ElevenLabsUsageError.cliSignedOut) {
            try ElevenLabsCLIProbe.parse(
                stdout: "",
                stderr: "Error: not logged in. Run `elevenlabs auth login`.",
                exitCode: 1,
                updatedAt: Date())
        }
    }

    @Test
    func `reports other CLI failures with their message`() {
        #expect(throws: ElevenLabsUsageError.cliFailed("Service unavailable")) {
            try ElevenLabsCLIProbe.parse(
                stdout: #"{"error":{"code":503,"message":"Service unavailable","reason":"serverError"}}"#,
                stderr: "",
                exitCode: 1,
                updatedAt: Date())
        }
        #expect(throws: ElevenLabsUsageError.cliFailed("node: command not found")) {
            try ElevenLabsCLIProbe.parse(
                stdout: "",
                stderr: "node: command not found\n",
                exitCode: 127,
                updatedAt: Date())
        }
    }

    @Test
    func `command environment drops API keys and adds the login PATH`() {
        let environment = ElevenLabsCLIProbe.commandEnvironment(
            base: [
                "ELEVENLABS_API_KEY": "xi-test",
                "XI_API_KEY": "xi-other",
                "PATH": "/usr/bin:/bin",
                "HOME": "/Users/test",
            ],
            loginPATH: ["/opt/node/bin", "/usr/bin"])

        #expect(environment["ELEVENLABS_API_KEY"] == nil)
        #expect(environment["XI_API_KEY"] == nil)
        #expect(environment["HOME"] == "/Users/test")
        #expect(environment["NO_COLOR"] == "1")
        #expect(environment["PATH"] == "/opt/node/bin:/usr/bin:/bin")
    }

    @Test
    func `runs the CLI and reads a signed-out exit`() async throws {
        let script = try FakeCLI.make(name: "elevenlabs", body: """
        if [ -n "$ELEVENLABS_API_KEY" ]; then echo "key leaked" >&2; exit 9; fi
        if [ "$*" != "user subscription get --format json" ]; then echo "unexpected args: $*" >&2; exit 8; fi
        cat <<'JSON'
        \(Self.signedOutBody)
        JSON
        exit 2
        """)
        defer { script.remove() }

        await #expect(throws: ElevenLabsUsageError.cliSignedOut) {
            try await ElevenLabsCLIProbe().fetch(environment: [
                "ELEVENLABS_CLI_PATH": script.path,
                "ELEVENLABS_API_KEY": "xi-should-not-pass",
                "PATH": "/usr/bin:/bin",
            ])
        }
    }

    @Test
    func `runs the CLI and reads usage`() async throws {
        let script = try FakeCLI.make(name: "elevenlabs", body: """
        cat <<'JSON'
        \(Self.subscriptionBody)
        JSON
        """)
        defer { script.remove() }

        let snapshot = try await ElevenLabsCLIProbe().fetch(
            environment: ["ELEVENLABS_CLI_PATH": script.path, "PATH": "/usr/bin:/bin"],
            now: Date(timeIntervalSince1970: 5))
        #expect(snapshot.characterCount == 51500)
        #expect(snapshot.updatedAt == Date(timeIntervalSince1970: 5))
    }

    @Test
    func `auto tries an API key before the CLI`() async {
        let auto = await ElevenLabsProviderDescriptor.resolveStrategies(context: Self.context(.auto))
        let api = await ElevenLabsProviderDescriptor.resolveStrategies(context: Self.context(.api))
        let cli = await ElevenLabsProviderDescriptor.resolveStrategies(context: Self.context(.cli))

        #expect(auto.map(\.id) == ["elevenlabs.api", "elevenlabs.cli"])
        #expect(api.map(\.id) == ["elevenlabs.api"])
        #expect(cli.map(\.id) == ["elevenlabs.cli"])
        #expect(ElevenLabsProviderDescriptor.descriptor.fetchPlan.sourceModes == [.auto, .api, .cli])
    }

    @Test
    func `API strategy is skipped in auto without a key but kept in API mode`() async {
        let strategy = ElevenLabsAPIFetchStrategy()
        #expect(await strategy.isAvailable(Self.context(.auto)) == false)
        #expect(await strategy.isAvailable(Self.context(.api)) == true)
        #expect(await strategy.isAvailable(Self.context(.auto, env: ["ELEVENLABS_API_KEY": "xi-test"])) == true)
    }

    @Test
    func `a rejected key falls back to the CLI only in auto without a chosen account`() {
        let strategy = ElevenLabsAPIFetchStrategy()
        #expect(strategy.shouldFallback(on: ElevenLabsUsageError.invalidAPIKey, context: Self.context(.auto)))
        #expect(!strategy.shouldFallback(on: ElevenLabsUsageError.invalidAPIKey, context: Self.context(.api)))
        #expect(!strategy.shouldFallback(
            on: ElevenLabsUsageError.invalidAPIKey,
            context: Self.context(.auto, tokenAccount: UUID())))
        #expect(!strategy.shouldFallback(
            on: ElevenLabsUsageError.apiError("HTTP 500"),
            context: Self.context(.auto)))
    }

    private static func context(
        _ mode: ProviderSourceMode,
        env: [String: String] = [:],
        tokenAccount: UUID? = nil) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: mode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection,
            selectedTokenAccountID: tokenAccount)
    }
}

/// An executable `/bin/sh` script standing in for a provider CLI, in its own temporary folder.
struct FakeCLI {
    let directory: URL
    let path: String

    static func make(name: String, body: String) throws -> FakeCLI {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "midas-fake-cli-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return FakeCLI(directory: directory, path: url.path(percentEncoded: false))
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.directory)
    }
}
