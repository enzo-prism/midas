import AppKit
import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct MidasProviderAuditRenderTests {
    /// Opt-in previews use real presentation adapters with synthetic snapshots and no stores or provider probes.
    @Test @MainActor func exportProviderAuditFixturesWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["MIDAS_AUDIT_PREVIEW_OUTPUT"] else { return }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let now = Date()
        let fixtures: [(String, UsageProvider, UsageSnapshot)] = [
            ("codex-spend-and-weekly", .codex, UsageSnapshot(
                primary: self.window(15, minutes: 300),
                secondary: self.window(28, minutes: 10080),
                updatedAt: now)),
            ("meta-local-activity", .meta, self.metaSnapshot(now: now)),
            ("cursor-pools-and-mix", .cursor, self.cursorPools(now: now)),
            ("cursor-request-count", .cursor, self.cursorRequests(now: now)),
        ]
        let actions = MidasActions(
            refresh: {},
            settings: {},
            accounts: { _ in },
            openUsage: { _ in },
            legacyMenu: {},
            quit: {})
        for (name, provider, snapshot) in fixtures {
            let presentation = try self.presentation(provider: provider, snapshot: snapshot, now: now)
            for scheme in [ColorScheme.light, .dark] {
                let view = MidasProviderDetailView(presentation: presentation, actions: actions)
                    .padding(24)
                    .frame(width: 400, alignment: .topLeading)
                    .background(MidasTheme.background)
                    .environment(\.colorScheme, scheme)
                try self.export(view, name: name, scheme: scheme, output: output)
            }
        }
    }

    private func metaSnapshot(now: Date) -> UsageSnapshot {
        UsageSnapshot(
            primary: self.window(0, minutes: 1440, description: "2.4K today"),
            secondary: self.window(0, minutes: 10080, description: "12K last 7d"),
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .meta,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "local"))
    }

    private func cursorPools(now: Date) -> UsageSnapshot {
        UsageSnapshot(
            primary: self.window(30, minutes: 43200),
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(id: "cursor-models", title: "Models", window: self.window(68)),
                NamedRateWindow(
                    id: "cursor-pool-models",
                    title: "Cursor Models",
                    window: self.window(20, minutes: 43200)),
                NamedRateWindow(
                    id: "cursor-pool-other",
                    title: "Other Models",
                    window: self.window(45, minutes: 43200)),
                NamedRateWindow(
                    id: "cursor-grok-bot",
                    title: "Grok Bot",
                    window: self.window(80, minutes: 10080)),
            ],
            updatedAt: now)
    }

    private func cursorRequests(now: Date) -> UsageSnapshot {
        UsageSnapshot(
            primary: self.window(69.4, minutes: 43200),
            secondary: nil,
            cursorRequests: CursorRequestUsage(used: 347, limit: 500),
            updatedAt: now)
    }

    private func window(_ used: Double, minutes: Int? = nil, description: String? = nil) -> RateWindow {
        RateWindow(usedPercent: used, windowMinutes: minutes, resetsAt: nil, resetDescription: description)
    }

    private func presentation(provider: UsageProvider, snapshot: UsageSnapshot, now: Date) throws
        -> MidasProviderPresentation
    {
        let cost = CostUsageTokenSnapshot(
            sessionTokens: 12000,
            sessionCostUSD: 1.25,
            last30DaysTokens: 2_400_000,
            last30DaysCostUSD: provider == .meta ? 0 : (provider == .codex ? 128.42 : 38.40),
            last30DaysAPIEquivalentCostUSD: provider == .meta ? 24.80 : nil,
            historyDays: 30,
            historyLabel: "Last 30 days",
            costProvenance: .listPriceEstimate,
            daily: [],
            updatedAt: now)
        let card = try UsageMenuCardView.Model.make(.init(
            provider: provider,
            metadata: #require(ProviderDefaults.metadata[provider]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: cost,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            now: now))
        return .make(
            provider: provider,
            card: card,
            snapshot: snapshot,
            tokenSnapshot: cost,
            isRefreshing: false,
            isStale: false)
    }

    @MainActor private func export(_ view: some View, name: String, scheme: ColorScheme, output: String) throws {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        #expect(size.width == 400)
        #expect(size.height > 100)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let filename = "midas-\(name)-\(scheme == .dark ? "dark" : "light").png"
        try png.write(to: URL(fileURLWithPath: output).appendingPathComponent(filename))
    }
}
