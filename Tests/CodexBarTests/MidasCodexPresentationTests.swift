import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MidasCodexPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(weekly: Double? = 28, extra: [NamedRateWindow]? = nil) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 99,
                windowMinutes: 300,
                resetsAt: self.now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: weekly.map {
                RateWindow(
                    usedPercent: $0,
                    windowMinutes: 10080,
                    resetsAt: self.now.addingTimeInterval(172_800),
                    resetDescription: nil)
            },
            extraRateWindows: extra,
            codexResetCredits: .countOnly(availableCount: 2, updatedAt: self.now),
            updatedAt: self.now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "fixture@example.com",
                accountOrganization: nil,
                loginMethod: "Plus"))
    }

    private func card(_ snapshot: UsageSnapshot, showUsed: Bool = false) throws -> UsageMenuCardView.Model {
        let projection = CodexConsumerProjection.make(
            surface: .liveCard,
            context: .init(
                snapshot: snapshot,
                rawUsageError: nil,
                liveCredits: nil,
                rawCreditsError: nil,
                liveDashboard: nil,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false,
                now: self.now))
        return try UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: #require(ProviderDefaults.metadata[.codex]),
            snapshot: snapshot,
            codexProjection: projection,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "other@example.com", plan: "Wrong account"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: showUsed,
            resetTimeDisplayStyle: .absolute,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            now: self.now))
    }

    private func present(_ snapshot: UsageSnapshot, card: UsageMenuCardView.Model) -> MidasProviderPresentation {
        MidasProviderPresentation.make(
            provider: .codex,
            card: card,
            snapshot: snapshot,
            tokenSnapshot: nil,
            isRefreshing: false,
            isStale: false)
    }

    @Test func resetTimingKeepsAbsoluteDisplayPreference() throws {
        let snapshot = self.snapshot()
        let card = try self.card(snapshot)
        let result = self.present(snapshot, card: card)
        #expect(result.hero?.resetText == card.metrics.first(where: { $0.id == "secondary" })?.resetText)
        #expect(result.metrics.first(where: { $0.id == "primary" })?.resetText ==
            card.metrics.first(where: { $0.id == "primary" })?.resetText)
        #expect(result.hero?.helpText == snapshot.secondary?.resetsAt?.formatted(date: .complete, time: .shortened))
    }

    @Test func usedPreferenceCannotInvertCodexRemaining() throws {
        let snapshot = self.snapshot()
        let result = try self.present(snapshot, card: self.card(snapshot, showUsed: true))
        #expect(result.hero?.remainingPercent == 72)
        #expect(result.metrics.first(where: { $0.id == "primary" })?.remainingPercent == 1)
    }

    @Test func resetCreditsRemainCountWithoutWeeklyData() throws {
        let snapshot = self.snapshot(weekly: nil)
        let card = try self.card(snapshot)
        let result = self.present(snapshot, card: card)
        #expect(result.hero == nil)
        #expect(result.resetCreditsText == card.metrics.first(where: { $0.id == "codex-reset-credits" })?.statusText)
        #expect(result.resetCreditsText?.contains("2") == true)
        #expect(!result.metrics.contains(where: { $0.id == "codex-reset-credits" }))
    }

    @Test func redactedCardIdentityIsNeverReplacedWithRawSnapshotIdentity() throws {
        let snapshot = self.snapshot()
        let card = try self.card(snapshot)
        let result = self.present(snapshot, card: card)
        #expect(result.account == card.email)
        #expect(!result.account.contains("fixture@example.com"))
        #expect(!result.account.contains("other@example.com"))
        #expect(result.plan != "Wrong account")
    }

    @Test func unknownAdditionalQuotaStaysVisibleWithoutFakeExhaustion() throws {
        let extra = NamedRateWindow(
            id: "extra-fixture",
            title: "Additional quota",
            window: RateWindow(
                usedPercent: 100,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            usageKnown: false)
        let snapshot = self.snapshot(extra: [extra])
        let card = try self.card(snapshot)
        let result = self.present(snapshot, card: card)
        #expect(!result.metrics.contains(where: { $0.id == extra.id }))
        #expect(result.notes.contains(where: { $0.contains(extra.title) }))
    }
}
