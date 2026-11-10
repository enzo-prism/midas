import Foundation
import Testing
@testable import CodexBarCore

struct CodexFastTierTests {
    private static func settings(_ tier: Any?, at timestamp: String) -> [String: Any] {
        var threadSettings: [String: Any] = ["model": "gpt-6.1-sol", "reasoning_effort": "high"]
        if let tier { threadSettings["service_tier"] = tier }
        return [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": ["type": "thread_settings_applied", "thread_settings": threadSettings],
        ]
    }

    private static func tokenCount(input: Int, output: Int, at timestamp: String) -> [String: Any] {
        [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "info": ["total_token_usage": [
                    "input_tokens": input,
                    "cached_input_tokens": 0,
                    "output_tokens": output,
                ]],
            ],
        ]
    }

    @Test
    func `session file tier marks the usage that follows until it changes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 11, day: 3)
        let stamps = (0..<6).map { env.isoString(for: day.addingTimeInterval(TimeInterval($0))) }
        let turnContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": stamps[0],
            "payload": ["model": "gpt-6.1-sol"],
        ]
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "fast-session.jsonl",
            contents: env.jsonl([
                turnContext,
                Self.settings("default", at: stamps[0]),
                Self.tokenCount(input: 100, output: 10, at: stamps[1]),
                Self.settings("priority", at: stamps[2]),
                Self.tokenCount(input: 300, output: 30, at: stamps[3]),
                // A settings event without the field leaves the tier as it was.
                Self.settings(nil, at: stamps[4]),
                Self.tokenCount(input: 600, output: 60, at: stamps[5]),
            ]))
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)

        let parsed = CostUsageScanner.parseCodexFile(fileURL: fileURL, range: range)
        #expect(parsed.rows.map(\.input) == [100, 200, 300])
        #expect(parsed.rows.map(\.fast) == [nil, true, true])
        #expect(parsed.lastCodexFast == true)

        // An incremental scan resumes with the tier the earlier scan ended on.
        let resumed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: range,
            startOffset: parsed.parsedBytes,
            initialModel: parsed.lastModel,
            initialTotals: parsed.lastTotals,
            initialCodexFast: parsed.lastCodexFast)
        #expect(resumed.lastCodexFast == true)
    }

    @Test
    func `fast rows are priced at the model's fast multiplier without trace metadata`() {
        let standard = CostUsageScanner.CodexUsageRow(
            day: "2026-11-03", model: "gpt-6.1-sol", turnID: nil, input: 1_000_000, cached: 0, output: 100_000)
        var fast = standard
        fast.fast = true

        let base = CostUsageScanner.codexRowCostBreakdown(
            rows: [standard], priorityTurns: [:], modelsDevCatalog: nil, modelsDevCacheRoot: nil)
        let split = CostUsageScanner.codexRowCostBreakdown(
            rows: [standard, fast], priorityTurns: [:], modelsDevCatalog: nil, modelsDevCacheRoot: nil)

        #expect(split.priorityTokens == 1_100_000)
        #expect(split.standardTokens == 1_100_000)
        if let baseCost = base.optionalStandardCostUSD {
            // Priced model: the Fast row costs twice the standard row.
            #expect(abs((split.optionalPriorityCostUSD ?? 0) - baseCost * 2) < 1e-9)
            let surcharge = CostUsageScanner.codexPrioritySurchargeUSD(
                rows: [standard, fast], priorityTurns: [:], modelsDevCatalog: nil, modelsDevCacheRoot: nil)
            #expect(abs((surcharge ?? 0) - baseCost) < 1e-9)
        }
    }

    @Test
    func `fast multiplier applies only where a fast price is known`() {
        #expect(CostUsagePricing.codexFastCostUSD(
            model: "gpt-6.1-sol", inputTokens: 10, outputTokens: 1, baseCost: 3) == 6)
        // Long context stays Fast-priced for the GPT-6 family.
        #expect(CostUsagePricing.codexFastCostUSD(
            model: "gpt-6-astra", inputTokens: 400_000, outputTokens: 1, baseCost: 3) == 6)
        #expect(CostUsagePricing.codexFastCostUSD(
            model: "gpt-5.6-sol", inputTokens: 400_000, outputTokens: 1, baseCost: 3) == nil)
        #expect(CostUsagePricing.codexFastCostUSD(
            model: "codex-auto-review", inputTokens: 10, outputTokens: 1, baseCost: 3) == nil)
        #expect(CostUsagePricing.codexFastCostUSD(
            model: "gpt-6.1-sol", inputTokens: 10, outputTokens: 1, baseCost: nil) == nil)
    }
}
