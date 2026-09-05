import AppKit
import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct MidasPresentationTests {
    private func window(_ used: Double, minutes: Int) -> RateWindow {
        RateWindow(usedPercent: used, windowMinutes: minutes, resetsAt: nil, resetDescription: nil)
    }

    private func present(_ snapshot: UsageSnapshot?, refreshing: Bool = false, stale: Bool = false)
        -> MidasProviderPresentation
    {
        MidasProviderPresentation.make(
            provider: .codex,
            card: nil,
            snapshot: snapshot,
            tokenSnapshot: nil,
            isRefreshing: refreshing,
            isStale: stale)
    }

    @Test func weeklyHeroIgnoresSessionRemaining() {
        let snapshot = UsageSnapshot(
            primary: self.window(99, minutes: 300),
            secondary: self.window(28, minutes: 10080),
            updatedAt: Date())
        let result = self.present(snapshot)
        #expect(result.hero?.remainingPercent == 72)
        #expect(result.hero?.title == "This week")
        #expect(result.metrics.first(where: { $0.id == "primary" })?.remainingPercent == 1)
    }

    @Test func missingWeeklyNeverFallsBackToSession() {
        let snapshot = UsageSnapshot(primary: self.window(10, minutes: 300), secondary: nil, updatedAt: Date())
        #expect(self.present(snapshot).hero == nil)
        #expect(self.present(snapshot).summary == "Weekly usage unavailable")
    }

    @Test func weeklyInPrimarySlotUsesWeeklySemantics() {
        let snapshot = UsageSnapshot(primary: self.window(40, minutes: 10080), secondary: nil, updatedAt: Date())
        #expect(self.present(snapshot).hero?.remainingPercent == 60)
    }

    @Test func exhaustedIsDifferentFromUnknown() {
        let snapshot = UsageSnapshot(primary: nil, secondary: self.window(100, minutes: 10080), updatedAt: Date())
        #expect(self.present(snapshot).hero?.remainingPercent == 0)
        #expect(self.present(snapshot).hero?.isExhausted == true)
        #expect(self.present(nil).hero == nil)
    }

    @Test func cachedWeeklyRemainsVisibleDuringRefresh() {
        let snapshot = UsageSnapshot(primary: nil, secondary: self.window(28, minutes: 10080), updatedAt: Date())
        let result = self.present(snapshot, refreshing: true, stale: true)
        #expect(result.hero?.remainingPercent == 72)
        #expect(result.isStale)
        #expect(result.freshness.contains("last update"))
    }

    @Test func percentDirectionAndInvalidNumbers() {
        func metric(_ value: Double, style: UsageMenuCardView.Model.PercentStyle) -> UsageMenuCardView.Model.Metric {
            .init(
                id: "primary",
                title: "Session",
                percent: value,
                percentStyle: style,
                resetText: nil,
                detailText: nil,
                detailLeftText: nil,
                detailRightText: nil,
                pacePercent: nil,
                paceOnTop: true)
        }
        #expect(MidasQuotaMetric.make(metric(28, style: .used))?.remainingPercent == 72)
        #expect(MidasQuotaMetric.make(metric(28, style: .left))?.remainingPercent == 28)
        #expect(MidasQuotaMetric.make(metric(.nan, style: .used)) == nil)
    }

    /// Opt-in export uses synthetic data only; it never initializes stores or probes credentials.
    @Test @MainActor func exportDesignFixturesWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["MIDAS_PREVIEW_OUTPUT"] else { return }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let actions = MidasActions(
            refresh: {},
            settings: {},
            accounts: { _ in },
            openUsage: { _ in },
            legacyMenu: {},
            quit: {})
        for (label, used, stale) in [
            ("healthy", 28.0, false),
            ("exhausted", 100.0, false),
            ("stale", 64.0, true),
            ("missing", -1.0, false),
        ] {
            let snapshot = UsageSnapshot(
                primary: self.window(label == "exhausted" ? 100 : 15, minutes: 300),
                secondary: used < 0 ? nil : self.window(used, minutes: 10080),
                updatedAt: Date())
            let model = self.present(snapshot, stale: stale)
            for scheme in [ColorScheme.light, .dark] {
                let view = MidasProviderDetailView(presentation: model, actions: actions)
                    .padding(24).frame(width: 400, alignment: .topLeading)
                    .background(MidasTheme.background).environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try #require(renderer.nsImage)
                let data = try #require(image.tiffRepresentation)
                let bitmap = try #require(NSBitmapImageRep(data: data))
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                let name = "midas-\(label)-\(scheme == .dark ? "dark" : "light").png"
                try png.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
            }
        }
    }

    /// Complete surfaces use isolated settings and a store whose background work is explicitly disabled.
    @Test @MainActor func exportCompleteSurfacesWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["MIDAS_PREVIEW_OUTPUT"] else { return }
        let suite = "MidasSurfacePreview-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = false
        let providers: [UsageProvider] = [.codex, .claude, .cursor]
        for provider in UsageProvider.allCases {
            if let metadata = ProviderRegistry.shared.metadata[provider] {
                settings.setProviderEnabled(
                    provider: provider,
                    metadata: metadata,
                    enabled: providers.contains(provider))
            }
        }
        settings.mergedOverviewSelectedProviders = providers
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            planUtilizationHistoryStore: testPlanUtilizationHistoryStore(suiteName: suite),
            startupBehavior: .testing,
            environmentBase: [:])
        let actions = MidasActions(
            refresh: {}, settings: {}, accounts: { _ in }, openUsage: { _ in }, legacyMenu: {}, quit: {})
        let models: [UsageProvider: MidasProviderPresentation] = Dictionary(uniqueKeysWithValues:
            zip(providers, [72.0, 86.0, 54.0]).map { provider, remaining in
                let metric = MidasQuotaMetric(
                    id: "weekly",
                    title: "This week",
                    remainingPercent: remaining,
                    resetText: "Resets in 2d 4h",
                    helpText: "Synthetic design fixture")
                return (provider, MidasProviderPresentation(
                    provider: provider,
                    name: ProviderRegistry.shared.metadata[provider]?.displayName ?? provider.rawValue,
                    account: "Personal workspace",
                    plan: "Connected",
                    hero: metric,
                    metrics: [],
                    resetCreditsText: provider == .codex ? "2 resets available" : nil,
                    resetCreditsHelp: nil,
                    freshness: "Updated just now",
                    error: nil,
                    placeholder: nil,
                    notes: [],
                    financialSummary: nil,
                    financialLabel: nil,
                    spend: MidasSpendPresentation.make(
                        provider: provider,
                        snapshot: CostUsageTokenSnapshot(
                            sessionTokens: nil,
                            sessionCostUSD: nil,
                            last30DaysTokens: 820_000,
                            last30DaysCostUSD: provider == .codex ? 12345.67 : provider == .claude ? 42.80 : 18.72,
                            costProvenance: .listPriceEstimate,
                            daily: [],
                            updatedAt: Date())),
                    isRefreshing: false,
                    isStale: false,
                    updatedAt: Date()))
            })
        let presentation: (UsageProvider) -> MidasProviderPresentation = { models[$0]! }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            let navigation = MidasNavigationState()
            let overview = MidasPanelView(
                store: store,
                settings: settings,
                navigation: navigation,
                presentation: presentation,
                actions: actions)
                .frame(width: 400, height: 660)
                .environment(\.colorScheme, scheme)
            try self.export(overview, name: "overview", scheme: scheme, output: output)
            let usage = MidasUsageWindowView(
                store: store,
                settings: settings,
                navigation: navigation,
                presentation: presentation,
                actions: actions)
                .frame(width: 900, height: 640)
                .environment(\.colorScheme, scheme)
            try self.export(usage, name: "usage-overview", scheme: scheme, output: output)
            navigation.provider = .codex
            try self.export(usage, name: "usage-codex", scheme: scheme, output: output)
        }
    }

    @MainActor private func export(_ view: some View, name: String, scheme: ColorScheme, output: String) throws {
        let hosting = NSHostingView(rootView: view)
        let size = name == "overview" ? NSSize(width: 400, height: 660) : NSSize(width: 900, height: 640)
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
