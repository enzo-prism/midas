import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MidasDGXSparkPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_792_285_200) // 2026-10-18 01:00 UTC.

    @Test func localIdentityNeverInheritsACloudQuotaOrAccount() {
        let snapshot = UsageSnapshot(
            primary: .init(usedPercent: 50, windowMinutes: 10080, resetsAt: nil, resetDescription: "Next week"),
            secondary: nil,
            updatedAt: self.now,
            identity: .init(
                providerID: .localInference,
                accountEmail: "cloud@example.com",
                accountOrganization: "Cloud account",
                loginMethod: "Subscription"))
        let item = MidasProviderPresentation.make(
            provider: .localInference,
            card: nil,
            snapshot: snapshot,
            tokenSnapshot: nil,
            isRefreshing: false,
            isStale: true)
        #expect(item.name == "DGX Spark")
        #expect(item.account.isEmpty)
        #expect(item.plan == nil)
        #expect(item.hero == nil)
        #expect(item.metrics.isEmpty)
        #expect(item.orbitQuota == nil)
        #expect(item.resetCreditsText == nil)
        #expect(item.error == nil)
        #expect(item.dgxSpark != nil)
        #expect(ProviderDefaults.metadata[.localInference]?.displayName == "DGX Spark")
    }

    @Test func fixedThirtyDayUTCRangeIgnoresRollingFieldsAndOlderRows() throws {
        let rows = [
            self.day("2026-09-18", input: 9_000_000, cached: 0, output: 1_000_000),
            self.day("2026-09-19", input: 70, cached: 20, output: 30),
            self.day("2026-10-18", input: 140, cached: 40, output: 60),
            self.day("2026-10-19", input: 9_000_000, cached: 0, output: 1_000_000),
        ]
        let snapshot = DGXSparkPricing.project(snapshot: self.snapshot(rows), now: self.now)
        let model = MidasDGXSparkPresentation.make(snapshot: snapshot, now: self.now)
        #expect(model.range?.start == "2026-09-19")
        #expect(model.range?.end == "2026-10-18")
        #expect(model.tokens == 300)
        #expect(model.inputTokens == 210)
        #expect(model.cachedInputTokens == 60)
        #expect(model.outputTokens == 90)
        #expect(model.pricedTokens == 300)
        #expect(model.hasVerifiedModel)
        #expect(!model.hasUnpricedUsage)
        #expect(try abs(#require(model.amount) - 0.000078) < 0.000000001)
        // The aggregate may still select a different period without mutating the Spark card.
        let month = MidasSpendPeriod.month(year: 2026, month: 10)
            .tokens(snapshot: snapshot, timeZone: MidasSpendPeriod.utc, now: self.now)?.tokens
        #expect(month == 200)
        #expect(model.tokens == 300)
    }

    @Test func tinyKnownValueIsNeverRoundedToZero() throws {
        let snapshot = DGXSparkPricing.project(
            snapshot: self.snapshot([self.day("2026-10-18", input: 7, cached: 0, output: 1)]),
            now: self.now)
        let model = MidasDGXSparkPresentation.make(snapshot: snapshot, now: self.now)
        #expect(model.tokens == 8)
        #expect(model.valueText.hasPrefix("<"))
        #expect(try #require(model.preciseValueText).contains("0.0000019"))
        let spend = try #require(MidasSpendPresentation.make(provider: .localInference, snapshot: snapshot))
        #expect(spend.title == "API-equivalent value")
        #expect(spend.isEstimate)
        #expect(spend.value.hasPrefix("<"))
        #expect(spend.detail.contains("not a bill"))
    }

    @Test func unverifiedHistoricalTokensRemainVisibleAndUnpriced() {
        let unknown = CostUsageDailyReport.Entry(
            date: "2026-10-18",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 8,
            costUSD: nil,
            modelsUsed: ["local-runtime"],
            modelBreakdowns: nil)
        let model = MidasDGXSparkPresentation.make(
            snapshot: DGXSparkPricing.project(snapshot: self.snapshot([unknown]), now: self.now),
            now: self.now)
        #expect(model.tokens == 8)
        #expect(model.amount == nil)
        #expect(model.valueText == "—")
        #expect(model.hasUnpricedUsage)
        #expect(!model.hasVerifiedModel)
        #expect(model.modelText == "Model not verified")
        #expect(model.inputTokens == nil)
        #expect(model.pricedTokens == 0)
        #expect(model.pricingCoverageText == "0 of 8 tokens priced")
    }

    @Test(arguments: [false, true])
    func pricingCoverageNamesOnlyTheValuedTokenSubset(sameDay: Bool) throws {
        let known = self.day("2026-10-18", input: 80000, cached: 60000, output: 3000)
        let unknown = CostUsageDailyReport.Entry(
            date: "2026-10-17",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 1_317_000,
            costUSD: nil,
            modelsUsed: ["local-runtime"],
            modelBreakdowns: [.init(modelName: "local-runtime", costUSD: nil, totalTokens: 1_317_000)])
        let rows: [CostUsageDailyReport.Entry] = if sameDay {
            [.init(
                date: "2026-10-18",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: 1_400_000,
                costUSD: nil,
                modelsUsed: [DGXSparkPricing.modelID, "local-runtime"],
                modelBreakdowns: (known.modelBreakdowns ?? []) + (unknown.modelBreakdowns ?? []))]
        } else {
            [unknown, known]
        }
        let valued = DGXSparkPricing.project(snapshot: self.snapshot(rows), now: self.now)
        let model = MidasDGXSparkPresentation.make(snapshot: valued, now: self.now)
        #expect(model.tokens == 1_400_000)
        #expect(model.pricedTokens == 83000)
        #expect(model.pricingCoverageText == "\(83000.formatted()) of \(1_400_000.formatted()) tokens priced")
        #expect(model.hasUnpricedUsage)
        #expect(try abs(#require(model.amount) - 0.0085) < 0.000000001)
    }

    @Test func conflictingDailyTotalsDoNotClaimAPricedTokenCount() {
        let row = self.day("2026-10-18", input: 7, cached: 0, output: 1)
        let valued = DGXSparkPricing.project(snapshot: self.snapshot([row, row]), now: self.now)
        let model = MidasDGXSparkPresentation.make(snapshot: valued, now: self.now)
        #expect(model.tokens == nil)
        #expect(model.pricedTokens == nil)
        #expect(model.pricingCoverageText == "Pricing coverage unavailable")
    }

    @Test func localAPIEquivalentValuePreservesCentsAboveOneDollar() throws {
        let snapshot = DGXSparkPricing.project(
            snapshot: self.snapshot([
                self.day("2026-10-18", input: 12_000_000, cached: 9_000_000, output: 400_000),
            ]),
            now: self.now)
        let model = MidasDGXSparkPresentation.make(snapshot: snapshot, now: self.now)
        let expected = 1.25.formatted(.currency(code: "USD"))
        #expect(model.valueText == expected)
        #expect(model.preciseValueText == expected)
        let spend = try #require(MidasSpendPresentation.make(provider: .localInference, snapshot: snapshot))
        #expect(spend.value == expected)
        #expect(spend.amount == 1.25)
    }

    @Test func missingAndExplicitZeroAreDifferent() {
        let absent = MidasDGXSparkPresentation.make(snapshot: nil, now: self.now)
        #expect(absent.tokens == nil)
        #expect(absent.tokenText == "—")
        #expect(absent.amount == nil)
        #expect(absent.updatedAt == nil)
        #expect(absent.pricedTokens == nil)
        let zero = MidasDGXSparkPresentation.make(
            snapshot: DGXSparkPricing.project(
                snapshot: self.snapshot([self.day("2026-10-18", input: 0, cached: 0, output: 0)]),
                now: self.now),
            now: self.now)
        #expect(zero.tokens == 0)
        #expect(zero.amount == 0)
        #expect(zero.pricedTokens == 0)
        #expect(!zero.valueText.hasPrefix("<"))
    }

    @Test func breakdownDoesNotDisplayIncompleteSubtotalOrOverflow() {
        let incomplete = CostUsageDailyReport.Entry(
            date: "2026-10-17",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 8,
            costUSD: nil,
            modelsUsed: nil,
            modelBreakdowns: nil)
        let model = MidasDGXSparkPresentation.make(
            snapshot: self.snapshot([
                incomplete, self.day("2026-10-18", input: 70, cached: 20, output: 30),
            ]),
            now: self.now)
        #expect(model.tokens == 108)
        #expect(model.inputTokens == nil)
        #expect(model.cachedInputTokens == nil)
        #expect(model.outputTokens == nil)
        let overflow = MidasDGXSparkPresentation.make(
            snapshot: self.snapshot([
                self.day("2026-10-17", input: Int.max, cached: 0, output: 0),
                self.day("2026-10-18", input: 1, cached: 0, output: 0),
            ]),
            now: self.now)
        #expect(overflow.tokens == nil)
        #expect(overflow.inputTokens == nil)
        #expect(overflow.pricedTokens == nil)
    }

    @Test func sparkMenuBarDescriptionHasActivityAndNoCloudQuotaLanguage() {
        var item = MidasProviderPresentation.make(
            provider: .localInference,
            card: nil,
            snapshot: nil,
            tokenSnapshot: nil,
            isRefreshing: false,
            isStale: false)
        item.dgxSpark = MidasDGXSparkPresentation.make(
            snapshot: DGXSparkPricing.project(
                snapshot: self.snapshot([self.day("2026-10-18", input: 7, cached: 0, output: 1)]),
                now: self.now),
            now: self.now)
        for mode in [MidasMenuBarMode.focus, .constellation] {
            for hidden in [false, true] {
                let presentation = MidasMenuBarPresentation(
                    mode: mode,
                    presentations: [item],
                    focusProvider: .localInference,
                    refreshingProviders: [],
                    hideSpend: hidden,
                    now: self.now)
                #expect(presentation.title == "DG 8")
                #expect(presentation.tooltip.contains("8 recorded tokens"))
                #expect(!presentation.tooltip.contains("quota"))
                #expect(!presentation.tooltip.contains("percent"))
                if hidden { #expect(!presentation.tooltip.contains("$")) }
            }
        }
    }

    @Test func compactSparkAccessibilityRetainsItsOwnLastReceivedStatus() {
        let priced = DGXSparkPricing.project(
            snapshot: self.snapshot([self.day("2026-10-18", input: 7, cached: 0, output: 1)]),
            now: self.now)
        let stale = MidasDGXSparkPresentation.make(snapshot: priced, now: self.now.addingTimeInterval(3600))
        var item = MidasProviderPresentation.make(
            provider: .localInference,
            card: nil,
            snapshot: nil,
            tokenSnapshot: nil,
            isRefreshing: false,
            isStale: false)
        item.dgxSpark = stale
        let summary = MidasCompactAccessibility.summary(item)
        #expect(stale.isStale)
        #expect(!item.isStale)
        for text in ["Last received", "8 recorded tokens", "8 of 8 tokens priced", "API-equivalent", "not a bill"] {
            #expect(summary.contains(text))
        }
        #expect(!summary.contains("Limit unavailable"))
        #expect(!summary.localizedCaseInsensitiveContains("quota"))
        #expect(!summary.contains("%"))
    }

    @Test func compactSparkAccessibilityUsesFixedThirtyDayValueInsteadOfSelectedMonth() throws {
        let priced = DGXSparkPricing.project(
            snapshot: self.snapshot([
                self.day("2026-09-18", input: 120_000_000, cached: 90_000_000, output: 4_000_000),
                self.day("2026-10-18", input: 12_000_000, cached: 9_000_000, output: 400_000),
            ]),
            now: self.now)
        let spark = MidasDGXSparkPresentation.make(snapshot: priced, now: self.now)
        let selectedAmount = try #require(MidasSpendPeriod.month(year: 2026, month: 9)
            .amount(snapshot: priced, timeZone: MidasSpendPeriod.utc, now: self.now)?.dollars)
        #expect(selectedAmount == 12.50)
        #expect(spark.amount == 1.25)
        var item = MidasProviderPresentation.make(
            provider: .localInference,
            card: nil,
            snapshot: nil,
            tokenSnapshot: nil,
            isRefreshing: false,
            isStale: false)
        item.dgxSpark = spark
        item.spend = MidasSpendPresentation(
            title: "API-equivalent value",
            value: selectedAmount.formatted(.currency(code: "USD")),
            period: "Sep 2026",
            detail: "Selected-month aggregate remains separate from the Spark's rolling window.",
            updatedAt: self.now,
            amount: selectedAmount,
            currency: "USD",
            secondaryValue: nil,
            secondaryLabel: nil,
            isEstimate: true)
        let summary = MidasCompactAccessibility.summary(item)
        #expect(summary.contains(MidasOverviewMoney.format(1.25, currency: "USD")))
        #expect(!summary.contains(MidasOverviewMoney.format(selectedAmount, currency: "USD")))
        #expect(summary.localizedCaseInsensitiveContains("last 30 days UTC"))
        #expect(summary.contains("API-equivalent"))
        #expect(summary.contains("not a bill"))
        #expect(!summary.contains("Limit unavailable"))
    }

    @Test func compactSparkAccessibilityKeepsMissingActivityDifferentFromKnownZero() {
        var item = MidasProviderPresentation.make(
            provider: .localInference,
            card: nil,
            snapshot: nil,
            tokenSnapshot: nil,
            isRefreshing: false,
            isStale: false)
        item.dgxSpark = MidasDGXSparkPresentation.make(snapshot: nil, now: self.now)
        let missing = MidasCompactAccessibility.summary(item)
        #expect(missing.contains("Unavailable"))
        #expect(missing.contains("Waiting for recorded usage"))
        #expect(!missing.contains("0 recorded tokens"))
        item.dgxSpark = MidasDGXSparkPresentation.make(
            snapshot: DGXSparkPricing.project(
                snapshot: self.snapshot([self.day("2026-10-18", input: 0, cached: 0, output: 0)]),
                now: self.now),
            now: self.now)
        let zero = MidasCompactAccessibility.summary(item)
        #expect(zero.contains("0 recorded tokens"))
        #expect(zero.contains(MidasOverviewMoney.format(0, currency: "USD")))
        #expect(!zero.contains("Limit unavailable"))
    }

    private func day(_ date: String, input: Int, cached: Int, output: Int) -> CostUsageDailyReport.Entry {
        .init(
            date: date,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cached,
            totalTokens: input + output,
            costUSD: nil,
            modelsUsed: [DGXSparkPricing.modelID],
            modelBreakdowns: [.init(
                modelName: DGXSparkPricing.modelID,
                costUSD: nil,
                totalTokens: input + output,
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cached)])
    }

    private func snapshot(_ rows: [CostUsageDailyReport.Entry]) -> CostUsageTokenSnapshot {
        .init(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 999_999_999,
            last30DaysCostUSD: nil,
            historyDays: 365,
            daily: rows,
            updatedAt: self.now)
    }
}
