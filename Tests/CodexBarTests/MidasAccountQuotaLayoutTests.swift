import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MidasAccountQuotaLayoutTests {
    private func presentation(weeklyUsed: Double?, sessionUsed: Double?) -> MidasProviderPresentation {
        func window(_ used: Double, minutes: Int) -> RateWindow {
            RateWindow(usedPercent: used, windowMinutes: minutes, resetsAt: nil, resetDescription: nil)
        }
        return MidasProviderPresentation.make(
            provider: .codex,
            card: nil,
            snapshot: UsageSnapshot(
                primary: sessionUsed.map { window($0, minutes: 300) },
                secondary: weeklyUsed.map { window($0, minutes: 10080) },
                updatedAt: Date()),
            tokenSnapshot: nil,
            isRefreshing: false,
            isStale: false)
    }

    @Test func exhaustedSessionCannotHideBehindHealthyWeeklyQuota() {
        let metrics = MidasAccountQuotaLayout.overviewMetrics(
            self.presentation(weeklyUsed: 10, sessionUsed: 100))
        #expect(metrics.map(\.id) == ["secondary", "primary"])
        #expect(metrics.last?.remainingPercent == 0)
    }

    @Test func lessRestrictiveSessionStaysInDetails() {
        let presentation = self.presentation(weeklyUsed: 96, sessionUsed: 10)
        #expect(MidasAccountQuotaLayout.overviewMetrics(presentation).map(\.id) == ["secondary"])
        #expect(MidasAccountQuotaLayout.allMetrics(presentation).map(\.id) == ["secondary", "primary"])
    }

    @Test func similarHealthyWindowsStayCompact() {
        let presentation = self.presentation(weeklyUsed: 10, sessionUsed: 20)
        #expect(MidasAccountQuotaLayout.overviewMetrics(presentation).map(\.id) == ["secondary"])
    }

    @Test func materialRestrictionAndLowBalanceRemainVisible() {
        let material = self.presentation(weeklyUsed: 10, sessionUsed: 30)
        #expect(MidasAccountQuotaLayout.overviewMetrics(material).map(\.id) == ["secondary", "primary"])
        let low = self.presentation(weeklyUsed: 85, sessionUsed: 90)
        #expect(MidasAccountQuotaLayout.overviewMetrics(low).map(\.id) == ["secondary", "primary"])
    }

    @Test func absentWeeklyRetainsExplicitSessionLabel() {
        let metrics = MidasAccountQuotaLayout.overviewMetrics(
            self.presentation(weeklyUsed: nil, sessionUsed: 30))
        #expect(metrics.map(\.id) == ["primary"])
        #expect(metrics.first.map { MidasAccountQuotaLayout.resetLine($0, includesWindow: true) }
            == "Session · Reset unavailable")
    }

    @Test func missingResetIsExplicitAndWindowIsNotRepeatedInDetails() {
        let metric = MidasQuotaMetric(
            id: "secondary",
            title: "This week",
            remainingPercent: 90,
            resetText: " ",
            helpText: nil)
        #expect(MidasAccountQuotaLayout.resetLine(metric, includesWindow: true) == "Weekly · Reset unavailable")
        #expect(MidasAccountQuotaLayout.resetLine(metric, includesWindow: false) == "Reset unavailable")
    }

    @Test func expiredResetRetainsRecordedBalanceUntilFreshDataArrives() {
        let now = Date(timeIntervalSince1970: 1000)
        let metric = MidasQuotaMetric(
            id: "secondary",
            title: "This week",
            remainingPercent: 4,
            resetText: "Resets now",
            helpText: nil,
            resetsAt: now.addingTimeInterval(-60))
        #expect(MidasAccountQuotaLayout.resetLine(metric, includesWindow: true, now: now)
            == "Weekly · Reset pending update")
        #expect(metric.remainingPercent == 4)
    }

    @Test func accountNamesUseAliasesAndShortenOnlyUnambiguousIdentities() {
        let names = MidasAccountNames.resolve(
            identities: [("a", "enzo@one.example"), ("b", "enzo@two.example"), ("c", "unique@three.example")],
            provider: .codex,
            aliases: [:])
        #expect(names["a"] == "enzo@one.example")
        #expect(names["b"] == "enzo@two.example")
        #expect(names["c"] == "unique")
        let aliased = MidasAccountNames.resolve(
            identities: [("a", "enzo@one.example"), ("b", "enzo@two.example")],
            provider: .codex,
            aliases: ["codex:a": "Personal", "cursor:b": "Wrong provider"])
        #expect(aliased["a"] == "Personal")
        #expect(aliased["b"] == "enzo")
    }

    @Test func privacyHidesBothIdentitiesAndCustomAliases() {
        let names = MidasAccountNames.resolve(
            identities: [("a", "private@one.example"), ("b", "sensitive@two.example")],
            provider: .codex,
            aliases: ["codex:a": "Secret client", "codex:b": "Private workspace"],
            hidePersonalInfo: true)
        #expect(names == ["a": "Account 1", "b": "Account 2"])
        #expect(!names.values.joined().contains("private"))
        #expect(!names.values.joined().contains("Secret"))
    }
}
