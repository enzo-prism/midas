import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
@MainActor
struct MidasUsageSyncAccountScopeTests {
    private static let now = Date(timeIntervalSince1970: 1_792_065_600)
    private static let timestamp = "2026-10-13T10:00:00Z"

    @Test
    func `shared account roots ignore display selection and normalize duplicate homes`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let expected = [fixture.firstHome, fixture.secondHome].map {
            $0.appendingPathComponent("sessions", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        }.map(\.path).sorted()
        for trackAll in [false, true] {
            fixture.settings.midasTrackAllAccounts = trackAll
            #expect(fixture.store.midasCodexSyncAdditionalSessionsRoots.map(\.path) == expected)
        }
    }

    @Test
    func `shared export includes both accounts and ambient logs with copied sessions counted once`() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(session: "ambient-session", to: fixture.ambient)
        try fixture.write(session: "first-account-session", to: fixture.firstHome.appendingPathComponent("sessions"))
        try fixture.write(session: "second-account-session", to: fixture.secondHome.appendingPathComponent("sessions"))
        try fixture.write(session: "second-account-session", to: fixture.ambient, name: "copied.jsonl")
        let workspace = MidasUsageSyncWorkspace()
        var priorEvents: [MidasUsageSyncEvent]?
        for trackAll in [false, true] {
            fixture.settings.midasTrackAllAccounts = trackAll
            let options = MidasUsageSyncExporter.Options(
                codexSessionsRoot: fixture.ambient,
                codexAdditionalSessionsRoots: fixture.store.midasCodexSyncAdditionalSessionsRoots,
                cacheRoot: fixture.root.appendingPathComponent("cache"),
                codexTraceDatabaseURL: fixture.root.appendingPathComponent("absent-trace.sqlite"),
                forceRescan: true)
            let exported = try await MidasUsageSyncExporter.export(
                workspace: workspace, providers: [.codex], now: Self.now, options: options)
            #expect(exported.events.count == 3)
            #expect(exported.events.reduce(0) { $0 + ($1.values.tokens ?? 0) } == 360)
            #expect(exported.excludedRecords == 0)
            if let priorEvents { #expect(exported.events == priorEvents) }
            priorEvents = exported.events
            let json = try #require(String(bytes: JSONEncoder().encode(exported.events), encoding: .utf8))
            #expect(!json.contains("@example.com"))
            #expect(!json.contains(fixture.root.path))
            #expect(!json.contains("private prompt"))
        }
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let ambient: URL
        let firstHome: URL
        let secondHome: URL
        let suite: String
        let settings: SettingsStore
        let store: UsageStore

        init() throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("midas-sync-accounts-\(UUID().uuidString)", isDirectory: true)
            self.ambient = self.root.appendingPathComponent("ambient/sessions", isDirectory: true)
            self.firstHome = self.root.appendingPathComponent("first", isDirectory: true)
            self.secondHome = self.root.appendingPathComponent("second", isDirectory: true)
            try FileManager.default.createDirectory(at: self.ambient, withIntermediateDirectories: true)
            let accounts = [
                Self.account(email: "first@example.com", home: self.firstHome.path),
                Self.account(email: "second@example.com", home: self.secondHome.path),
                Self.account(email: "duplicate@example.com", home: self.firstHome.path + "/../first"),
            ]
            self.suite = "MidasUsageSyncAccountScopeTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: self.suite)!
            self.settings = SettingsStore(
                userDefaults: defaults,
                configStore: testConfigStore(suiteName: self.suite),
                zaiTokenStore: NoopZaiTokenStore(),
                syntheticTokenStore: NoopSyntheticTokenStore())
            self.settings.refreshFrequency = .manual
            self.settings.statusChecksEnabled = false
            self.settings.providerDetectionCompleted = true
            self.settings._test_codexAccountSnapshotLoader = { source in
                CodexAccountReconciliationSnapshot(
                    storedAccounts: accounts,
                    activeStoredAccount: accounts.first,
                    liveSystemAccount: nil,
                    matchingStoredAccountForLiveSystemAccount: nil,
                    activeSource: source,
                    hasUnreadableAddedAccountStore: false)
            }
            self.settings.codexActiveSource = .managedAccount(id: accounts[0].id)
            self.store = UsageStore(
                fetcher: UsageFetcher(environment: [:]),
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: self.settings,
                startupBehavior: .testing,
                environmentBase: [:])
        }

        private static func account(email: String, home: String) -> ManagedCodexAccount {
            ManagedCodexAccount(
                id: UUID(),
                email: email,
                managedHomePath: home,
                createdAt: 1,
                updatedAt: 1,
                lastAuthenticatedAt: 1)
        }

        func write(session: String, to root: URL, name: String = "session.jsonl") throws {
            let folder = root.appendingPathComponent("2026/10/13", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let lines: [[String: Any]] = [
                ["type": "session_meta", "timestamp": Self.timestamp, "payload": ["id": session]],
                ["type": "turn_context", "timestamp": Self.timestamp, "payload": ["model": "gpt-5"]],
                [
                    "type": "event_msg",
                    "timestamp": Self.timestamp,
                    "payload": ["type": "task_started", "turn_id": "turn-\(session)"],
                ],
                [
                    "type": "event_msg",
                    "timestamp": Self.timestamp,
                    "prompt": "private prompt",
                    "payload": ["type": "token_count", "info": [
                        "total_token_usage": ["input_tokens": 100, "cached_input_tokens": 40, "output_tokens": 20],
                        "last_token_usage": ["input_tokens": 100, "cached_input_tokens": 40, "output_tokens": 20],
                    ]],
                ],
            ]
            var data = Data()
            for line in lines {
                try data.append(JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]))
                data.append(0x0A)
            }
            try data.write(to: folder.appendingPathComponent(name))
        }

        private static var timestamp: String {
            MidasUsageSyncAccountScopeTests.timestamp
        }

        func cleanup() {
            self.settings._test_codexAccountSnapshotLoader = nil
            UserDefaults(suiteName: self.suite)?.removePersistentDomain(forName: self.suite)
            try? FileManager.default.removeItem(at: self.root)
        }
    }
}
