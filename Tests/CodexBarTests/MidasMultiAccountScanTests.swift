import Foundation
import Testing
@testable import CodexBarCore

struct MidasMultiAccountScanTests {
    @Test func combinesHomesAndArchivesWithoutRepeatingCopiedSessions() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        func session(_ id: String, input: Int) throws -> String {
            try env.jsonl([
                ["type": "session_meta", "payload": ["id": id]],
                ["type": "turn_context", "payload": ["model": "gpt-5"]],
                ["type": "event_msg", "timestamp": env.isoString(for: day), "payload": [
                    "type": "token_count", "info": ["total_token_usage": [
                        "input_tokens": input, "cached_input_tokens": 0, "output_tokens": 10,
                        "reasoning_output_tokens": 0, "total_tokens": input + 10,
                    ]],
                ]],
            ])
        }
        let source = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-primary.jsonl",
            contents: session("primary", input: 100))
        let other = env.root.appendingPathComponent("secondary/sessions")
        let archive = env.root.appendingPathComponent("secondary/archived_sessions")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: other.appendingPathComponent("rollout-copy.jsonl"))
        try session("secondary", input: 200).write(
            to: archive.appendingPathComponent("rollout-secondary.jsonl"),
            atomically: true,
            encoding: .utf8)
        var options = CostUsageScanner.Options(codexSessionsRoot: env.codexSessionsRoot, cacheRoot: env.cacheRoot)
        options.codexAdditionalSessionsRoots = [other, env.codexSessionsRoot, other]
        options.refreshMinIntervalSeconds = 0
        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(report.data.reduce(0) { $0 + ($1.totalTokens ?? 0) } == 320)
        // Warm-cache aggregation must not count copies or repeat either account.
        let cached = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(cached.data.reduce(0) { $0 + ($1.totalTokens ?? 0) } == 320)
        // Removing an account root invalidates its contribution.
        options.codexAdditionalSessionsRoots = []
        let single = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(single.data.reduce(0) { $0 + ($1.totalTokens ?? 0) } == 110)
    }
}
