import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct OpenAICostCommandTests {
    private static func bucket(day: String, cost: Double, tokens: Int) -> OpenAIAPIUsageSnapshot.DailyBucket {
        OpenAIAPIUsageSnapshot.DailyBucket(
            day: day,
            startTime: Date(timeIntervalSince1970: 1_700_179_200),
            endTime: Date(timeIntervalSince1970: 1_700_265_600),
            costUSD: cost,
            requests: 4,
            inputTokens: tokens,
            cachedInputTokens: 0,
            outputTokens: tokens / 2,
            totalTokens: tokens + tokens / 2,
            lineItems: [.init(name: "Sample models", costUSD: cost)],
            models: [.init(
                name: "gpt-5",
                requests: 4,
                inputTokens: tokens,
                cachedInputTokens: 0,
                outputTokens: tokens / 2,
                totalTokens: tokens + tokens / 2)])
    }

    @Test
    func `openai cost requires api key`() async {
        await #expect(throws: OpenAIAPISettingsError.missingToken) {
            try await CostUsageFetcher().loadTokenSnapshot(
                provider: .openai,
                environment: [:],
                historyDays: 30,
                refreshPricingInBackground: false)
        }
    }

    @Test
    func `openai snapshot projects billed spend`() {
        let usage = OpenAIAPIUsageSnapshot(
            daily: [
                Self.bucket(day: "2026-09-01", cost: 1.25, tokens: 1000),
                Self.bucket(day: "2026-09-02", cost: 2.5, tokens: 2000),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_700_265_600),
            historyDays: 30)
        let snapshot = usage.toCostUsageTokenSnapshot()

        #expect(snapshot.last30DaysCostUSD == 3.75)
        #expect(snapshot.last30DaysTokens == 4500)
        #expect(snapshot.daily.count == 2)
        #expect(snapshot.daily[0].costUSD == 1.25)
    }

    @Test
    func `renders openai cost text section`() {
        let usage = OpenAIAPIUsageSnapshot(
            daily: [Self.bucket(day: "2026-09-02", cost: 2.5, tokens: 2000)],
            updatedAt: Date(timeIntervalSince1970: 1_700_265_600),
            historyDays: 30)
        let output = CodexBarCLI.renderCostText(
            provider: .openai,
            snapshot: usage.toCostUsageTokenSnapshot(),
            useColor: false)

        #expect(output.contains("OpenAI Cost (API-rate estimate)"))
        #expect(output.contains("$2.50"))
    }
}
