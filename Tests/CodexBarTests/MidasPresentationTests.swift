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
        let snapshot = UsageSnapshot(
            primary: self.window(10, minutes: 300),
            secondary: nil,
            updatedAt: Date())
        #expect(self.present(snapshot).hero == nil)
        #expect(self.present(snapshot).summary == "Weekly usage unavailable")
    }

    @Test func weeklyInPrimarySlotUsesWeeklySemantics() {
        let reset = Date().addingTimeInterval(3600)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 40, windowMinutes: 10080, resetsAt: reset, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        #expect(self.present(snapshot).hero?.remainingPercent == 60)
        #expect(self.present(snapshot).hero?.resetsAt == reset)
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

    @Test @MainActor func completeSurfaceFixturesKeepProviderLimitsAndSpendDistinct() throws {
        let providers: [UsageProvider] = [.codex, .claude, .cursor]
        let models = try providers.map { try self.previewPresentation($0, state: .healthy) }
        let claude = try #require(models.first { $0.provider == .claude })
        #expect(MidasAccountQuotaLayout.overviewMetrics(claude).map(\.id) == ["primary", "secondary"])
        let cursor = try #require(models.first { $0.provider == .cursor })
        #expect(MidasAccountQuotaLayout.overviewMetrics(cursor).map(\.id) == [
            MidasCursorLimits.cursorModelsID, MidasCursorLimits.otherModelsID, MidasCursorLimits.grokBotID,
        ])
        let accounts = try self.previewAccounts(state: .healthy)
        #expect(accounts.map { $0.presentation.hero?.remainingPercent } == [72, 46])
        #expect(accounts.allSatisfy { $0.presentation.spend == nil })
        let total = try #require(MidasTotalSpend(presentations: models).totals.first)
        #expect(abs(total.amount - 189.94) < 0.001)
    }

    @Test @MainActor func completeSurfaceFixturesDistinguishUnavailableFromExhausted() throws {
        let unavailable = try self.previewPresentation(.codex, state: .unavailable)
        let exhausted = try self.previewPresentation(.codex, state: .staleExhausted)
        #expect(unavailable.hero == nil)
        #expect(unavailable.spend == nil)
        #expect(exhausted.hero?.remainingPercent == 0)
        #expect(exhausted.isStale)
        #expect(exhausted.spend?.isDisplayable == true)
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
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let suite = "MidasSurfacePreview-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings._test_managedCodexAccountStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        settings._test_liveSystemCodexAccount = nil
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = false
        settings.midasSpendPeriodSelection = "rolling30Days"
        let providers: [UsageProvider] = [.codex, .claude, .cursor]
        settings.mergedOverviewSelectedProviders = providers
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            planUtilizationHistoryStore: testPlanUtilizationHistoryStore(suiteName: suite),
            startupBehavior: .testing,
            environmentBase: [:])
        store._test_widgetSnapshotSaveOverride = { _ in }
        for state in PreviewState.allCases {
            self.configurePreviewProviders(state == .empty ? [] : providers, settings: settings)
            let models = try Dictionary(uniqueKeysWithValues: providers.map { provider in
                try (provider, self.previewPresentation(provider, state: state))
            })
            let accounts = try self.previewAccounts(state: state)
            let actions = MidasActions(
                refresh: {},
                settings: {},
                accounts: { _ in },
                openUsage: { _ in },
                legacyMenu: {},
                quit: {},
                accountPresentations: { $0 == .codex ? accounts : [] })
            for appearance in PreviewAppearance.all {
                let navigation = MidasNavigationState()
                let panel = MidasPanelView(
                    store: store,
                    settings: settings,
                    navigation: navigation,
                    presentation: { models[$0]! },
                    actions: actions,
                    opaqueNavigation: appearance.accessible)
                let name = state == .healthy ? "overview" : "overview-\(state.rawValue)"
                let overviewHeight = MidasPanelLayout.height(
                    providerCount: state == .empty ? 0 : providers.count, availableHeight: 900)
                try self.export(
                    panel,
                    name: name,
                    appearance: appearance,
                    output: output,
                    size: NSSize(width: MidasPanelLayout.width, height: overviewHeight))
                guard state == .healthy else { continue }
                try self.export(
                    panel,
                    name: "overview-short-screen",
                    appearance: appearance,
                    output: output,
                    size: NSSize(width: MidasPanelLayout.width, height: MidasPanelLayout.height(
                        providerCount: providers.count, availableHeight: 400)))
                for provider in providers {
                    navigation.provider = provider
                    try self.export(
                        panel,
                        name: "detail-\(provider.rawValue)",
                        appearance: appearance,
                        output: output,
                        size: NSSize(width: MidasPanelLayout.width, height: MidasPanelLayout.maximumHeight))
                }
                navigation.provider = nil
                let usage = MidasUsageWindowView(
                    store: store,
                    settings: settings,
                    navigation: navigation,
                    presentation: { models[$0]! },
                    actions: actions).frame(width: 900, height: 640)
                try self.export(
                    usage,
                    name: "usage-overview",
                    appearance: appearance,
                    output: output,
                    size: NSSize(width: 900, height: 640))
                navigation.provider = .codex
                try self.export(
                    usage,
                    name: "usage-codex",
                    appearance: appearance,
                    output: output,
                    size: NSSize(width: 900, height: 640))
            }
        }
    }

    /// Opt-in native interaction host: all controls use isolated settings and synthetic provider data.
    @Test @MainActor func interactiveDesignPreviewWhenRequested() throws {
        guard let requested = ProcessInfo.processInfo.environment["MIDAS_INTERACTIVE_PREVIEW_SECONDS"],
              let seconds = Double(requested), seconds.isFinite, seconds > 0
        else { return }
        let suite = "MidasInteractivePreview-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings._test_managedCodexAccountStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        settings._test_liveSystemCodexAccount = nil
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = false
        settings.midasSpendPeriodSelection = "rolling30Days"
        let providers: [UsageProvider] = [.codex, .claude, .cursor]
        settings.mergedOverviewSelectedProviders = providers
        self.configurePreviewProviders(providers, settings: settings)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            planUtilizationHistoryStore: testPlanUtilizationHistoryStore(suiteName: suite),
            startupBehavior: .testing,
            environmentBase: [:])
        store._test_widgetSnapshotSaveOverride = { _ in }
        let models = try Dictionary(uniqueKeysWithValues: providers.map { provider in
            try (provider, self.previewPresentation(provider, state: .healthy))
        })
        let accounts = try self.previewAccounts(state: .healthy)
        let usageNavigation = MidasNavigationState()
        let usageActions = MidasActions(
            refresh: {},
            settings: {},
            accounts: { _ in },
            openUsage: { _ in },
            legacyMenu: {},
            quit: {},
            accountPresentations: { $0 == .codex ? accounts : [] })
        var usageWindow: NSWindow?
        let actions = MidasActions(
            refresh: {},
            settings: {},
            accounts: { _ in },
            openUsage: { provider in
                usageNavigation.provider = provider
                if let usageWindow {
                    usageWindow.makeKeyAndOrderFront(nil)
                    return
                }
                let usage = MidasUsageWindowView(
                    store: store,
                    settings: settings,
                    navigation: usageNavigation,
                    presentation: { models[$0]! },
                    actions: usageActions)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false)
                window.title = "Midas Usage Design Preview"
                window.identifier = NSUserInterfaceItemIdentifier("midas-usage-design-preview")
                window.isReleasedWhenClosed = false
                window.contentViewController = NSHostingController(rootView: usage)
                window.contentMinSize = NSSize(width: 760, height: 520)
                window.center()
                usageWindow = window
                window.makeKeyAndOrderFront(nil)
            },
            legacyMenu: {},
            quit: {},
            accountPresentations: { $0 == .codex ? accounts : [] })
        let navigation = MidasNavigationState()
        let height = MidasPanelLayout.height(providerCount: providers.count, availableHeight: 900)
        let panel = MidasPanelView(
            store: store,
            settings: settings,
            navigation: navigation,
            presentation: { models[$0]! },
            actions: actions)
            .frame(width: MidasPanelLayout.width, height: height)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: MidasPanelLayout.width, height: height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Midas Design Preview"
        window.identifier = NSUserInterfaceItemIdentifier("midas-design-preview")
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: panel)
        window.center()
        let application = NSApplication.shared
        let originalActivationPolicy = application.activationPolicy()
        application.setActivationPolicy(.regular)
        defer {
            usageWindow?.close()
            usageWindow?.contentViewController = nil
            window.close()
            window.contentViewController = nil
            application.setActivationPolicy(originalActivationPolicy)
        }
        window.makeKeyAndOrderFront(nil)
        application.finishLaunching()
        application.activate(ignoringOtherApps: true)
        print("MIDAS_INTERACTIVE_PREVIEW_READY: Midas Design Preview")
        let deadline = Date().addingTimeInterval(min(seconds, 300))
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                if !window.isVisible || Date() >= deadline {
                    application.stop(nil)
                    // Wake nextEvent so a quiet preview also returns from NSApplication.run().
                    if let event = NSEvent.otherEvent(
                        with: .applicationDefined,
                        location: .zero,
                        modifierFlags: [],
                        timestamp: 0,
                        windowNumber: 0,
                        context: nil,
                        subtype: 0,
                        data1: 0,
                        data2: 0)
                    {
                        application.postEvent(event, atStart: true)
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        application.run()
    }

    private enum PreviewState: String, CaseIterable {
        case healthy, unavailable, staleExhausted = "stale-exhausted", empty
    }

    private struct PreviewAppearance {
        let scheme: ColorScheme
        let accessible: Bool

        static var all: [Self] {
            [
                .init(scheme: .light, accessible: false),
                .init(scheme: .dark, accessible: false),
                .init(scheme: .light, accessible: true),
                .init(scheme: .dark, accessible: true),
            ]
        }

        var name: String {
            (self.scheme == .dark ? "dark" : "light") + (self.accessible ? "-accessible" : "")
        }

        var nativeAppearance: NSAppearance.Name {
            if self.accessible {
                return self.scheme == .dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua
            }
            return self.scheme == .dark ? .darkAqua : .aqua
        }
    }

    @MainActor private func configurePreviewProviders(_ providers: [UsageProvider], settings: SettingsStore) {
        for provider in UsageProvider.allCases {
            if let metadata = ProviderRegistry.shared.metadata[provider] {
                settings.setProviderEnabled(
                    provider: provider,
                    metadata: metadata,
                    enabled: providers.contains(provider))
            }
        }
    }

    private func previewSnapshot(
        _ provider: UsageProvider,
        state: PreviewState,
        accountIndex: Int = 0) -> UsageSnapshot?
    {
        guard state != .unavailable else { return nil }
        let exhausted = state == .staleExhausted
        func metric(_ used: Double, _ minutes: Int, _ reset: String) -> RateWindow {
            RateWindow(usedPercent: used, windowMinutes: minutes, resetsAt: nil, resetDescription: reset)
        }
        let primary = metric(exhausted ? 100 : 15, 300, "Resets in 2h 10m")
        let weekly = metric(exhausted ? 100 : (accountIndex == 0 ? 28 : 54), 10080, "Resets in 2d 4h")
        let extras: [NamedRateWindow]? = provider == .cursor ? [
            .init(
                id: MidasCursorLimits.cursorModelsID,
                title: "Cursor Models",
                window: metric(exhausted ? 100 : 20, 43200, "Resets in 12d")),
            .init(
                id: MidasCursorLimits.otherModelsID,
                title: "Other Models",
                window: metric(exhausted ? 96 : 45, 43200, "Resets in 12d")),
            .init(
                id: MidasCursorLimits.grokBotID,
                title: "Grok Bot",
                window: metric(exhausted ? 100 : 80, 10080, "Resets in 3d")),
        ] : nil
        return UsageSnapshot(
            primary: provider == .cursor ? metric(exhausted ? 98 : 30, 43200, "Resets in 12d") : primary,
            secondary: provider == .cursor ? nil : weekly,
            extraRateWindows: extras,
            updatedAt: Date(timeIntervalSince1970: 1_792_238_400),
            identity: ProviderIdentitySnapshot(
                providerID: provider,
                accountEmail: "fixture-\(accountIndex)@example.com",
                accountOrganization: nil,
                loginMethod: "Pro"))
    }

    @MainActor private func previewPresentation(
        _ provider: UsageProvider, state: PreviewState, accountIndex: Int = 0, includesSpend: Bool = true) throws
        -> MidasProviderPresentation
    {
        let now = Date(timeIntervalSince1970: 1_792_238_400)
        let snapshot = self.previewSnapshot(provider, state: state, accountIndex: accountIndex)
        let cost: CostUsageTokenSnapshot? = state == .unavailable || !includesSpend ? nil : .init(
            sessionTokens: 12000,
            sessionCostUSD: 1.25,
            last30DaysTokens: 820_000,
            last30DaysCostUSD: provider == .codex ? 128.42 : provider == .claude ? 42.80 : 18.72,
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
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            now: now))
        return .make(
            provider: provider,
            card: card,
            snapshot: snapshot,
            tokenSnapshot: cost,
            isRefreshing: false,
            isStale: state == .staleExhausted)
    }

    @MainActor private func previewAccounts(state: PreviewState) throws -> [MidasAccountPresentation] {
        try [0, 1].map { index in
            try MidasAccountPresentation(
                id: "synthetic-\(index)",
                isPrimary: index == 0,
                presentation: self.previewPresentation(
                    .codex,
                    state: state,
                    accountIndex: index,
                    includesSpend: false),
                displayName: index == 0 ? "Personal" : "Work")
        }
    }

    @MainActor private func export(
        _ view: some View, name: String, appearance: PreviewAppearance, output: String, size: NSSize) throws
    {
        let content = view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, appearance.scheme)
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        window.appearance = NSAppearance(named: appearance.nativeAppearance)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(bitmap.pixelsWide >= Int(size.width))
        #expect(bitmap.pixelsHigh >= Int(size.height))
        let filename = "midas-\(name)-\(appearance.name).png"
        try png.write(to: URL(fileURLWithPath: output).appendingPathComponent(filename), options: .withoutOverwriting)
        window.contentView = nil
    }
}
