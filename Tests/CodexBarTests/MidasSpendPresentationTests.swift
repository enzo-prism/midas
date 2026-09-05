import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct MidasSpendPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_788_523_200)

    @Test func estimatesCarryTheirPriceMeaningAndActualPeriod() throws {
        let spend = try #require(MidasSpendPresentation.make(
            provider: .codex,
            snapshot: self.snapshot(
                amount: 12.50,
                provenance: .listPriceEstimate)))
        #expect(spend.title == "Estimated spend")
        #expect(spend.amount == 12.50)
        #expect(spend.period == "Last 7 days")
        #expect(spend.detail.contains("API-rate"))
        #expect(spend.detail.contains("not a bill"))
    }

    @Test func unknownSourceNeverBecomesAnEstimateOrCashCharge() throws {
        let spend = try #require(MidasSpendPresentation.make(
            provider: .codex,
            snapshot: self.snapshot(
                amount: 4,
                provenance: .unknown)))
        #expect(spend.title == "Recorded usage value")
    }

    @Test func unavailableAndInvalidNeverBecomeZero() {
        #expect(MidasSpendPresentation.make(
            provider: .codex,
            snapshot: nil) == nil)
        for amount: Double? in [nil, .nan, .infinity, -1] {
            #expect(MidasSpendPresentation.make(
                provider: .codex,
                snapshot: self.snapshot(
                    amount: amount,
                    provenance: .listPriceEstimate)) == nil)
        }
        #expect(MidasSpendPresentation.make(
            provider: .codex,
            snapshot: self.snapshot(
                amount: 0,
                provenance: .listPriceEstimate))?.amount == 0)
    }

    @Test func cursorEstimatedAndMeteredValuesNeverAddTogether() throws {
        let spend = try #require(MidasSpendPresentation.make(
            provider: .cursor,
            snapshot: self.snapshot(
                amount: 15,
                provenance: .mixed,
                metered: 3)))
        #expect(spend.title == "Estimated spend")
        #expect(spend.amount == 15)
        #expect(spend.secondaryLabel == "Provider-metered consumption")
        #expect(spend.secondaryValue == 3.0.formatted(.currency(code: "USD")))
    }

    @Test func meteredOnlyUsesAnHonestPrimaryLabel() throws {
        let spend = try #require(MidasSpendPresentation.make(
            provider: .cursor,
            snapshot: self.snapshot(
                amount: nil,
                provenance: .vendorMetered,
                metered: 3)))
        #expect(spend.title == "Provider-metered usage")
        #expect(spend.amount == 3)
        #expect(spend.secondaryValue == nil)
    }

    @Test func metaFreeTierKeepsZeroPrimaryAndStandardEquivalentSeparate() throws {
        let spend = try #require(MidasSpendPresentation.make(
            provider: .meta,
            snapshot: self.snapshot(
                amount: 0,
                provenance: .listPriceEstimate,
                equivalent: 22)))
        #expect(spend.title == "Estimated spend")
        #expect(spend.amount == 0)
        #expect(spend.detail.contains("Model-tier"))
        #expect(spend.secondaryLabel == "Standard API-equivalent value")
        #expect(spend.secondaryValue == 22.0.formatted(.currency(code: "USD")))
    }

    @Test func currencyIsNotConvertedOrRelabeled() throws {
        let spend = try #require(MidasSpendPresentation.make(
            provider: .mistral,
            snapshot: self.snapshot(
                amount: 12,
                provenance: .vendorMetered,
                currency: "EUR")))
        #expect(spend.currency == "EUR")
        #expect(spend.value == 12.0.formatted(.currency(code: "EUR")))
    }

    @Test func codexLocalScannerAndCacheEstablishEstimateProvenance() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(
            year: 2026,
            month: 4,
            day: 8)
        // A fresh isolated catalog prevents network pricing refresh in this fixture.
        ModelsDevCache.save(
            catalog: ModelsDevCatalog(providers: [:]),
            fetchedAt: day,
            cacheRoot: env.cacheRoot)
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "spend-fixture.jsonl",
            contents: env.jsonl([
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: day),
                    "payload": ["model": "openai/gpt-5.4"],
                ],
                ["type": "event_msg", "timestamp": env.isoString(for: day), "payload": [
                    "type": "token_count", "info": [
                        "last_token_usage": [
                            "input_tokens": 42,
                            "cached_input_tokens": 0,
                            "output_tokens": 0,
                        ],
                        "model": "openai/gpt-5.4",
                    ],
                ]],
            ]))
        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        let fresh = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            historyDays: 1,
            scannerOptions: options,
            piScannerOptions: PiSessionCostScanner.Options(
                piSessionsRoot: env.piSessionsRoot,
                cacheRoot: env.cacheRoot))
        let cached = await CostUsageFetcher.loadCachedCodexTokenSnapshot(
            now: day,
            historyDays: 1,
            scannerOptions: options)
        #expect(fresh.costProvenance == .listPriceEstimate)
        #expect(fresh.last30DaysTokens == 42)
        #expect(cached?.costProvenance == .listPriceEstimate)
        #expect(cached?.last30DaysTokens == 42)
    }

    private func snapshot(
        amount: Double?,
        provenance: CostProvenance,
        metered: Double? = nil,
        equivalent: Double? = nil,
        currency: String = "USD") -> CostUsageTokenSnapshot
    {
        .init(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: amount,
            last30DaysAPIEquivalentCostUSD: equivalent,
            currencyCode: currency,
            historyDays: 7,
            meteredCostUSD: metered,
            costProvenance: provenance,
            daily: [],
            updatedAt: self.now)
    }
}
