import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct MidasUsageSyncExporterTests {
    private struct Fixture {
        let root: URL
        let codex: URL
        let claude: URL
        let meta: URL
        let cache: URL

        init() throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "midas-sync-export-\(UUID().uuidString)",
                    isDirectory: true)
            self.codex = self.root.appendingPathComponent(
                "codex/sessions",
                isDirectory: true)
            self.claude = self.root.appendingPathComponent(
                "claude/projects",
                isDirectory: true)
            self.meta = self.root.appendingPathComponent(
                "muse/sessions",
                isDirectory: true)
            self.cache = self.root.appendingPathComponent(
                "cache",
                isDirectory: true)
            for folder in [self.codex, self.claude, self.meta, self.cache] {
                try FileManager.default.createDirectory(
                    at: folder,
                    withIntermediateDirectories: true)
            }
        }

        var options: MidasUsageSyncExporter.Options {
            MidasUsageSyncExporter.Options(
                codexSessionsRoot: self.codex,
                claudeProjectsRoots: [self.claude],
                metaSessionsRoot: self.meta,
                cacheRoot: self.cache,
                codexTraceDatabaseURL: self.root.appendingPathComponent("absent-trace.sqlite"))
        }

        func write(_ lines: [[String: Any]], at url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let body = try lines.map { try JSONSerialization.data(
                withJSONObject: $0,
                options: [.sortedKeys]) }
            var data = Data()
            for line in body {
                data.append(line)
                data.append(0x0A)
            }
            try data.write(to: url)
        }

        func remove() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }

    private static let now = Date(timeIntervalSince1970: 1_792_065_600) // 2026-10-15 12:00 UTC
    private static let timestamp = "2026-10-13T10:00:00Z"

    private static func codexLines(
        session: String = "private-session-id",
        turn: String? = "private-turn-id",
        timestamp: String = Self.timestamp) -> [[String: Any]]
    {
        var lines: [[String: Any]] = [
            [
                "type": "session_meta",
                "timestamp": timestamp,
                "payload": ["id": session, "cwd": "/private/project/location"],
            ],
            ["type": "turn_context", "timestamp": timestamp, "payload": ["model": "gpt-5"]],
        ]
        if let turn {
            lines.append([
                "type": "event_msg",
                "timestamp": timestamp,
                "payload": ["type": "task_started", "turn_id": turn],
            ])
        }
        lines.append([
            "type": "event_msg", "timestamp": timestamp,
            "prompt": "private prompt must never leave the computer",
            "payload": ["type": "token_count", "info": [
                "total_token_usage": ["input_tokens": 100, "cached_input_tokens": 40, "output_tokens": 20],
                "last_token_usage": ["input_tokens": 100, "cached_input_tokens": 40, "output_tokens": 20],
            ]],
        ])
        return lines
    }

    private static func claudeLine(
        output: Int,
        message: String? = "private-message-id",
        request: String? = "private-request-id",
        timestamp: String? = Self.timestamp) -> [String: Any]
    {
        var content: [String: Any] = [
            "model": "claude-sonnet-4-5-20250929",
            "content": "private Claude prompt",
            "usage": [
                "input_tokens": 100,
                "cache_read_input_tokens": 40,
                "cache_creation_input_tokens": 10,
                "output_tokens": output,
            ],
        ]
        if let message { content["id"] = message }
        var line: [String: Any] = ["type": "assistant", "sessionId": "private-claude-session", "message": content]
        if let request { line["requestId"] = request }
        if let timestamp { line["timestamp"] = timestamp }
        return line
    }

    private static func metaLine(
        recordID: String? = "private-meta-record-id",
        timestamp: Int? = 1_792_051_200_000_000) -> [String: Any]
    {
        var line: [String: Any] = [
            "payload_type": "runtime.session", "stream": ["id": "private-meta-stream-id"], "sequence": 3,
            "payload": ["event": [
                "kind": "model_completed",
                "model": "muse-spark-1.3-contributor",
                "usage": [
                    "input_tokens": 100,
                    "output_tokens": 20,
                    "reasoning_tokens": 5,
                    "cache_read_tokens": 40,
                ],
            ]],
        ]
        if let recordID { line["id"] = recordID }
        if let timestamp { line["recorded_at"] = timestamp }
        return line
    }

    @Test
    func `Codex copied logs export identical opaque event IDs without private content`() async throws {
        let first = try Fixture()
        let second = try Fixture()
        defer { first.remove(); second.remove() }
        try first.write(
            Self.codexLines(),
            at: first.codex.appendingPathComponent("2026/10/13/session.jsonl"))
        try second.write(
            Self.codexLines(),
            at: second.codex.appendingPathComponent("2026/10/13/copied.jsonl"))
        let workspace = MidasUsageSyncWorkspace()
        let one = try await MidasUsageSyncExporter.export(
            workspace: workspace,
            providers: [.codex],
            now: Self.now,
            options: first.options)
        let two = try await MidasUsageSyncExporter.export(
            workspace: workspace,
            providers: [.codex],
            now: Self.now,
            options: second.options)
        #expect(one.events.count == 1)
        #expect(one.events == two.events)
        #expect(one.events.first?.values.tokens == 120)
        #expect(one.events.first?.values.tokenMix.inputTokens == 100)
        #expect(one.events.first?.values.tokenMix.cacheReadTokens == 40)
        #expect(one.excludedRecords == 0)
        let publication = MidasUsageSyncPublication(
            workspaceID: workspace.id,
            deviceID: UUID(),
            deviceName: "Test Mac",
            publishedAt: Self.now,
            events: one.events)
        try publication.validate(
            workspaceID: workspace.id,
            now: Self.now)
        let data = try JSONEncoder().encode(publication)
        let json = try #require(String(bytes: data, encoding: .utf8))
        #expect(!json.contains("private-session-id"))
        #expect(!json.contains("private-turn-id"))
        #expect(!json.contains("private prompt"))
        #expect(!json.contains("/private/project/location"))
        #expect(!json.contains(first.root.path))
        let otherWorkspace = try await MidasUsageSyncExporter.export(
            workspace: MidasUsageSyncWorkspace(),
            providers: [.codex],
            now: Self.now,
            options: first.options)
        #expect(otherWorkspace.events.first?.id != one.events.first?.id)
    }

    @Test
    func `Codex incremental refresh retains old events and exports only new deltas`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.codex.appendingPathComponent("2026/10/13/session.jsonl")
        var lines = Self.codexLines()
        try fixture.write(
            lines,
            at: file)
        let workspace = MidasUsageSyncWorkspace()
        let initial = try await MidasUsageSyncExporter.export(
            workspace: workspace,
            providers: [.codex],
            now: Self.now,
            options: fixture.options)
        lines.append([
            "type": "event_msg", "timestamp": "2026-10-13T10:01:00Z",
            "payload": ["type": "token_count", "info": [
                "total_token_usage": ["input_tokens": 180, "cached_input_tokens": 50, "output_tokens": 35],
                "last_token_usage": ["input_tokens": 80, "cached_input_tokens": 10, "output_tokens": 15],
            ]],
        ])
        try fixture.write(
            lines,
            at: file)
        let appended = try await MidasUsageSyncExporter.export(
            workspace: workspace,
            providers: [.codex],
            now: Self.now.addingTimeInterval(1),
            options: fixture.options)
        #expect(initial.events.count == 1)
        #expect(appended.events.count == 2)
        #expect(appended.events.reduce(0) { $0 + ($1.values.tokens ?? 0) } == 215)
        #expect(appended.events.contains { $0.id == initial.events.first?.id })
        let repeated = try await MidasUsageSyncExporter.export(
            workspace: workspace,
            providers: [.codex],
            now: Self.now.addingTimeInterval(2),
            options: fixture.options)
        #expect(repeated.events == appended.events)
    }

    @Test
    func `Claude final streaming chunk and mirrored subagent records count once`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            [Self.claudeLine(output: 10), Self.claudeLine(output: 20)],
            at: fixture.claude.appendingPathComponent("project/session.jsonl"))
        try fixture.write(
            [Self.claudeLine(output: 20)],
            at: fixture.claude.appendingPathComponent("project/subagents/copy.jsonl"))
        let result = try await MidasUsageSyncExporter.export(
            workspace: MidasUsageSyncWorkspace(),
            providers: [.claude],
            now: Self.now,
            options: fixture.options)
        #expect(result.events.count == 1)
        #expect(result.events.first?.values.tokens == 170)
        #expect(result.events.first?.values.requests == 1)
        #expect(result.events.first?.values.costUSD != nil)
        #expect(result.excludedRecords == 0)
    }

    @Test
    func `Default sync cache remains isolated from ordinary narrow Claude scans`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cachesDirectory = fixture.root.appendingPathComponent("caches", isDirectory: true)
        let normalRoot = cachesDirectory.appendingPathComponent(MidasIdentity.supportDirectoryName, isDirectory: true)
        var defaults = fixture.options
        defaults.cacheRoot = nil
        let options = MidasUsageSyncExporter.resolvingCacheRoot(defaults, cachesDirectory: cachesDirectory)
        let syncRoot = try #require(options.cacheRoot)
        #expect(syncRoot == normalRoot.appendingPathComponent("usage-sync-scan", isDirectory: true))
        #expect(MidasUsageSyncExporter.resolvingCacheRoot(fixture.options).cacheRoot == fixture.cache)
        let oldTimestamp = ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(-100 * 86400))
        try fixture.write([
            Self.claudeLine(output: 20, message: "old", request: "old", timestamp: oldTimestamp),
            Self.claudeLine(output: 20),
        ], at: fixture.claude.appendingPathComponent("project/session.jsonl"))
        let workspace = MidasUsageSyncWorkspace()
        // Passing the resolved temporary root deliberately keeps this fixture free of network requests.
        let first = try await MidasUsageSyncExporter.export(
            workspace: workspace, providers: [.claude], now: Self.now, options: options)
        #expect(first.events.count == 2)
        let syncFile = CostUsageCacheIO.cacheFileURL(provider: .claude, cacheRoot: syncRoot)
        let original = try Data(contentsOf: syncFile)
        let normalOptions = CostUsageScanner.Options(claudeProjectsRoots: [fixture.claude], cacheRoot: normalRoot)
        _ = try CostUsageScanner.loadDailyReportCancellable(
            provider: .claude,
            since: Self.now.addingTimeInterval(-29 * 86400),
            until: Self.now,
            now: Self.now,
            options: normalOptions,
            checkCancellation: nil)
        #expect(try Data(contentsOf: syncFile) == original)
        let normalCache = CostUsageCacheIO.load(provider: .claude, cacheRoot: normalRoot)
        let syncCache = CostUsageCacheIO.load(provider: .claude, cacheRoot: syncRoot)
        #expect(try #require(syncCache.scanSinceKey) < #require(normalCache.scanSinceKey))
        let repeated = try await MidasUsageSyncExporter.export(
            workspace: workspace, providers: [.claude], now: Self.now.addingTimeInterval(1), options: options)
        #expect(repeated.events == first.events)
        #expect(try Data(contentsOf: syncFile) == original)
    }

    @Test
    func `Legacy usage without stable identity or timestamp is excluded visibly`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var codex = Self.codexLines(turn: nil)
        var missingTimestamp = try #require(codex.last)
        missingTimestamp.removeValue(forKey: "timestamp")
        codex.append(missingTimestamp)
        try fixture.write(
            codex,
            at: fixture.codex.appendingPathComponent("2026/10/13/legacy.jsonl"))
        try fixture.write(
            [Self.claudeLine(
                output: 20,
                message: nil), Self.claudeLine(
                output: 20,
                timestamp: nil)],
            at: fixture.claude.appendingPathComponent("project/legacy.jsonl"))
        try fixture.write(
            [Self.metaLine(recordID: nil), Self.metaLine(timestamp: nil)],
            at: fixture.meta.appendingPathComponent("project/session.jsonl"))
        let result = try await MidasUsageSyncExporter.export(
            workspace: MidasUsageSyncWorkspace(),
            now: Self.now,
            options: fixture.options)
        #expect(result.events.isEmpty)
        #expect(result.excludedRecords == 6)
    }

    @Test
    func `Meta retained frames and copied records share stable identity and existing pricing`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = Self.metaLine()
        let recordData = try JSONSerialization.data(withJSONObject: record)
        let recordString = try #require(String(bytes: recordData, encoding: .utf8))
        let retained: [String: Any] = ["retained_frame": "transaction", "children": [["record_json": recordString]]]
        try fixture.write(
            [record, retained],
            at: fixture.meta.appendingPathComponent("one/session.jsonl"))
        try fixture.write(
            [record],
            at: fixture.meta.appendingPathComponent("two/session.jsonl"))
        let result = try await MidasUsageSyncExporter.export(
            workspace: MidasUsageSyncWorkspace(),
            providers: [.meta],
            now: Self.now,
            options: fixture.options)
        #expect(result.events.count == 1)
        #expect(result.events.first?.values.tokens == 125)
        #expect(result.events.first?.values.costUSD != nil)
        #expect(result.events.first?.values.apiEquivalentCostUSD != nil)
        #expect(result.events.first?.values.provenance == .listPriceEstimate)
        #expect(result.events.first?.values.tokenMix.inputTokens == 100)
        #expect(result.events.first?.values.tokenMix.reasoningTokens == 5)
        #expect(result.excludedRecords == 0)
    }

    @Test
    func `Meta candidate filtering preserves escaped usage and malformed line exclusions`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.meta.appendingPathComponent("candidate/session.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var body = Data()
        func append(_ line: Data) {
            body.append(line)
            body.append(0x0A)
        }
        func encode(_ record: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        }
        func recordText(_ id: String, escaped: Bool) throws -> String {
            let value = try #require(String(bytes: encode(Self.metaLine(recordID: id)), encoding: .utf8))
            return escaped ? value.replacingOccurrences(of: "model_completed", with: #"model\u005fcompleted"#) : value
        }
        try append(encode(["payload": ["text": String(repeating: "unrelated transcript text ", count: 10000)]]))
        try append(encode(Self.metaLine(recordID: "direct")))
        try append(encode([
            "retained_frame": "transaction",
            "children": [["record_json": recordText("retained", escaped: false)]],
        ]))
        try append(Data(recordText("escaped-direct", escaped: true).utf8))
        try append(encode([
            "retained_frame": "transaction",
            "children": [["record_json": recordText("escaped-retained", escaped: true)]],
        ]))
        var bad = Self.metaLine(recordID: "bad-counter")
        var payload = try #require(bad["payload"] as? [String: Any])
        var event = try #require(payload["event"] as? [String: Any])
        var usage = try #require(event["usage"] as? [String: Any])
        usage["input_tokens"] = -1
        event["usage"] = usage
        payload["event"] = event
        bad["payload"] = payload
        try append(encode(bad))
        append(Data([0xFF]))
        append(Data(repeating: 0x78, count: MuseSessionLogScanner.maxLineBytes + 1))
        try body.write(to: file)

        let result = try await MidasUsageSyncExporter.export(
            workspace: MidasUsageSyncWorkspace(),
            providers: [.meta],
            now: Self.now,
            options: fixture.options)
        #expect(result.events.count == 4)
        #expect(result.events.reduce(0) { $0 + ($1.values.tokens ?? 0) } == 500)
        #expect(result.excludedRecords == 3)
    }

    @Test
    func `UTC day derives from source offset and history window omits older events`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            Self.codexLines(timestamp: "2026-10-12T23:30:00-07:00"),
            at: fixture.codex.appendingPathComponent("2026/10/13/current.jsonl"))
        try fixture.write(
            Self.codexLines(
                session: "older-session",
                timestamp: "2025-01-01T00:00:00Z"),
            at: fixture.codex.appendingPathComponent("2025/01/01/old.jsonl"))
        var options = fixture.options
        options.forceRescan = true
        let result = try await MidasUsageSyncExporter.export(
            workspace: MidasUsageSyncWorkspace(),
            providers: [.codex],
            now: Self.now,
            options: options)
        #expect(result.events.count == 1)
        #expect(result.events.first?.day == "2026-10-13")
    }

    @Test
    func `Codex timestamp collisions are excluded instead of losing or duplicating usage`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var lines = Self.codexLines()
        lines.append([
            "type": "event_msg", "timestamp": Self.timestamp,
            "payload": ["type": "token_count", "info": [
                "total_token_usage": ["input_tokens": 180, "cached_input_tokens": 50, "output_tokens": 35],
                "last_token_usage": ["input_tokens": 80, "cached_input_tokens": 10, "output_tokens": 15],
            ]],
        ])
        try fixture.write(lines, at: fixture.codex.appendingPathComponent("2026/10/13/collision.jsonl"))
        let result = try await MidasUsageSyncExporter.export(
            workspace: MidasUsageSyncWorkspace(),
            providers: [.codex],
            now: Self.now,
            options: fixture.options)
        #expect(result.events.isEmpty)
        #expect(result.excludedRecords == 2)
    }

    @Test
    func `Unknown Meta model keeps tokens but exports neither invented cost nor arbitrary model text`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var record = Self.metaLine()
        var payload = try #require(record["payload"] as? [String: Any])
        var event = try #require(payload["event"] as? [String: Any])
        event["model"] = "private arbitrary string"
        payload["event"] = event
        record["payload"] = payload
        try fixture.write([record], at: fixture.meta.appendingPathComponent("one/session.jsonl"))
        let result = try await MidasUsageSyncExporter.export(
            workspace: MidasUsageSyncWorkspace(),
            providers: [.meta],
            now: Self.now,
            options: fixture.options)
        #expect(result.events.count == 1)
        #expect(result.events.first?.values.tokens == 125)
        #expect(result.events.first?.values.costUSD == nil)
        #expect(result.events.first?.values.apiEquivalentCostUSD == nil)
        #expect(result.events.first?.values.model == nil)
        #expect(result.events.first?.values.unpricedRequests == 1)
    }

    @Test
    func `Byte cap rolls the older provider day into totals instead of excluding records`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let newestTimestamp = 1_792_051_200_000_000
        let newest = Self.metaLine(recordID: "newest", timestamp: newestTimestamp)
        let oldest = Self.metaLine(recordID: "oldest", timestamp: newestTimestamp - 7200 * 1_000_000)
        let middle = Self.metaLine(recordID: "middle", timestamp: newestTimestamp - 3600 * 1_000_000)
        try fixture.write([newest, oldest, middle], at: fixture.meta.appendingPathComponent("one/session.jsonl"))
        let workspace = MidasUsageSyncWorkspace()
        let full = try await MidasUsageSyncExporter.export(
            workspace: workspace,
            providers: [.meta],
            now: Self.now,
            options: fixture.options)
        #expect(full.events.count == 3)
        let singleEventBytes = try full.events.map { try JSONEncoder().encode($0).count + 1 }.max() ?? 0
        var options = fixture.options
        options.maximumEventBytes = singleEventBytes + 16
        let limited = try await MidasUsageSyncExporter.export(
            workspace: workspace,
            providers: [.meta],
            now: Self.now,
            options: options)
        // All three share one UTC day, so the whole day is published as one rollup with the same totals.
        #expect(limited.events.count == 1)
        #expect(limited.events.allSatisfy { MidasUsageSyncRollup.isRollup($0, deviceID: nil) })
        #expect(limited.events.first?.observedAt == Date(timeIntervalSince1970: Double(newestTimestamp) / 1_000_000))
        #expect(limited.events.first?.values.tokens == full.events.reduce(0) { $0 + ($1.values.tokens ?? 0) })
        #expect(limited.events.first?.values.requests == full.events.reduce(0) { $0 + ($1.values.requests ?? 0) })
        #expect(limited.excludedRecords == 0)
    }

    @Test
    func `Byte cap keeps an updated event complete and ignores its later copied prefix`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let timestamp = 1_792_051_200_000_000
        let prefix = Self.metaLine(recordID: "growing", timestamp: timestamp - 7200 * 1_000_000)
        let middle = Self.metaLine(recordID: "middle", timestamp: timestamp - 3600 * 1_000_000)
        let newer = Self.metaLine(recordID: "newer", timestamp: timestamp - 1800 * 1_000_000)
        var complete = Self.metaLine(recordID: "growing", timestamp: timestamp)
        var payload = try #require(complete["payload"] as? [String: Any])
        var event = try #require(payload["event"] as? [String: Any])
        var usage = try #require(event["usage"] as? [String: Any])
        usage["output_tokens"] = 200
        event["usage"] = usage
        payload["event"] = event
        complete["payload"] = payload
        try fixture.write([prefix, middle, complete, newer, prefix], at: fixture.meta.appendingPathComponent(
            "one/session.jsonl"))
        let workspace = MidasUsageSyncWorkspace()
        let full = try await MidasUsageSyncExporter.export(
            workspace: workspace, providers: [.meta], now: Self.now, options: fixture.options)
        #expect(full.events.count == 3)
        let sizes = try full.events.map { try JSONEncoder().encode($0).count + 1 }.sorted()
        var options = fixture.options
        options.maximumEventBytes = sizes.suffix(2).reduce(0, +) + 8
        let limited = try await MidasUsageSyncExporter.export(
            workspace: workspace, providers: [.meta], now: Self.now, options: options)
        #expect(limited.events.allSatisfy { MidasUsageSyncRollup.isRollup($0, deviceID: nil) })
        #expect(limited.events.reduce(0) { $0 + ($1.values.tokens ?? 0) }
            == full.events.reduce(0) { $0 + ($1.values.tokens ?? 0) })
        #expect(limited.excludedRecords == 0)
    }

    @Test
    func `Malformed local numeric counters are excluded before any pricing conversion or addition`() async throws {
        let invalid: [Any] = [Int.max, 1e100, -1, 1.5, true]
        for provider in [UsageProvider.codex, .claude, .meta] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            switch provider {
            case .codex:
                var lines = Self.codexLines()
                for (index, number) in invalid.enumerated() {
                    var bad = try #require(Self.codexLines().last)
                    var payload = try #require(bad["payload"] as? [String: Any])
                    var info = try #require(payload["info"] as? [String: Any])
                    let usage: [String: Any] = ["input_tokens": number, "cached_input_tokens": 0, "output_tokens": 5]
                    info["last_token_usage"] = usage
                    info["total_token_usage"] = usage
                    payload["info"] = info
                    bad["payload"] = payload
                    bad["timestamp"] = "2026-10-13T10:01:0\(index)Z"
                    lines.append(bad)
                }
                try fixture.write(lines, at: fixture.codex.appendingPathComponent("2026/10/13/malformed.jsonl"))
            case .claude:
                var lines = [Self.claudeLine(output: 20)]
                for (index, number) in invalid.enumerated() {
                    var bad = Self.claudeLine(
                        output: 20,
                        message: "bad-message-\(index)",
                        request: "bad-request-\(index)")
                    var message = try #require(bad["message"] as? [String: Any])
                    var usage = try #require(message["usage"] as? [String: Any])
                    usage["input_tokens"] = number
                    message["usage"] = usage
                    bad["message"] = message
                    lines.append(bad)
                }
                try fixture.write(lines, at: fixture.claude.appendingPathComponent("project/malformed.jsonl"))
            case .meta:
                var lines = [Self.metaLine()]
                for (index, number) in invalid.enumerated() {
                    var bad = Self.metaLine(recordID: "bad-record-\(index)")
                    var payload = try #require(bad["payload"] as? [String: Any])
                    var event = try #require(payload["event"] as? [String: Any])
                    var usage = try #require(event["usage"] as? [String: Any])
                    usage["input_tokens"] = number
                    event["usage"] = usage
                    payload["event"] = event
                    bad["payload"] = payload
                    lines.append(bad)
                }
                try fixture.write(lines, at: fixture.meta.appendingPathComponent("project/session.jsonl"))
            default:
                break
            }
            let result = try await MidasUsageSyncExporter.export(
                workspace: MidasUsageSyncWorkspace(),
                providers: [provider],
                now: Self.now,
                options: fixture.options)
            #expect(result.events.count == 1)
            #expect(result.excludedRecords == invalid.count)
            #expect(result.events.first?.values.tokens == (provider == .codex ? 120 : provider == .claude ? 170 : 125))
        }
    }

    @Test
    func `Repeated extreme Claude rows keep exact numeric USD when private nanosecond cache overflows`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let count = 1024
        let halfTrillion = 500_000_000_000
        let lines: [[String: Any]] = try (0..<count).map { index in
            var line = Self.claudeLine(
                output: halfTrillion, message: "extreme-message-\(index)", request: "extreme-request-\(index)")
            var message = try #require(line["message"] as? [String: Any])
            message["usage"] = [
                "input_tokens": halfTrillion,
                "output_tokens": halfTrillion,
                "cache_read_input_tokens": 0,
                "cache_creation_input_tokens": 0,
            ]
            line["message"] = message
            return line
        }
        try fixture.write(lines, at: fixture.claude.appendingPathComponent("project/extreme.jsonl"))
        let result = try await MidasUsageSyncExporter.export(
            workspace: MidasUsageSyncWorkspace(),
            providers: [.claude],
            now: Self.now,
            options: fixture.options)
        #expect(result.events.count == count)
        #expect(result.excludedRecords == 0)
        let perRow = try #require(result.events.first?.values.costUSD)
        #expect(perRow * Double(count) * CostUsageScanner.costScale > Double(Int64.max))
        let cache = CostUsageCacheIO.load(provider: .claude, cacheRoot: fixture.cache)
        #expect(cache.days.values.first?.values.first?[safe: 4] == Int.max)
        let report = try CostUsageScanner.loadDailyReportCancellable(
            provider: .claude,
            since: Self.now.addingTimeInterval(-7 * 86400),
            until: Self.now,
            now: Self.now,
            options: CostUsageScanner.Options(claudeProjectsRoots: [fixture.claude], cacheRoot: fixture.cache),
            checkCancellation: nil)
        let total = try #require(report.summary?.totalCostUSD)
        #expect(abs(total - perRow * Double(count)) < 0.001)
        #expect(report.summary?.totalTokens == count * 1_000_000_000_000)
    }

    @Test
    func `Repeated extreme Codex rows reprice correctly after cached nanoseconds exceed Int64`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let count = 2048
        let halfTrillion = 500_000_000_000
        var lines = Array(Self.codexLines().prefix(3))
        for index in 0..<count {
            let at = Date(timeIntervalSince1970: 1_791_885_600 + Double(index))
            let timestamp = ISO8601DateFormatter().string(from: at)
            lines.append([
                "type": "event_msg", "timestamp": timestamp,
                "payload": ["type": "token_count", "info": [
                    "last_token_usage": [
                        "input_tokens": halfTrillion,
                        "cached_input_tokens": 0,
                        "output_tokens": halfTrillion,
                    ],
                ]],
            ])
        }
        try fixture.write(lines, at: fixture.codex.appendingPathComponent("2026/10/13/extreme.jsonl"))
        let result = try await MidasUsageSyncExporter.export(
            workspace: MidasUsageSyncWorkspace(),
            providers: [.codex],
            now: Self.now,
            options: fixture.options)
        #expect(result.events.count == count)
        #expect(result.excludedRecords == 0)
        let perRow = try #require(result.events.first?.values.costUSD)
        #expect(perRow * Double(count) * CostUsageScanner.costScale > Double(Int64.max))
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: fixture.cache)
        #expect(cache.files.values.first?.codexCostNanos?.values.first?.values.first == Int64.max)
        let report = CostUsageScanner.buildCodexReportFromCache(
            cache: cache,
            range: CostUsageScanner.CostUsageDayRange(since: Self.now.addingTimeInterval(-7 * 86400), until: Self.now))
        let total = try #require(report.summary?.totalCostUSD)
        #expect(abs(total - perRow * Double(count)) < 0.001)
        #expect(report.summary?.totalTokens == count * 1_000_000_000_000)
    }

    @Test
    func `Codex sync retention uses UTC timestamps across local day boundaries`() {
        let rows = [
            CostUsageScanner.CodexUsageRow(
                day: "2025-10-15",
                model: "gpt-5",
                turnID: "within-window",
                input: 100,
                cached: 0,
                output: 20,
                timestamp: "2025-10-16T00:01:00Z"),
            CostUsageScanner.CodexUsageRow(
                day: "2025-10-16",
                model: "gpt-5",
                turnID: "expired",
                input: 100,
                cached: 0,
                output: 20,
                timestamp: "2025-10-15T23:59:00Z"),
        ]
        let range = CostUsageScanner.CostUsageDayRange(since: Self.now.addingTimeInterval(-29 * 86400), until: Self.now)
        let retained = CostUsageScanner.pruneCodexSyncRows(rows, range: range)
        #expect(retained.map(\.turnID) == ["within-window"])
    }

    @Test
    func `Codex sync rescans replace stable identities despite differing cached local days`() {
        let existing = CostUsageScanner.CodexUsageRow(
            day: "2026-06-01",
            model: "gpt-5",
            turnID: "same-turn",
            input: 100,
            cached: 0,
            output: 20,
            timestamp: Self.timestamp)
        let refreshed = CostUsageScanner.CodexUsageRow(
            day: "2026-10-13",
            model: "gpt-5",
            turnID: "same-turn",
            input: 110,
            cached: 0,
            output: 30,
            timestamp: Self.timestamp)
        let range = CostUsageScanner.CostUsageDayRange(since: Self.now.addingTimeInterval(-29 * 86400), until: Self.now)
        let retained = CostUsageScanner.retainingCodexSyncRows(existing: [existing], parsed: [refreshed], range: range)
        #expect(retained.count == 1)
        #expect(retained.first?.input == 110)
        #expect(retained.first?.output == 30)
        let ambiguous = CostUsageScanner.retainingCodexSyncRows(
            existing: [existing], parsed: [refreshed, refreshed], range: range)
        #expect(ambiguous.count == 2)
    }

    @Test
    func `Narrow Codex rescan preserves year history for a fresh workspace and expires old rows`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.codex.appendingPathComponent("2026/10/13/mixed-history.jsonl")
            .resolvingSymlinksInPath().standardizedFileURL
        let oldAt = Self.now.addingTimeInterval(-100 * 86400)
        let oldTimestamp = ISO8601DateFormatter().string(from: oldAt)
        var lines = Self.codexLines(timestamp: oldTimestamp)
        var current = Array(Self.codexLines().dropFirst())
        var last = try #require(current.last)
        var payload = try #require(last["payload"] as? [String: Any])
        var info = try #require(payload["info"] as? [String: Any])
        info["total_token_usage"] = ["input_tokens": 200, "cached_input_tokens": 80, "output_tokens": 40]
        payload["info"] = info
        last["payload"] = payload
        current[current.count - 1] = last
        lines.append(contentsOf: current)
        try fixture.write(lines, at: file)
        let initial = try await MidasUsageSyncExporter.export(
            workspace: MidasUsageSyncWorkspace(),
            providers: [.codex],
            now: Self.now,
            options: fixture.options)
        #expect(initial.events.count == 2)
        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: fixture.cache)
        #expect(cache.files.count == 1)
        let cacheKey = try #require(cache.files.keys.first)
        let cachedFile = URL(fileURLWithPath: cacheKey)
        #expect(cachedFile.lastPathComponent == file.lastPathComponent)
        var existing = try #require(cache.files[cacheKey])
        existing.codexSyncRows?.append(CostUsageScanner.CodexUsageRow(
            day: "2024-01-01",
            model: "gpt-5",
            turnID: "expired",
            input: 100,
            cached: 0,
            output: 20,
            timestamp: "2024-01-01T00:00:00Z"))
        cache.files[cacheKey] = existing
        let index = CostUsageScanner.CodexSessionFileIndex(files: [cachedFile], roots: [fixture.codex])
        let resources = CostUsageScanner.CodexScanResources(
            fileIndex: index,
            inheritedResolver: CostUsageScanner.CodexInheritedTotalsResolver(fileIndex: index, checkCancellation: nil),
            modelsDevCatalog: nil,
            modelsDevCacheRoot: fixture.cache,
            priorityTurns: [:])
        let range = CostUsageScanner.CostUsageDayRange(since: Self.now.addingTimeInterval(-29 * 86400), until: Self.now)
        var state = CostUsageScanner.CodexScanState()
        try CostUsageScanner.rescanCodexFile(
            input: CostUsageScanner.CodexFileScanInput(
                fileURL: cachedFile,
                metadata: CostUsageScanner.codexFileMetadata(fileURL: cachedFile),
                cached: existing),
            context: CostUsageScanner.CodexFileScanContext(
                range: range,
                forceFullScan: true,
                dropDeferredCodexRows: false,
                requiresTurnIDCache: false,
                changedPriorityTurnIDs: [],
                resources: resources,
                checkCancellation: nil),
            cache: &cache,
            state: &state)
        #expect(cache.files[cacheKey]?.codexSyncRows?.count == 2)
        #expect(!((cache.files[cacheKey]?.codexSyncRows ?? []).contains { $0.day == "2024-01-01" }))
        #expect(CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: fixture.cache).didSave)
        // Use a new workspace so the coordinator's retained publication cannot conceal cache loss.
        let fresh = try await MidasUsageSyncExporter.export(
            workspace: MidasUsageSyncWorkspace(),
            providers: [.codex],
            now: Self.now,
            options: fixture.options)
        #expect(fresh.events.count == 2)
        #expect(fresh.events.reduce(0) { $0 + ($1.values.tokens ?? 0) } == 240)
        #expect(Set(fresh.events.map(\.day)) == Set([MidasUsageSyncPublication.day(oldAt), "2026-10-13"]))
        #expect(fresh.excludedRecords == 0)
    }
}
