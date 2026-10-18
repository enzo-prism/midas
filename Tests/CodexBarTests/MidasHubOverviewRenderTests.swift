import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

struct MidasHubOverviewRenderTests {
    @Test @MainActor func renderRecordedThirtyDayTotalsWithUnpricedLocalTokens() throws {
        guard let destination = ProcessInfo.processInfo.environment["MIDAS_HUB_RENDER_OUTPUT"] else { return }
        let now = Date()
        let day = MidasUsageSyncPublication.day(now)
        let snapshots: [UsageProvider: CostUsageTokenSnapshot] = [
            .codex: self.snapshot(tokens: 400_000, cost: 12.50, day: day, now: now),
            .claude: self.snapshot(tokens: 200_000, cost: 8.75, day: day, now: now),
            .localInference: self.snapshot(tokens: 50000, cost: nil, day: day, now: now),
        ]
        let providers: [UsageProvider] = [.codex, .claude, .localInference]
        let presentations = providers.map {
            MidasProviderPresentation.make(
                provider: $0,
                card: nil,
                snapshot: nil,
                tokenSnapshot: snapshots[$0],
                isRefreshing: false,
                isStale: false)
        }
        let total = MidasRecordedTokenTotal(
            providers: providers,
            snapshots: snapshots,
            period: .rolling30Days,
            reportingTimeZones: Dictionary(uniqueKeysWithValues: providers.map { ($0, MidasSpendPeriod.utc) }),
            now: now)
        #expect(total.tokens == 650_000)
        #expect(MidasTotalSpend(presentations: presentations).totals.first?.amount == 21.25)
        for scheme in [ColorScheme.light, .dark] {
            let view = VStack(alignment: .leading, spacing: 24) {
                Text("Midas · Preview with sample data").font(.headline)
                Label("Combined usage · 3 devices", systemImage: "network")
                    .foregroundStyle(MidasTheme.secondaryText)
                MidasTotalSpendView(presentations: presentations, tokenTotal: total, periodLabel: "Last 30 days")
                Divider()
                Text("Mac mini · MacBook Pro · DGX Spark").font(.callout)
                Text("Local inference contributes measured tokens. Its dollar value remains unavailable.")
                    .font(.footnote).foregroundStyle(MidasTheme.secondaryText)
            }
            .padding(24).frame(width: 430)
            .background(MidasTheme.background).foregroundStyle(MidasTheme.text)
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let url = URL(fileURLWithPath: destination)
                .appendingPathComponent("midas-tailscale-overview-\(scheme == .dark ? "dark" : "light").png")
            try png.write(to: url, options: .withoutOverwriting)
        }
    }

    private func snapshot(tokens: Int, cost: Double?, day: String, now: Date) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: tokens,
            last30DaysCostUSD: cost,
            costProvenance: cost == nil ? .unknown : .listPriceEstimate,
            daily: [.init(
                date: day,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: tokens,
                costUSD: cost,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: now)
    }
}
