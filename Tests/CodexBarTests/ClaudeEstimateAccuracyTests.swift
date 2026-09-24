import Foundation
import Testing
@testable import CodexBarCore

/// Claude dollar estimates follow Anthropic's published API rates, including the Claude 5
/// family's cache-read discounts and the fast-mode, US-only, and web-search modifiers that
/// Claude Code records in each transcript row.
struct ClaudeEstimateAccuracyTests {
    @Test
    func `claude 5 family prices from built in table without models dev`() throws {
        let root = try Self.emptyCacheRoot()
        func cost(_ model: String) -> Double? {
            CostUsagePricing.claudeCostUSD(
                model: model,
                inputTokens: 1_000_000,
                cacheReadInputTokens: 1_000_000,
                cacheCreationInputTokens: 1_000_000,
                cacheCreationInputTokens1h: 500_000,
                outputTokens: 1_000_000,
                modelsDevCacheRoot: root)
        }
        // input + cache read + 5m write (1.25x) + 1h write (2x) + output, per 1M tokens.
        Self.expectDollars(cost("claude-opus-5-5"), 4 + 0.2 + 0.5 * 5 + 0.5 * 8 + 20)
        Self.expectDollars(cost("claude-opus-5"), 5 + 0.5 + 0.5 * 6.25 + 0.5 * 10 + 25)
        Self.expectDollars(cost("claude-sonnet-5"), 2 + 0.2 + 0.5 * 2.5 + 0.5 * 4 + 10)
        Self.expectDollars(cost("claude-fable-5-1"), 10 + 0.25 + 0.5 * 12.5 + 0.5 * 20 + 50)
        Self.expectDollars(cost("claude-mythos-5-1"), 10 + 0.25 + 0.5 * 12.5 + 0.5 * 20 + 50)
        Self.expectDollars(cost("claude-mythos-5"), 10 + 1 + 0.5 * 12.5 + 0.5 * 20 + 50)
    }

    @Test
    func `fast mode doubles supported opus models only`() throws {
        let root = try Self.emptyCacheRoot()
        func cost(_ model: String, speed: String?) -> Double? {
            CostUsagePricing.claudeCostUSD(
                model: model,
                inputTokens: 1_000_000,
                cacheReadInputTokens: 1_000_000,
                cacheCreationInputTokens: 0,
                outputTokens: 1_000_000,
                speed: speed,
                modelsDevCacheRoot: root)
        }
        Self.expectDollars(cost("claude-opus-5-5", speed: "fast"), 2 * (4 + 0.2 + 20))
        Self.expectDollars(cost("claude-opus-5", speed: "fast"), 2 * (5 + 0.5 + 25))
        Self.expectDollars(cost("claude-opus-4-8", speed: "fast"), 2 * (5 + 0.5 + 25))
        Self.expectDollars(cost("claude-opus-5-5", speed: "standard"), 4 + 0.2 + 20)
        Self.expectDollars(cost("claude-sonnet-5", speed: "fast"), 2 + 0.2 + 10)
    }

    @Test
    func `us only inference and web searches add their premiums`() throws {
        let root = try Self.emptyCacheRoot()
        let us = CostUsagePricing.claudeCostUSD(
            model: "claude-opus-5-5",
            inputTokens: 1_000_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 1_000_000,
            inferenceGeo: "us",
            webSearchRequests: 3,
            modelsDevCacheRoot: root)
        Self.expectDollars(us, 1.1 * (4 + 20) + 0.03)

        let global = CostUsagePricing.claudeCostUSD(
            model: "claude-opus-5-5",
            inputTokens: 1_000_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 1_000_000,
            inferenceGeo: "not_available",
            modelsDevCacheRoot: root)
        Self.expectDollars(global, 24)
    }

    @Test
    func `unknown models stay unpriced even with web searches`() throws {
        let cost = try CostUsagePricing.claudeCostUSD(
            model: "claude-unreleased-test-model",
            inputTokens: 10,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 10,
            webSearchRequests: 5,
            modelsDevCacheRoot: Self.emptyCacheRoot())
        #expect(cost == nil)
    }

    @Test
    func `scanner reprices recorded fast mode geo and web search rows`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 23)
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/modifiers.jsonl",
            contents: env.jsonl([
                Self.assistantRow(
                    id: "fast",
                    model: "claude-opus-5-5",
                    usage: [
                        "input_tokens": 1000,
                        "cache_creation_input_tokens": 0,
                        "cache_read_input_tokens": 0,
                        "output_tokens": 1000,
                        "speed": "fast",
                        "inference_geo": "us",
                        "server_tool_use": ["web_search_requests": 2, "web_fetch_requests": 1],
                    ]),
            ]))

        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: Self.options(env))

        #expect(report.data.count == 1)
        let expected = 2 * 1.1 * (1000 * 4e-6 + 1000 * 2e-5) + 0.02
        Self.expectDollars(report.data.first?.costUSD, expected)
        #expect(report.data.first?.requestCount == 1)
        #expect(report.data.first?.unpricedRequestCount == nil)
        #expect(report.data.first?.pricedRequestCount == 1)
    }

    @Test
    func `scanner discloses unpriced rows on a mixed day`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 23)
        let usage: [String: Any] = [
            "input_tokens": 1000,
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 0,
            "output_tokens": 1000,
        ]
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/mixed.jsonl",
            contents: env.jsonl([
                Self.assistantRow(id: "known", model: "claude-opus-5-5", usage: usage),
                Self.assistantRow(id: "unknown-a", model: "claude-unreleased-test-model", usage: usage),
                Self.assistantRow(id: "unknown-b", model: "claude-unreleased-test-model", usage: usage),
            ]))

        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: Self.options(env))

        let entry = try #require(report.data.first)
        Self.expectDollars(entry.costUSD, 1000 * 4e-6 + 1000 * 2e-5)
        #expect(entry.requestCount == 3)
        #expect(entry.pricedRequestCount == 1)
        #expect(entry.unpricedRequestCount == 2)
    }

    // MARK: - Helpers

    private static func expectDollars(
        _ actual: Double?,
        _ expected: Double,
        sourceLocation: SourceLocation = #_sourceLocation)
    {
        guard let actual else {
            Issue.record("Expected \(expected), got nil", sourceLocation: sourceLocation)
            return
        }
        #expect(abs(actual - expected) < 1e-9, "\(actual) != \(expected)", sourceLocation: sourceLocation)
    }

    private static func assistantRow(id: String, model: String, usage: [String: Any]) -> [String: Any] {
        [
            "message": [
                "model": model,
                "id": "msg_\(id)",
                "type": "message",
                "role": "assistant",
                "usage": usage,
            ],
            "requestId": "req_\(id)",
            "type": "assistant",
            "timestamp": "2026-09-23T12:00:00.000Z",
            "sessionId": "session_claude_estimates",
        ]
    }

    private static func options(_ env: CostUsageTestEnvironment) -> CostUsageScanner.Options {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        return options
    }

    private static func emptyCacheRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("midas-claude-estimate-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
