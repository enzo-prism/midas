import AppKit
import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct MidasOnboardingRenderTests {
    /// Opt-in snapshots only: synthetic settings, no account discovery, provider probes, or login actions.
    @Test @MainActor func exportOnboardingFixturesWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["MIDAS_ONBOARDING_PREVIEW_OUTPUT"] else { return }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let suite = "MidasOnboardingRender-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite, reset: false),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings._test_managedCodexAccountStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        // The non-nil store override enables the test observer. A nil account without an injected
        // reconciliation environment returns nil directly instead of consulting ambient auth.
        settings._test_liveSystemCodexAccount = nil
        settings.statusChecksEnabled = false
        settings.midasCodexEstimateMode = .automatic
        for provider in UsageProvider.allCases {
            if let metadata = ProviderRegistry.shared.metadata[provider] {
                settings.setProviderEnabled(
                    provider: provider, metadata: metadata, enabled: MidasOnboarding.providers.contains(provider))
            }
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._test_widgetSnapshotSaveOverride = { _ in }
        #expect(settings.codexVisibleAccountProjection.visibleAccounts.isEmpty)
        let coordinator = ManagedCodexAccountCoordinator()
        for step in MidasOnboardingStep.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let view = MidasSpendSetupView(
                    settings: settings,
                    store: store,
                    coordinator: coordinator,
                    openProvider: { _ in },
                    initialStep: step)
                    .environment(\.colorScheme, scheme)
                    .background(scheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color.white)
                try self.export(view, step: step, scheme: scheme, output: output)
            }
        }
    }

    @MainActor private func export(
        _ view: some View, step: MidasOnboardingStep, scheme: ColorScheme, output: String) throws
    {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        #expect(size.width == 600)
        #expect(size.height >= 430 && size.height <= 650)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let filename = "midas-onboarding-\(step.rawValue)-\(scheme == .dark ? "dark" : "light").png"
        try png.write(to: URL(fileURLWithPath: output).appendingPathComponent(filename))
    }
}
