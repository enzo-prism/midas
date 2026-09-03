import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexLimitProximityTests {
    private func makeProjection(
        primary: RateWindow?,
        secondary: RateWindow?,
        now: Date) -> CodexConsumerProjection
    {
        let snapshot: UsageSnapshot? = if primary == nil, secondary == nil {
            nil
        } else {
            UsageSnapshot(
                primary: primary,
                secondary: secondary,
                tertiary: nil,
                updatedAt: now,
                identity: nil)
        }
        return CodexConsumerProjection.make(
            surface: .liveCard,
            context: CodexConsumerProjection.Context(
                snapshot: snapshot,
                rawUsageError: nil,
                liveCredits: nil,
                rawCreditsError: nil,
                liveDashboard: nil,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false,
                now: now))
    }

    @Test
    func `session proximity shows remaining percent left`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let projection = self.makeProjection(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            now: now)
        #expect(projection.limitProximityDetail(for: .session, showUsed: false) == "80% left")
    }

    @Test
    func `weekly proximity shows used percent when showUsed`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let projection = self.makeProjection(
            primary: RateWindow(
                usedPercent: 2,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 4,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(86400),
                resetDescription: nil),
            now: now)
        #expect(projection.limitProximityDetail(for: .weekly, showUsed: true) == "4% used")
        #expect(projection.limitProximityDetail(for: .weekly, showUsed: false) == "96% left")
    }

    @Test
    func `proximity is nil when lane has no window`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let projection = self.makeProjection(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            now: now)
        #expect(projection.limitProximityDetail(for: .weekly, showUsed: false) == nil)
    }

    @Test
    func `proximity clamps exhausted window to zero left`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let projection = self.makeProjection(
            primary: RateWindow(
                usedPercent: 120,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            now: now)
        #expect(projection.limitProximityDetail(for: .session, showUsed: false) == "0% left")
    }

    @Test
    func `menu card codex lanes carry proximity detail text`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(4 * 60 * 60),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 4,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(6 * 24 * 60 * 60),
                resetDescription: nil),
            tertiary: nil,
            updatedAt: now,
            identity: nil)
        let projection = CodexConsumerProjection.make(
            surface: .liveCard,
            context: CodexConsumerProjection.Context(
                snapshot: snapshot,
                rawUsageError: nil,
                liveCredits: nil,
                rawCreditsError: nil,
                liveDashboard: nil,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false,
                now: now))
        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            codexProjection: projection,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "user@example.com", plan: "Pro"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))
        let session = try #require(model.metrics.first { $0.id == "primary" })
        #expect(session.detailText == "80% left")
        let weekly = try #require(model.metrics.first { $0.id == "secondary" })
        #expect(weekly.detailText == "96% left")
    }

    @Test
    func `menu card codex proximity follows showUsed toggle`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(4 * 60 * 60),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: nil)
        let projection = CodexConsumerProjection.make(
            surface: .liveCard,
            context: CodexConsumerProjection.Context(
                snapshot: snapshot,
                rawUsageError: nil,
                liveCredits: nil,
                rawCreditsError: nil,
                liveDashboard: nil,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false,
                now: now))
        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            codexProjection: projection,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "user@example.com", plan: "Pro"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))
        let session = try #require(model.metrics.first { $0.id == "primary" })
        #expect(session.detailText == "20% used")
    }
}
