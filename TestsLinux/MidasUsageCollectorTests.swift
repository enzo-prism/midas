import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

@Suite(.serialized)
struct MidasUsageCollectorTests {
    private static let now = Date(timeIntervalSince1970: 1_792_065_600)

    private struct Fixture {
        let root: URL
        let codex: URL
        let claude: URL
        let meta: URL
        let state: URL

        init() throws {
            self.root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("midas-collector-\(UUID().uuidString)", isDirectory: true)
            self.codex = self.root.appendingPathComponent("codex/sessions", isDirectory: true)
            self.claude = self.root.appendingPathComponent("claude/projects", isDirectory: true)
            self.meta = self.root.appendingPathComponent("meta/sessions", isDirectory: true)
            self.state = self.root.appendingPathComponent("state", isDirectory: true)
            for directory in [self.codex, self.claude, self.meta] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }

        var options: MidasUsageCollector.Options {
            MidasUsageCollector.Options(
                stateRoot: self.state,
                providers: [.codex, .claude, .meta],
                export: .init(
                    codexSessionsRoot: self.codex,
                    claudeProjectsRoots: [self.claude],
                    metaSessionsRoot: self.meta,
                    cacheRoot: self.state.appendingPathComponent("scan-cache", isDirectory: true),
                    codexTraceDatabaseURL: self.root.appendingPathComponent("absent-trace.sqlite"),
                    forceRescan: true))
        }

        func write(session: String) throws {
            let lines: [[String: Any]] = [
                ["type": "session_meta", "timestamp": "2026-10-13T10:00:00Z", "payload": ["id": session]],
                ["type": "turn_context", "timestamp": "2026-10-13T10:00:00Z", "payload": ["model": "gpt-5"]],
                [
                    "type": "event_msg",
                    "timestamp": "2026-10-13T10:00:00Z",
                    "payload": ["type": "task_started", "turn_id": "private-turn-\(session)"],
                ],
                [
                    "type": "event_msg",
                    "timestamp": "2026-10-13T10:00:00Z",
                    "prompt": "PRIVATE_PROMPT_MUST_NOT_SYNC",
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
            let folder = self.codex.appendingPathComponent("2026/10/13", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent(session + ".jsonl"))
        }

        func connection(_ name: String) -> MidasUsageHubConnection {
            MidasUsageHubConnection(
                endpoint: URL(string: "http://127.0.0.1:9876")!,
                deviceID: UUID(),
                deviceName: name,
                credential: String(repeating: "test-only-credential-", count: 3))
        }

        func remove() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }

    private actor Hub {
        let workspace = MidasUsageSyncWorkspace(createdAt: MidasUsageCollectorTests.now)
        var publications: [MidasUsageSyncPublication] = []
        var online = true
        var verifiedOutboxes = 0

        enum Offline: Error { case unavailable }

        func setOnline(_ value: Bool) {
            self.online = value
        }

        func getWorkspace() throws -> MidasUsageSyncWorkspace {
            guard self.online else { throw Offline.unavailable }
            return self.workspace
        }

        func exchange(
            local: MidasUsageSyncPublication, root: URL, now: Date) throws -> MidasUsageCollectorTransport.Exchange
        {
            let store = try MidasUsageCollectorStorage(root: root)
            let persisted: MidasUsageSyncPublication? = try store.load("outbox.json")
            #expect(persisted == local)
            self.verifiedOutboxes += 1
            guard self.online else { throw Offline.unavailable }
            self.publications = try MidasUsageSyncLedger(
                publications: self.publications + [local], workspaceID: self.workspace.id, now: now).publications
            return MidasUsageCollectorTransport.Exchange(
                workspace: self.workspace,
                publications: self.publications,
                publicationSucceeded: true,
                unavailableFiles: 0,
                rejectedFiles: 0)
        }

        nonisolated func transport(root: URL) -> MidasUsageCollectorTransport {
            MidasUsageCollectorTransport(
                workspace: { _ in try await self.getWorkspace() },
                exchange: { _, _, local, now in try await self.exchange(local: local, root: root, now: now) })
        }
    }

    @Test
    func threeDevicesReplayCopiedLogsOfflineRecoveryAndSameTotals() async throws {
        let fixtures = try (0..<3).map { _ in try Fixture() }
        defer { fixtures.forEach { $0.remove() } }
        let hub = Hub()
        let connections = fixtures.enumerated().map { $1.connection("Fixture device \($0)") }
        for (index, fixture) in fixtures.enumerated() {
            try fixture.write(session: "private-unique-session-\(index)")
            try fixture.write(session: "private-shared-session")
            let collector = MidasUsageCollector(options: fixture.options, transport: hub.transport(root: fixture.state))
            let status = try await collector.collect(connection: connections[index], now: Self.now)
            #expect(status.publicationSucceeded)
            #expect(status.localRecords == 2)
        }
        for (index, fixture) in fixtures.enumerated() {
            let collector = MidasUsageCollector(options: fixture.options, transport: hub.transport(root: fixture.state))
            _ = try await collector.collect(connection: connections[index], now: Self.now.addingTimeInterval(1))
            let store = try MidasUsageCollectorStorage(root: fixture.state)
            let cached: MidasUsageCollector.Received? = try store.load("received.json")
            let received = try #require(cached)
            let ledger = try MidasUsageSyncLedger(
                publications: received.publications, workspaceID: received.workspace.id, now: Self.now)
            #expect(ledger.publications.count == 3)
            #expect(ledger.snapshots[.codex]?.daily.first?.totalTokens == 480)
            #expect((ledger.snapshots[.codex]?.daily.first?.costUSD ?? 0) > 0)
            let text = try String(contentsOf: fixture.state.appendingPathComponent("outbox.json"), encoding: .utf8)
            #expect(!text.contains("PRIVATE_PROMPT"))
            #expect(!text.contains("private-unique-session"))
            #expect(!text.contains(connections[index].credential))
            let attributes = try FileManager.default.attributesOfItem(
                atPath: fixture.state.appendingPathComponent("outbox.json").path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        let fixture = fixtures[0]
        let collector = MidasUsageCollector(options: fixture.options, transport: hub.transport(root: fixture.state))
        await hub.setOnline(false)
        try fixture.write(session: "private-offline-session")
        let offline = try await collector.collect(connection: connections[0], now: Self.now.addingTimeInterval(2))
        #expect(offline.state == "offline")
        #expect(!offline.publicationSucceeded)
        #expect(offline.localRecords == 3)
        #expect(offline.devices == 3)
        try FileManager.default.removeItem(at: fixture.codex)
        let restarted = MidasUsageCollector(options: fixture.options, transport: hub.transport(root: fixture.state))
        let retained = try await restarted.collect(connection: connections[0], now: Self.now.addingTimeInterval(3))
        #expect(retained.localRecords == 3)
        await hub.setOnline(true)
        let synced = try await restarted.collect(connection: connections[0], now: Self.now.addingTimeInterval(4))
        #expect(synced.publicationSucceeded)
        let store = try MidasUsageCollectorStorage(root: fixture.state)
        let cached: MidasUsageCollector.Received? = try store.load("received.json")
        let received = try #require(cached)
        let ledger = try MidasUsageSyncLedger(
            publications: received.publications, workspaceID: received.workspace.id, now: Self.now)
        #expect(ledger.snapshots[.codex]?.daily.first?.totalTokens == 600)
        #expect(await hub.verifiedOutboxes == 9)
    }

    @Test
    func firstOfflineRunNeverInventsWorkspaceOrUsage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let hub = Hub()
        await hub.setOnline(false)
        let collector = MidasUsageCollector(options: fixture.options, transport: hub.transport(root: fixture.state))
        await #expect(throws: MidasUsageCollector.CollectorError.self) {
            try await collector.collect(connection: fixture.connection("Fixture device"), now: Self.now)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("outbox.json").path))
    }

