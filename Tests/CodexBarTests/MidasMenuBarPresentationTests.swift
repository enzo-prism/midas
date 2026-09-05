import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct MidasMenuBarPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_788_523_200)

    @Test func focusCodexShowsWeeklyNeverSessionOrDollars() {
        let model = self.model(
            .focus,
            items: [self.item(
                .codex,
                remaining: 72,
                amount: 10)])
        #expect(model.title == "C 72%")
        #expect(model.tooltip.contains("Token spend (API rates)"))
        #expect(model.width == 120)
    }

    @Test func missingWeeklyDoesNotFallBackToSession() {
        let item = self.item(
            .codex,
            remaining: nil)
        #expect(self.model(
            .focus,
            items: [item]).title == "C —")
        #expect(self.model(
            .focus,
            items: [item]).tooltip.contains("weekly quota unavailable"))
    }

    @Test func ledgerDistinguishesUnavailableZeroAndTinyPositiveSpend() {
        #expect(self.model(
            .ledger,
            items: [self.item(
                .codex,
                amount: nil)]).title == "—")
        #expect(self.model(
            .ledger,
            items: [self.item(
                .codex,
                amount: 0)]).title == "≈$0")
        #expect(self.model(
            .ledger,
            items: [self.item(
                .codex,
                amount: 0.04)]).title == "≈$0.04")
    }

    @Test func ledgerCompactsLargeValuesButExposesExactAmountsAndCoverage() {
        let model = self.model(
            .ledger,
            items: [
                self.item(
                    .codex,
                    amount: 12345.67), self.item(
                    .cursor,
                    amount: nil),
            ])
        #expect(model.title == "≈$12.3k")
        #expect(model.tooltip.contains(12345.67.formatted(.currency(code: "USD"))))
        #expect(model.tooltip.contains("1 of 2 providers"))
        #expect(model.isPartial)
        #expect(!model.isStale)
    }

    @Test func metaActivityRemainsAccessibleWhenSpendIsHidden() {
        var item = self.item(.meta)
        item.activitySummary = "12,000 tokens recorded"
        let model = self.model(.constellation, items: [item], hideSpend: true)
        #expect(model.accessibilityLabel.contains("12,000 tokens recorded"))
        #expect(model.tooltip.contains("quota unavailable"))
    }

    @Test func hideSpendRemovesDollarsFromEveryPublicString() {
        for mode in MidasMenuBarMode.allCases {
            let model = self.model(
                mode,
                items: [self.item(
                    .codex,
                    remaining: 70,
                    amount: 123.45)],
                hideSpend: true)
            for text in [model.title, model.tooltip, model.accessibilityLabel] {
                #expect(!text.contains("$"))
                #expect(!text.contains("123.45"))
                #expect(!text.contains("Token spend (API rates)"))
            }
        }
    }

    @Test func constellationPrioritizesDistinctProviderLettersWithoutMetaQuota() {
        let model = self.model(
            .constellation,
            items: [
                self.item(.claude), self.item(.meta), self.item(.cursor), self.item(
                    .codex,
                    remaining: 50),
            ])
        #expect(model.title == "C 50%  U —  M —")
        #expect(model.accessibilityLabel.contains("Codex"))
        #expect(model.accessibilityLabel.contains("Cursor"))
        #expect(model.accessibilityLabel.contains("Meta"))
        #expect(model.tooltip.contains("1 more providers"))
    }

    @Test func refreshAgeAndQuotaAttentionAreIndependent() {
        let healthy = self.item(
            .codex,
            remaining: 50)
        let aged = self.item(
            .codex,
            remaining: 50,
            age: 901)
        #expect(!self.model(
            .focus,
            items: [healthy]).isStale)
        #expect(self.model(
            .focus,
            items: [aged]).isStale)
        #expect(!self.model(
            .focus,
            items: [aged]).attention)
        #expect(self.model(
            .focus,
            items: [self.item(
                .codex,
                remaining: 10)]).attention)
        #expect(self.model(
            .focus,
            items: [self.item(
                .codex,
                remaining: 0)]).attention)
        let refresh = MidasMenuBarPresentation(
            mode: .focus,
            presentations: [healthy],
            focusProvider: .codex,
            refreshingProviders: [.codex],
            hideSpend: false,
            now: self.now)
        #expect(refresh.isRefreshing)
        #expect(refresh.title == "C 50%")
    }

    @Test func ledgerKeepsCurrenciesSeparate() {
        let model = self.model(
            .ledger,
            items: [
                self.item(
                    .codex,
                    amount: 10), self.item(
                    .mistral,
                    amount: 20,
                    currency: "EUR"),
            ])
        #expect(model.title == "≈2 FX")
        #expect(model.tooltip.contains("USD"))
        #expect(model.tooltip.contains("EUR"))
        #expect(!model.title.contains("$30"))
    }

    @Test func providerIncidentHasExplicitIdentityWithoutImplyingQuotaExhaustion() {
        let model = MidasMenuBarPresentation(
            mode: .focus,
            presentations: [self.item(
                .codex,
                remaining: 90)],
            focusProvider: .codex,
            refreshingProviders: [],
            hideSpend: false,
            now: self.now,
            incidentDescriptions: ["Codex: provider service degraded"])
        #expect(model.attention)
        #expect(model.title == "C 90%")
        #expect(model.tooltip.contains("Codex: provider service degraded"))
        #expect(model.accessibilityLabel.contains("Codex: provider service degraded"))
    }

    @Test func oldSpendDoesNotHideBehindAFreshQuotaTimestamp() {
        var item = self.item(
            .codex,
            remaining: 70,
            amount: 10)
        item.spend = MidasSpendPresentation.make(
            provider: .codex,
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: nil,
                last30DaysCostUSD: 10,
                costProvenance: .listPriceEstimate,
                daily: [],
                updatedAt: self.now.addingTimeInterval(-901)))
        #expect(self.model(
            .ledger,
            items: [item]).isStale)
        #expect(!self.model(
            .ledger,
            items: [item],
            hideSpend: true).isStale)
    }

    @Test func orbitPairsAllProviderSpendWithFavoriteWeeklyQuota() {
        let model = self.model(.orbit, items: [
            self.item(.codex, remaining: 72, amount: 10),
            self.item(.cursor, amount: 20),
        ])
        #expect(model.title == "$30")
        #expect(model.width == 110)
        #expect(model.orbitProvider == .codex)
        #expect(model.orbitRemainingPercent == 72)
        #expect(model.tooltip.contains("Favorite: Codex"))
        #expect(model.tooltip.contains("not billed charges"))
        #expect(model.tooltip.contains("2 providers"))
    }

    @Test func orbitNeverSubstitutesAnAvailableProviderForMissingFavorite() {
        let model = self.model(.orbit, items: [self.item(.cursor, amount: 20)])
        #expect(model.title == "$20")
        #expect(model.orbitProvider == .codex)
        #expect(model.orbitRemainingPercent == nil)
        #expect(model.tooltip.contains("Codex: unavailable"))
    }

    @Test func orbitRingIgnoresOtherProviderIncidentRefreshAndAge() {
        let model = MidasMenuBarPresentation(
            mode: .orbit,
            presentations: [self.item(.codex, remaining: 72, amount: 10), self.item(.cursor, amount: 20, age: 1800)],
            focusProvider: .codex,
            refreshingProviders: [.cursor],
            hideSpend: false,
            now: self.now,
            incidentDescriptions: ["Cursor outage"],
            incidentDescriptionsByProvider: [.cursor: "Cursor outage"])
        #expect(!model.attention)
        #expect(!model.isRefreshing)
        #expect(!model.isStale)
        #expect(!model.tooltip.contains("Cursor outage"))
    }

    @Test func orbitRingReportsFavoriteIncidentWithoutChangingMeasuredQuota() {
        let model = MidasMenuBarPresentation(
            mode: .orbit,
            presentations: [self.item(.codex, remaining: 72, amount: 10)],
            focusProvider: .codex,
            refreshingProviders: [.codex],
            hideSpend: false,
            now: self.now,
            incidentDescriptionsByProvider: [.codex: "Codex service degraded"])
        #expect(model.attention)
        #expect(model.isRefreshing)
        #expect(model.orbitRemainingPercent == 72)
        #expect(model.tooltip.contains("Codex service degraded"))
    }

    @Test func orbitMetaRemainsNeutralAndPrivacyHidesAmounts() {
        let model = MidasMenuBarPresentation(
            mode: .orbit,
            presentations: [self.item(.meta, amount: 42)],
            focusProvider: .meta,
            refreshingProviders: [],
            hideSpend: true,
            now: self.now)
        #expect(model.orbitProvider == .meta)
        #expect(model.orbitRemainingPercent == nil)
        #expect(model.title == "••••")
        #expect(!model.tooltip.contains("$"))
        #expect(!model.accessibilityLabel.contains("$"))
        #expect(model.tooltip.contains("Token spend hidden"))
    }

    private func model(
        _ mode: MidasMenuBarMode,
        items: [MidasProviderPresentation],
        hideSpend: Bool = false)
        -> MidasMenuBarPresentation
    {
        .init(
            mode: mode,
            presentations: items,
            focusProvider: .codex,
            refreshingProviders: [],
            hideSpend: hideSpend,
            now: self.now)
    }

    private func item(
        _ provider: UsageProvider,
        remaining: Double? = nil,
        amount: Double? = nil,
        age: TimeInterval = 0,
        currency: String = "USD") -> MidasProviderPresentation
    {
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: remaining.map {
                RateWindow(
                    usedPercent: 100 - $0,
                    windowMinutes: 10080,
                    resetsAt: nil,
                    resetDescription: nil)
            },
            updatedAt: self.now.addingTimeInterval(-age))
        return .make(
            provider: provider,
            card: nil,
            snapshot: snapshot,
            tokenSnapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: nil,
                last30DaysCostUSD: amount,
                currencyCode: currency,
                costProvenance: .listPriceEstimate,
                daily: [],
                updatedAt: self.now),
            isRefreshing: false,
            isStale: false)
    }
}
