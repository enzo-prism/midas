import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct MidasOrbitQuotaTests {
    private func window(_ used: Double, minutes: Int? = 10080) -> RateWindow {
        RateWindow(usedPercent: used, windowMinutes: minutes, resetsAt: nil, resetDescription: nil)
    }

    private func item(
        _ provider: UsageProvider,
        primary: RateWindow? = nil,
        secondary: RateWindow? = nil,
        tertiary: RateWindow? = nil,
        extras: [NamedRateWindow] = []) -> MidasProviderPresentation
    {
        let snapshot = UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            extraRateWindows: extras,
            updatedAt: Date())
        let card = ProviderDefaults.metadata[provider].flatMap { metadata -> UsageMenuCardView.Model? in
            guard [primary, secondary, tertiary].compactMap(\.self).allSatisfy(\.usedPercent.isFinite) else {
                return nil
            }
            return UsageMenuCardView.Model.make(.init(
                provider: provider,
                metadata: metadata,
                snapshot: snapshot,
                credits: nil,
                creditsError: nil,
                dashboard: nil,
                dashboardError: nil,
                tokenSnapshot: nil,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: nil),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: false,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: true,
                hidePersonalInfo: false,
                now: snapshot.updatedAt))
        }
        return .make(
            provider: provider,
            card: card,
            snapshot: snapshot,
            tokenSnapshot: nil,
            isRefreshing: false,
            isStale: false)
    }

    private func orbit(_ item: MidasProviderPresentation) -> MidasMenuBarPresentation {
        .init(
            mode: .orbit,
            presentations: [item],
            focusProvider: item.provider,
            refreshingProviders: [],
            hideSpend: true)
    }

    @Test func claudeWeeklyAloneControlsRingWarningAndDescription() {
        let item = self.item(
            .claude,
            primary: self.window(100, minutes: 300),
            secondary: self.window(28),
            tertiary: self.window(100),
            extras: [.init(id: "claude-weekly-scoped-fable", title: "Fable only", window: self.window(100))])
        #expect(item.hero?.title == "5-hour limit")
        #expect(item.hero?.remainingPercent == 0)
        #expect(item.metrics.contains { $0.title == "Fable weekly limit" && $0.remainingPercent == 0 })
        let model = self.orbit(item)
        #expect(model.orbitRemainingPercent == 72)
        #expect(!model.attention)
        #expect(model.accessibilityLabel.contains("72 percent remaining, Weekly limit"))
        #expect(!model.accessibilityLabel.contains("Fable"))
        #expect(!model.tooltip.contains("Session"))
        let focus = MidasMenuBarPresentation(
            mode: .focus,
            presentations: [item],
            focusProvider: .claude,
            refreshingProviders: [],
            hideSpend: true)
        #expect(focus.attention)
        #expect(focus.tooltip.contains("Fable weekly limit"))
    }

    @Test func claudeAmbiguousPrimaryAndScopedOnlyWeeklyStayUnavailable() {
        for primary in [self.window(10), self.window(10, minutes: 300)] {
            let item = self.item(.claude, primary: primary, tertiary: self.window(100))
            #expect(item.orbitQuota == nil)
            #expect(!self.orbit(item).attention)
            #expect(self.orbit(item).tooltip.contains("weekly quota unavailable"))
        }
        #expect(self.item(.claude, secondary: self.window(20, minutes: nil)).orbitQuota?.remainingPercent == 80)
        #expect(self.item(.claude, secondary: self.window(20, minutes: 300)).orbitQuota == nil)
    }

    @Test func cursorUsesOnlyTotalMonthlyAndNeverPoolsOrGrokBot() {
        let extras = [
            NamedRateWindow(id: "cursor-grok-bot", title: "Grok Bot weekly", window: self.window(100)),
            NamedRateWindow(id: "cursor-pool-other", title: "Other Models", window: self.window(100, minutes: 43200)),
        ]
        let item = self.item(.cursor, primary: self.window(35, minutes: 43200), extras: extras)
        #expect(item.metrics.contains { $0.id == "cursor-pool-other" && $0.remainingPercent == 0 })
        #expect(item.metrics.contains { $0.id == "cursor-grok-bot" && $0.remainingPercent == 0 })
        #expect(item.orbitQuota?.title == "Monthly limit")
        #expect(self.orbit(item).orbitRemainingPercent == 65)
        #expect(!self.orbit(item).attention)
        let missing = self.item(.cursor, secondary: self.window(100), extras: extras)
        #expect(missing.orbitQuota == nil)
        #expect(!self.orbit(missing).attention)
        #expect(self.orbit(missing).tooltip.contains("monthly quota unavailable"))
    }

    @Test func cursorAcceptsCalendarMonthsButRejectsExplicitShortOrAnnualWindows() {
        for minutes: Int? in [nil, 28 * 1440, 29 * 1440, 30 * 1440, 31 * 1440, 30 * 1440 - 60] {
            #expect(self.item(.cursor, primary: self.window(28, minutes: minutes)).orbitQuota?.remainingPercent == 72)
        }
        for minutes in [300, 10080, 365 * 1440] {
            #expect(self.item(.cursor, primary: self.window(28, minutes: minutes)).orbitQuota == nil)
        }
    }

    @Test func knownZeroFullAndInvalidReadingsStayDistinctAcrossProviders() {
        for provider in [UsageProvider.codex, .claude, .cursor, .kimi] {
            for used in [0.0, 90, 100, -10, 110, .nan, .infinity, -.infinity] {
                let primary = provider == .cursor || provider == .kimi
                    ? self.window(used, minutes: provider == .cursor ? 43200 : 10080) : nil
                let secondary = primary == nil ? self.window(used) : nil
                let model = self.orbit(self.item(provider, primary: primary, secondary: secondary))
                if used.isFinite {
                    #expect(model.orbitRemainingPercent == min(100, max(0, 100 - used)))
                    #expect(model.attention == (used >= 90))
                } else {
                    #expect(model.orbitRemainingPercent == nil)
                    #expect(!model.attention)
                }
            }
            #expect(self.item(provider).orbitQuota == nil)
        }
    }

    @Test func codexUsesSemanticWeekInEitherSlotWithoutSessionFallback() {
        #expect(self.item(.codex, primary: self.window(28)).orbitQuota?.remainingPercent == 72)
        let item = self.item(.codex, primary: self.window(100, minutes: 300), secondary: self.window(28))
        #expect(self.orbit(item).orbitRemainingPercent == 72)
        #expect(!self.orbit(item).attention)
        #expect(self.item(.codex, primary: self.window(100, minutes: 300)).orbitQuota == nil)
    }

    @Test func invalidPresentationQuotaNeverBecomesARingOrWarning() {
        for value in [Double.nan, .infinity, -.infinity] {
            var item = self.item(.claude, secondary: self.window(28))
            item.orbitQuota = MidasQuotaMetric(
                id: "secondary", title: "Weekly limit", remainingPercent: value, resetText: nil, helpText: nil)
            #expect(self.orbit(item).orbitRemainingPercent == nil)
            #expect(!self.orbit(item).attention)
        }
    }

    @Test func orbitSelectionDoesNotChangePanelSessionAndScopedMetrics() {
        let item = self.item(.codex, primary: self.window(100, minutes: 300), secondary: self.window(28))
        #expect(item.hero?.remainingPercent == 72)
        #expect(item.metrics.first { $0.id == "primary" }?.remainingPercent == 0)
        let focus = MidasMenuBarPresentation(
            mode: .focus,
            presentations: [item],
            focusProvider: .codex,
            refreshingProviders: [],
            hideSpend: true)
        #expect(focus.attention)
        #expect(focus.tooltip.contains("Session"))
        #expect(!self.orbit(item).attention)
        #expect(!self.orbit(item).tooltip.contains("Session"))
    }

    @Test func providerErrorsAndIncidentsStillWarnWithHealthyWeeklyQuota() {
        let healthy = self.item(.claude, secondary: self.window(28))
        let failed = MidasProviderPresentation(
            provider: healthy.provider,
            name: healthy.name,
            account: "",
            plan: nil,
            hero: healthy.hero,
            metrics: healthy.metrics,
            orbitQuota: healthy.orbitQuota,
            resetCreditsText: nil,
            resetCreditsHelp: nil,
            freshness: "Last known usage",
            error: "Refresh failed",
            placeholder: nil,
            notes: [],
            financialSummary: nil,
            financialLabel: nil,
            isRefreshing: false,
            isStale: false,
            updatedAt: Date())
        #expect(self.orbit(failed).attention)
        #expect(self.orbit(failed).orbitRemainingPercent == 72)
        #expect(self.orbit(failed).tooltip.contains("refresh failed"))
        let incident = MidasMenuBarPresentation(
            mode: .orbit,
            presentations: [healthy],
            focusProvider: .claude,
            refreshingProviders: [],
            hideSpend: true,
            incidentDescriptionsByProvider: [.claude: "Claude service degraded"])
        #expect(incident.attention)
        #expect(incident.orbitRemainingPercent == 72)
        #expect(incident.tooltip.contains("Claude service degraded"))
    }

    @Test func otherProvidersRequireAnExplicitOverallWeek() {
        #expect(self.item(.kimi, primary: self.window(28)).orbitQuota?.remainingPercent == 72)
        #expect(self.item(.grok, primary: self.window(28)).orbitQuota?.remainingPercent == 72)
        #expect(self.item(.ollama, secondary: self.window(28)).orbitQuota?.remainingPercent == 72)
        for provider in [UsageProvider.antigravity, .gemini, .factory, .meta] {
            #expect(self.item(provider, primary: self.window(100), secondary: self.window(100)).orbitQuota == nil)
        }
        #expect(self.item(.kimi, primary: self.window(28, minutes: nil)).orbitQuota == nil)
        #expect(self.item(.grok, primary: self.window(28, minutes: 43200)).orbitQuota == nil)
    }
}