    @Test
    func refusesChangedDeviceAndUnsafeState() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let hub = Hub()
        let collector = MidasUsageCollector(options: fixture.options, transport: hub.transport(root: fixture.state))
        _ = try await collector.collect(connection: fixture.connection("First"), now: Self.now)
        await #expect(throws: MidasUsageCollector.CollectorError.self) {
            try await collector.collect(connection: fixture.connection("Another device"), now: Self.now)
        }
        let outbox = fixture.state.appendingPathComponent("outbox.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: outbox.path)
        let store = try MidasUsageCollectorStorage(root: fixture.state)
        #expect(throws: MidasUsageSyncError.self) {
            let _: MidasUsageSyncPublication? = try store.load("outbox.json")
        }
    }

    @Test
    func monotonicPublicationClockWithTiesAndSmallClockReversal() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let hub = Hub()
        let connection = fixture.connection("Fixture device")
        let collector = MidasUsageCollector(options: fixture.options, transport: hub.transport(root: fixture.state))
        let store = try MidasUsageCollectorStorage(root: fixture.state)
        _ = try await collector.collect(connection: connection, now: Self.now)
        let firstCached: MidasUsageSyncPublication? = try store.load("outbox.json")
        let first = try #require(firstCached)
        _ = try await collector.collect(connection: connection, now: Self.now)
        let tiedCached: MidasUsageSyncPublication? = try store.load("outbox.json")
        let tied = try #require(tiedCached)
        #expect(tied.publishedAt > first.publishedAt)
        let earlier = Self.now.addingTimeInterval(-60)
        _ = try await collector.collect(connection: connection, now: earlier)
        let reversedCached: MidasUsageSyncPublication? = try store.load("outbox.json")
        let reversed = try #require(reversedCached)
        #expect(reversed.publishedAt > tied.publishedAt)
        #expect(reversed.publishedAt <= earlier.addingTimeInterval(300))
        await #expect(throws: MidasUsageSyncError.self) {
            try await collector.collect(connection: connection, now: Self.now.addingTimeInterval(-600))
        }
        let unchangedCached: MidasUsageSyncPublication? = try store.load("outbox.json")
        let unchanged = try #require(unchangedCached)
        #expect(unchanged == reversed)
    }

    @Test
    func rejectsUnknownProviders() throws {
        #expect(try MidasUsageCollector.parseProviders("codex, claude,codex") == [.claude, .codex])
        #expect(throws: MidasUsageCollector.CollectorError.self) {
            try MidasUsageCollector.parseProviders("codex,ollama")
        }
        #expect(throws: MidasUsageCollector.CollectorError.self) {
            try MidasUsageCollector.parseProviders("")
        }
    }
}
