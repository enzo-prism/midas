import AppKit
import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct MidasCursorOverviewRenderTests {
    /// Opt-in export uses synthetic data only; it never initializes stores or probes credentials.
    @Test @MainActor
    func `export cursor overview when requested`() throws {
        guard let output = ProcessInfo.processInfo.environment["MIDAS_PREVIEW_OUTPUT"] else { return }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let now = Date()
        for (label, trial) in [("cursor-trio", false), ("cursor-grok-trial", true)] {
            let status = CursorStatusSnapshot(
                planPercentUsed: 28,
                planUsedUSD: 5.6,
                planLimitUSD: 20,
                onDemandUsedUSD: 0,
                onDemandLimitUSD: nil,
                teamOnDemandUsedUSD: nil,
                teamOnDemandLimitUSD: nil,
                billingCycleStart: now.addingTimeInterval(-18 * 86400),
                billingCycleEnd: now.addingTimeInterval(12 * 86400),
                membershipType: "pro",
                accountEmail: nil,
                accountName: nil,
                rawJSON: nil,
                cursorModelsUsedPercent: 15,
                otherModelsUsedPercent: 62,
                grokBotWeeklyUsedPercent: 91,
                grokBotWeeklyReset: trial ? nil : now.addingTimeInterval(3 * 86400),
                grokBotTrialEndsAt: trial ? now.addingTimeInterval(5 * 86400) : nil)
            let snapshot = status.toUsageSnapshot()
            let card = try UsageMenuCardView.Model.make(.init(
                provider: .cursor,
                metadata: #require(ProviderDefaults.metadata[.cursor]),
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
            let presentation = MidasProviderPresentation.make(
                provider: .cursor,
                card: card,
                snapshot: snapshot,
                tokenSnapshot: nil,
                isRefreshing: false,
                isStale: false)
            for scheme in [ColorScheme.light, .dark] {
                let view = MidasOverviewMetrics(item: presentation)
                    .padding(20).frame(width: 360, alignment: .topLeading)
                    .background(MidasTheme.background).environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try #require(renderer.nsImage)
                let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                let name = "midas-\(label)-\(scheme == .dark ? "dark" : "light").png"
                try png.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
            }
        }
    }
}
