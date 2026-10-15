import Foundation
import Testing
@testable import CodexBarCore

/// Gates for the retained-window scan behavior: a forward window slide and alternating
/// window widths must reuse per-file cache entries instead of forcing full corpus
/// reparses, and a scan that changed nothing must not rewrite the cache file. Reparse
/// detection uses the same-size/same-mtime mutation trick as the performance gates:
/// only a real reparse can observe the mutated token counts.
@Suite(.serialized)
struct CostUsageRetainedWindowTests {
    private static func claudeOptions(env: CostUsageTestEnvironment) -> CostUsageScanner.Options {
        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        return options
    }

    private static func claudeLine(
        env: CostUsageTestEnvironment,
        day: Date,
        id: String,
        input: Int) throws -> [String: Any]
    {
        [
            "type": "assistant",
            "timestamp": env.isoString(for: day),
            "sessionId": "retained-session",
            "requestId": "req_\(id)",
            "isSidechain": false,
            "message": [
                "id": "msg_\(id)",
                "model": "claude-sonnet-4-20250514",
                "usage": [
                    "input_tokens": input,
                    "cache_creation_input_tokens": 5,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 7,
                ],
            ],
        ]
    }

    private static func mutateInPlace(fileURL: URL, from: String, to: String) throws {
        #expect(from.utf8.count == to.utf8.count)
        // Read and restore the timestamp through URL resource values — the same surface the
        // Claude enumerator reads — so the restored mtime is bit-identical to the cached one.
        let modificationDate = try #require(
            try fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let original = try String(contentsOf: fileURL, encoding: .utf8)
        let modified = original.replacingOccurrences(of: from, with: to)
        #expect(modified != original)
        #expect(modified.utf8.count == original.utf8.count)
        try modified.write(to: fileURL, atomically: false, encoding: .utf8)
        var values = URLResourceValues()
        values.contentModificationDate = modificationDate
        var mutableURL = fileURL
        try mutableURL.setResourceValues(values)
    }

    private static func shifted(_ day: Date, byDays days: Int) throws -> Date {
        try #require(Calendar.current.date(byAdding: .day, value: days, to: day))
    }

    @Test
    func `claude forward window slide must not reparse unchanged files`() throws {
        CostUsageScanner._test_resetDailyReportMemo()
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let rowDay = try Self.shifted(day, byDays: -5)
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/slide.jsonl",
            contents: env.jsonl([Self.claudeLine(env: env, day: rowDay, id: "slide", input: 100)]))
        let options = Self.claudeOptions(env: env)

