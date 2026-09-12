import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MidasCodexEstimateTests {
    private let now = Date(timeIntervalSince1970: 1_789_171_200)

    private func snapshot(
        total: Int = 12500,
        priced: Int = 10000,
        cost: Double? = 0.02,
        date: String = "2026-09-10",
        currency: String = "USD",
        provenance: CostProvenance = .listPriceEstimate,
        updatedAt: Date? = nil) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: total,
            last30DaysCostUSD: cost,
            currencyCode: currency,
            costProvenance: provenance,
            daily: [CostUsageDailyReport.Entry(
                date: date,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: total,
                costUSD: cost,
                modelsUsed: ["gpt-5", "unpriced-test-model"],
                modelBreakdowns: [
                    .init(
                        modelName: "gpt-5",
                        costUSD: cost,
                        totalTokens: priced),
                    .init(
                        modelName: "unpriced-test-model",
                        costUSD: nil,
                        totalTokens: max(0, total - priced)),
                ])],
            updatedAt: updatedAt ?? self.now)
    }

    @Test func migrationPreservesExplicitChoices() throws {
        let suite = "MidasCodexEstimate-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(MidasCodexEstimateMode.load(from: defaults) == .automatic)
        defaults.set(
            0.75,
            forKey: "midasCloudUSDPerMillionTokens")
        #expect(MidasCodexEstimateMode.load(from: defaults) == .custom)
        defaults.set(
            0,
            forKey: "midasCloudUSDPerMillionTokens")
        #expect(MidasCodexEstimateMode.load(from: defaults) == .tokensOnly)
        defaults.set(
            "automatic",
            forKey: "midasCodexEstimateMode")
        #expect(MidasCodexEstimateMode.load(from: defaults) == .automatic)
        defaults.set(
            "tokensOnly",
            forKey: "midasCodexEstimateMode")
        defaults.set(
            5,
            forKey: "midasCloudUSDPerMillionTokens")
        #expect(MidasCodexEstimateMode.load(from: defaults) == .tokensOnly)
        defaults.set(
            "custom",
            forKey: "midasCodexEstimateMode")
        #expect(MidasCodexEstimateMode.load(from: defaults) == .custom)
    }

    @Test func weightedRateExcludesUnpricedTokensFromDenominator() throws {
        let sample = try #require(MidasCodexCalibration.make(
            snapshot: self.snapshot(),
            now: self.now))
        #expect(abs(sample.rate - 2) < 0.000001)
        #expect(sample.pricedTokens == 10000)
        #expect(sample.observedTokens == 12500)
        #expect(sample.estimate(now: self.now) != nil)
    }

    @Test func weightedRateUsesTokenWeightAcrossModels() throws {
        let daily = CostUsageDailyReport.Entry(
            date: "2026-09-10",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 100_000,
            costUSD: 0.19,
            modelsUsed: ["gpt-5", "gpt-5-mini"],
            modelBreakdowns: [
                .init(
                    modelName: "gpt-5",
                    costUSD: 0.1,
                    totalTokens: 10000),
                .init(
                    modelName: "gpt-5-mini",
                    costUSD: 0.09,
                    totalTokens: 90000),
            ])
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 100_000,
            last30DaysCostUSD: 0.19,
            costProvenance: .listPriceEstimate,
            daily: [daily],
            updatedAt: self.now)
        let sample = try #require(MidasCodexCalibration.make(
            snapshot: snapshot,
            now: self.now))
        #expect(abs(sample.rate - 1.9) < 0.000001)
    }

    @Test func coverageAndVolumeThresholdsAreInclusive() {
        #expect(MidasCodexCalibration.make(
            snapshot: self.snapshot(),
            now: self.now) != nil)
        #expect(MidasCodexCalibration.make(
            snapshot: self.snapshot(total: 12501),
            now: self.now) == nil)
        #expect(MidasCodexCalibration.make(
            snapshot: self.snapshot(
                total: 9999,
                priced: 9999),
            now: self.now) == nil)
    }

    @Test func rejectsInvalidAndUnpricedSamples() {
        for snapshot in [
            self.snapshot(total: -1), self.snapshot(
                total: 9999,
                priced: 10000),
            self.snapshot(cost: .nan), self.snapshot(cost: .infinity), self.snapshot(cost: -1),
            self.snapshot(cost: 0), self.snapshot(cost: nil),
            self.snapshot(currency: "EUR"), self.snapshot(provenance: .unknown),
            self.snapshot(provenance: .vendorMetered),
            self.snapshot(updatedAt: self.now.addingTimeInterval(-86401)),
            self.snapshot(updatedAt: self.now.addingTimeInterval(301)),
            self.snapshot(date: "2026-01-01"), self.snapshot(date: "2026-09-13"),
        ] {
            #expect(MidasCodexCalibration.make(
                snapshot: snapshot,
                now: self.now) == nil)
        }
    }

    @Test func noHistoryAndZeroTokensRemainUnavailable() {
        #expect(MidasCodexCalibration.make(
            snapshot: self.snapshot(
                total: 0,
                priced: 0,
                cost: 0),
            now: self.now) == nil)
        let empty = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            costProvenance: .listPriceEstimate,
            daily: [],
            updatedAt: self.now)
        #expect(MidasCodexCalibration.make(
            snapshot: empty,
            now: self.now) == nil)
    }

    @Test func rateExpiresWithoutFreshCalibration() throws {
        let sample = try #require(MidasCodexCalibration.make(
            snapshot: self.snapshot(),
            now: self.now))
        #expect(sample.estimate(now: self.now.addingTimeInterval(86400)) != nil)
        #expect(sample.estimate(now: self.now.addingTimeInterval(86401)) == nil)
        let oldUsage = MidasCodexCalibration(
            rate: 2,
            pricedTokens: 10000,
            observedTokens: 10000,
            sampledAt: self.now,
            lastUsageDay: "2026-01-01")
        #expect(oldUsage.estimate(now: self.now) == nil)
        let invalid = MidasCodexCalibration(
            rate: .infinity,
            pricedTokens: 10000,
            observedTokens: 10000,
            sampledAt: self.now,
            lastUsageDay: "2026-09-10")
        #expect(invalid.estimate(now: self.now) == nil)
    }
}
