import CodexBarCore
import Foundation
import Testing

struct MetaSessionLogScannerTests {
    private static func completedLine(
        input: Int,
        output: Int,
        reasoning: Int,
        model: String = "muse-spark-1.3-contributor",
        recordedAtMicros: Int = 1_788_446_411_666_043) -> String
    {
        """
        {"schema_version":1,"id":"abc","stream":{"kind":"session","id":"s1"},"sequence":9,\
        "recorded_at":\(recordedAtMicros),"record_type":"event","durability":"durable",\
        "causation_id":null,"payload_type":"runtime.session","payload_schema_version":1,\
        "payload":{"kind":"run","run_id":"r1","event":{"kind":"model_completed",\
        "usage":{"input_tokens":\(input),"output_tokens":\(output),\
        "cached_tokens":0,"cache_write_tokens":0,"cache_read_tokens":0,\
        "reasoning_tokens":\(reasoning)},"duration_ms":100,"finish_reason":"stop",\
        "model":"\(model)"}}}
        """
    }

    @Test
    func `parses direct model_completed record`() {
        let responses = MuseSessionLogScanner._parseResponsesForTesting(
            fromLine: Self.completedLine(input: 30034, output: 232, reasoning: 97))

        #expect(responses.count == 1)
        #expect(responses[0].usage.inputTokens == 30034)
        #expect(responses[0].usage.outputTokens == 232)
        #expect(responses[0].usage.reasoningTokens == 97)
        #expect(responses[0].usage.totalTokens == 30363)
        #expect(responses[0].model == "muse-spark-1.3-contributor")
    }

    @Test
    func `reads cache hits from cache_read_tokens`() {
        let line = """
        {"schema_version":1,"id":"abc","stream":{"kind":"session","id":"s1"},"sequence":9,\
        "recorded_at":1788446411666043,"record_type":"event","durability":"durable",\
        "causation_id":null,"payload_type":"runtime.session","payload_schema_version":1,\
        "payload":{"kind":"run","run_id":"r1","event":{"kind":"model_completed",\
        "usage":{"input_tokens":34895,"output_tokens":715,\
        "cached_tokens":0,"cache_write_tokens":0,"cache_read_tokens":29425,\
        "reasoning_tokens":562},"duration_ms":7629,"finish_reason":"tool_calls",\
        "model":"muse-spark-1.3-contributor"}}}
        """

        let responses = MuseSessionLogScanner._parseResponsesForTesting(fromLine: line)

        #expect(responses.count == 1)
        #expect(responses[0].usage.cachedTokens == 29425)
        #expect(responses[0].usage.totalTokens == 36172)
    }

    @Test
    func `unwraps retained_frame children`() {
        let inner = Self.completedLine(input: 100, output: 50, reasoning: 0)
        let escaped = inner
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let frame = """
        {"retained_frame":"session_permission_transaction","frame_schema_version":1,\
        "outer_log_ordinal":1,"transaction_id":"t1","children":[{"child_index":0,\
        "record_json":"\(escaped)"}],"content_sha256":"sha256:abc"}
        """

        let responses = MuseSessionLogScanner._parseResponsesForTesting(fromLine: frame)

        #expect(responses.count == 1)
        #expect(responses[0].usage.totalTokens == 150)
    }

    @Test
    func `ignores non-usage records`() {
        let line = """
        {"schema_version":1,"id":"x","stream":{"kind":"session","id":"s1"},"sequence":3,\
        "recorded_at":1788446407972312,"record_type":"event",\
        "payload_type":"runtime.session.metadata","payload_schema_version":1,\
        "payload":{"kind":"metadata","record":{"provider_id":"meta"}}}
        """

        #expect(MuseSessionLogScanner._parseResponsesForTesting(fromLine: line).isEmpty)
        #expect(MuseSessionLogScanner._parseResponsesForTesting(fromLine: "not json").isEmpty)
        #expect(MuseSessionLogScanner._parseResponsesForTesting(fromLine: "").isEmpty)
    }