        let cold = try CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: Self.shifted(day, byDays: -29),
            until: day,
            now: day,
            options: options)
        #expect(cold.summary?.totalTokens == 112)

        try Self.mutateInPlace(fileURL: fileURL, from: "\"input_tokens\":100", to: "\"input_tokens\":900")

        let slid = try CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: Self.shifted(day, byDays: -28),
            until: Self.shifted(day, byDays: 1),
            now: Self.shifted(day, byDays: 1),
            options: options)
        #expect(slid.summary?.totalTokens == cold.summary?.totalTokens)
    }

    @Test
    func `claude alternating 30 and 60 day windows share one retained cache`() throws {
        CostUsageScanner._test_resetDailyReportMemo()
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let oldDay = try Self.shifted(day, byDays: -40)
        let recentDay = try Self.shifted(day, byDays: -5)
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/alternating.jsonl",
            contents: env.jsonl([
                Self.claudeLine(env: env, day: oldDay, id: "old", input: 100),
                Self.claudeLine(env: env, day: recentDay, id: "recent", input: 100),
            ]))
        let options = Self.claudeOptions(env: env)

        let current = try CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: Self.shifted(day, byDays: -29),
            until: day,
            now: day,
            options: options)
        #expect(current.summary?.totalTokens == 112)

        let prior = try CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: Self.shifted(day, byDays: -59),
            until: day,
            now: day,
            options: options)
        #expect(prior.summary?.totalTokens == 224)

        try Self.mutateInPlace(fileURL: fileURL, from: "\"input_tokens\":100", to: "\"input_tokens\":900")

        let currentAgain = try CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: Self.shifted(day, byDays: -29),
            until: day,
            now: day,
            options: options)
        #expect(currentAgain.summary?.totalTokens == current.summary?.totalTokens)

        let priorAgain = try CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: Self.shifted(day, byDays: -59),
            until: day,
            now: day,
            options: options)
        #expect(priorAgain.summary?.totalTokens == prior.summary?.totalTokens)
    }

    @Test
    func `claude wide request is never truncated by the retained clip`() throws {
        CostUsageScanner._test_resetDailyReportMemo()
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let ancientDay = try Self.shifted(day, byDays: -200)
        let recentDay = try Self.shifted(day, byDays: -5)
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/wide.jsonl",
            contents: env.jsonl([
                Self.claudeLine(env: env, day: ancientDay, id: "ancient", input: 100),
                Self.claudeLine(env: env, day: recentDay, id: "recent", input: 100),
            ]))
        let options = Self.claudeOptions(env: env)

        _ = try CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: Self.shifted(day, byDays: -29),
            until: day,
            now: day,
            options: options)

        let wide = try CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: Self.shifted(day, byDays: -364),
            until: day,
            now: day,
            options: options)
        #expect(wide.summary?.totalTokens == 224)

        _ = try CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: Self.shifted(day, byDays: -29),
            until: day,
            now: day,
            options: options)

        let wideAgain = try CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: Self.shifted(day, byDays: -364),
            until: day,
            now: day,
            options: options)
        #expect(wideAgain.summary?.totalTokens == 224)
    }

    @Test
    func `claude regressed until must not delete newer retained rows`() throws {
        CostUsageScanner._test_resetDailyReportMemo()
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let olderDay = try Self.shifted(day, byDays: -5)
        let newerDay = try Self.shifted(day, byDays: -1)
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/until.jsonl",
            contents: env.jsonl([
                Self.claudeLine(env: env, day: olderDay, id: "older", input: 100),
                Self.claudeLine(env: env, day: newerDay, id: "newer", input: 200),
            ]))
        let options = Self.claudeOptions(env: env)

        let full = try CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: Self.shifted(day, byDays: -29),
            until: day,
            now: day,
            options: options)
        #expect(full.summary?.totalTokens == 324)

        let regressed = try CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: Self.shifted(day, byDays: -29),
            until: Self.shifted(day, byDays: -3),
            now: day,
            options: options)
        #expect(regressed.summary?.totalTokens == 112)

        try Self.mutateInPlace(fileURL: fileURL, from: "\"input_tokens\":200", to: "\"input_tokens\":800")

        let restored = try CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: Self.shifted(day, byDays: -29),
            until: day,
            now: day,
            options: options)
        #expect(restored.summary?.totalTokens == full.summary?.totalTokens)
    }

    @Test
    func `claude clean warm scan must not rewrite the cache file`() throws {
        CostUsageScanner._test_resetDailyReportMemo()
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/clean.jsonl",
            contents: env.jsonl([Self.claudeLine(env: env, day: day, id: "clean", input: 100)]))
        let options = Self.claudeOptions(env: env)

        _ = try CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: Self.shifted(day, byDays: -29),
            until: day,
            now: day,
            options: options)

        let cacheURL = CostUsageCacheIO.cacheFileURL(provider: .claude, cacheRoot: env.cacheRoot)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
        let sentinel = Date(timeIntervalSince1970: 978_307_200)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: cacheURL.path)

        _ = try CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: Self.shifted(day, byDays: -29),
            until: day,
            now: day,
            options: options)

        let attributes = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
        #expect(attributes[.modificationDate] as? Date == sentinel)
    }

    @Test
    func `codex forward window slide must not reparse unchanged files`() throws {
        CostUsageScanner._test_resetDailyReportMemo()
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let baseISO = env.isoString(for: day)
        let model = "openai/gpt-5.2-codex"
        func tokenCountLine(input: Int, cached: Int, output: Int) -> String {
            #"{"type":"event_msg","timestamp":"\#(baseISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"#
                + #""output_tokens":\#(output)},"model":"\#(model)"}}}"#
        }

        let contents = [
            #"{"type":"session_meta","timestamp":"\#(baseISO)","payload":{"session_id":"slide-0"}}"#,
            #"{"type":"turn_context","timestamp":"\#(baseISO)","payload":{"model":"\#(model)"}}"#,
            tokenCountLine(input: 100, cached: 20, output: 10),
            tokenCountLine(input: 200, cached: 40, output: 20),
        ].joined(separator: "\n") + "\n"
        let fileURL = try env.writeCodexSessionFile(day: day, filename: "session-slide.jsonl", contents: contents)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0

        let cold = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(cold.data.count == 1)

        try Self.mutateInPlace(fileURL: fileURL, from: "\"input_tokens\":100,", to: "\"input_tokens\":900,")

        let nextDay = try Self.shifted(day, byDays: 1)
        let slid = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: nextDay,
            now: nextDay,
            options: options)
        #expect(slid.data.first?.totalTokens == cold.data.first?.totalTokens)
    }
}
