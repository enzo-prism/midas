import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct MenuCardProviderRegressionTests {
    @Test
    func `elevenlabs progress color stays visible in light menus`() {
        #expect(UsageMenuCardView.Model.progressColor(for: .elevenlabs) == Color(nsColor: .labelColor))
    }

    @Test
    func `open router model shows daily and weekly key spend`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.openrouter])
        let snapshot = OpenRouterUsageSnapshot(
            totalCredits: 50,
            totalUsage: 45.3895596325,
            balance: 4.6104403675,
            usedPercent: 90.779119265,
            keyLimit: 20,
            keyUsage: 0.5,
            keyUsageDaily: 0.12,
            keyUsageWeekly: 0.74,
            rateLimit: nil,
            updatedAt: now).toUsageSnapshot()

        let model = UsageMenuCardView.Model.make(.init(
            provider: .openrouter,
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
            now: now))

        #expect(model.usageNotes == ["Today: $0.12 · This week: $0.74"])
    }

    @Test
    func `copilot over quota usage keeps used percentage detail`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.copilot])
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 115, windowMinutes: nil, resetsAt: nil, resetDescription: "115% used"),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: nil)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .copilot,
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
            now: now))

        let metric = try #require(model.metrics.first)
        #expect(metric.percent == 0)
        #expect(metric.percentLabel == "0% left")
        #expect(metric.detailLeftText == "115% used")
    }
}

struct CreditCountMenuCardTests {
    @Test
    func `suno progress color stays visible in light menus`() {
        #expect(UsageMenuCardView.Model.progressColor(for: .suno) == Color(nsColor: .labelColor))
    }

    @Test
    func `suno shows credit and download counts as details, not reset text`() throws {
        let now = Date()
        let renewsAt = now.addingTimeInterval(15 * 24 * 3600)
        let snapshot = SunoUsageSnapshot(
            planName: "Pro Plan",
            isActive: true,
            period: "month",
            creditsUsed: 470,
            creditLimit: 2500,
            totalCreditsLeft: 2030,
            topUpCredits: 0,
            downloadsUsed: 20,
            downloadLimit: 20,
            additionalDownloadsRemaining: 0,
            renewsAt: renewsAt,
            updatedAt: now).toUsageSnapshot()

        let model = try Self.model(provider: .suno, snapshot: snapshot, now: now)
        let credits = try #require(model.metrics.first { $0.id == "primary" })
        let downloads = try #require(model.metrics.first { $0.id == "secondary" })

        #expect(credits.detailText == "470 / 2,500 credits")
        #expect(downloads.detailText == "20 / 20 downloads")
        #expect(credits.resetText?.contains("credits") != true)
        #expect(downloads.resetText?.contains("downloads") != true)

        let midas = MidasCreditCounts.annotate(
            [MidasQuotaMetric(
                id: "primary",
                title: "Credits",
                remainingPercent: 81.2,
                resetText: "Resets in 15d",
                helpText: nil)],
            card: model)
        #expect(midas.first?.resetText == "Resets in 15d · 470 / 2,500 credits")
    }

    @Test
    func `elevenlabs count without a reset date never reads as a reset`() throws {
        let now = Date()
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "25,000 / 100,000 credits"),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: nil)

        let model = try Self.model(provider: .elevenlabs, snapshot: snapshot, now: now)
        let credits = try #require(model.metrics.first { $0.id == "primary" })
        #expect(credits.detailText == "25,000 / 100,000 credits")
        #expect(credits.resetText == nil)
    }

    private static func model(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        now: Date) throws -> UsageMenuCardView.Model
    {
        let metadata = try #require(ProviderDefaults.metadata[provider])
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
            now: now))
    }
}