    @Test
    func `summarizes today and weekly windows`() {
        // Anchor at local noon so "yesterday 11pm" stays on the previous
        // local-calendar day in every time zone (a GMT-midnight anchor puts
        // both samples on the same local day west of Greenwich).
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_788_480_000))
        let now = startOfToday.addingTimeInterval(12 * 3600)
        let yesterday = startOfToday.addingTimeInterval(-3600)
        let since = startOfToday.addingTimeInterval(-29 * 24 * 3600)

        let responses = [
            MetaCompletedResponse(
                at: now,
                model: "muse-spark-1.3-contributor",
                usage: MetaTokenUsage(inputTokens: 1000, outputTokens: 200)),
            MetaCompletedResponse(
                at: yesterday,
                model: "muse-spark-1.3-contributor",
                usage: MetaTokenUsage(inputTokens: 500, outputTokens: 100)),
        ]
        let summary = MuseSessionLogScanner._summarizeForTesting(
            responses: responses,
            since: since,
            until: now,
            now: now)

        #expect(summary.today.totalTokens == 1200)
        #expect(summary.last7Days.totalTokens == 1800)
        #expect(summary.last30Days.totalTokens == 1800)
        #expect(summary.modelsUsed == ["muse-spark-1.3-contributor"])
        #expect(summary.daily.count == 2)
    }

    @Test
    func `settings reader resolves meta api key`() {
        #expect(MetaSettingsReader.apiKey(environment: ["META_API_KEY": " metask_123 "]) == "metask_123")
        #expect(MetaSettingsReader.apiKey(environment: [:]) == nil)
        #expect(ProviderTokenResolver.metaToken(environment: ["META_API_KEY": "k"]) == "k")
    }

    @Test
    func `snapshot maps totals to menu windows`() {
        let now = Date(timeIntervalSince1970: 1_788_480_000)
        let summary = MetaUsageSummary(
            today: MetaTokenUsage(inputTokens: 1000, outputTokens: 200),
            last7Days: MetaTokenUsage(inputTokens: 5000, outputTokens: 2000),
            last30Days: MetaTokenUsage(inputTokens: 5000, outputTokens: 2000),
            sessionsWithData: 3,
            modelsUsed: ["muse-spark-1.3-contributor"],
            updatedAt: now)
        let snapshot = MetaUsageSnapshot(summary: summary).toUsageSnapshot()

        #expect(snapshot.identity?.providerID == .meta)
        #expect(snapshot.primary?.resetDescription == "1.2k today")
        #expect(snapshot.secondary?.resetDescription == "7.0k last 7d")
    }

    @Test
    func `cost fetcher builds daily report from summary`() {
        let summary = MetaUsageSummary(
            daily: [MetaDailyUsage(
                dayKey: "2026-09-03",
                usage: MetaTokenUsage(inputTokens: 100, outputTokens: 50, requests: 2),
                modelsUsed: ["muse-spark-1.3-contributor"])])
        let report = CostUsageFetcher.metaDailyReport(from: summary)

        #expect(report.data.count == 1)
        #expect(report.data[0].totalTokens == 150)
        #expect(report.data[0].requestCount == 2)
        // Contributor $0.10/$0.20 per 1M in/out: 100 * 1e-7 + 50 * 2e-7.
        #expect(abs((report.data[0].costUSD ?? -1) - 0.00002) < 1e-12)
        // Standard $1.25/$4.25 per 1M in/out: 100 * 1.25e-6 + 50 * 4.25e-6.
        #expect(abs((report.data[0].apiEquivalentCostUSD ?? -1) - 0.0003375) < 1e-12)
    }

    @Test
    func `cost fetcher leaves mixed model days unpriced`() {
        let summary = MetaUsageSummary(
            daily: [MetaDailyUsage(
                dayKey: "2026-09-03",
                usage: MetaTokenUsage(inputTokens: 100, outputTokens: 50, requests: 2),
                modelsUsed: ["muse-spark-1.3-contributor", "muse-spark-1.2"])])
        let report = CostUsageFetcher.metaDailyReport(from: summary)

        #expect(report.data.count == 1)
        #expect(report.data[0].costUSD == nil)
        #expect(report.data[0].apiEquivalentCostUSD == nil)
    }
}
