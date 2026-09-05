import AppKit
import CodexBarCore
import SwiftUI

/// Native presentation lifetime, separate from provider fetching and legacy menu tracking.
@MainActor
final class MidasAirCoordinator: NSObject, NSPopoverDelegate, NSWindowDelegate {
    private weak var controller: StatusItemController?
    private let popover = NSPopover()
    private let navigation = MidasNavigationState()
    private let usageNavigation = MidasNavigationState()
    private var usageWindow: NSWindow?
    private var retryTask: Task<Void, Never>?
    private weak var anchor: NSStatusBarButton?

    init(controller: StatusItemController) {
        self.controller = controller
        super.init()
        self.popover.behavior = .transient
        self.popover.delegate = self
    }

    func toggle(from button: NSStatusBarButton, provider: UsageProvider?) {
        if self.popover.isShown, self.anchor === button {
            self.closePopover()
            return
        }
        self.closePopover()
        guard let controller = self.controller else { return }
        self.anchor = button
        if controller.usesMidasMenuBar { self.navigation.provider = provider }
        if let provider { self.navigation.provider = provider }
        if let selected = self.navigation.provider,
           !controller.store.enabledProvidersForDisplay().contains(selected)
        {
            self.navigation.provider = nil
        }
        controller.lastMenuProvider = self.navigation.provider ?? controller.lastMenuProvider
        let availableHeight = button.window?.screen?.visibleFrame.height ?? 800
        let height = min(660, max(280, availableHeight - 80))
        let view = MidasPanelView(
            store: controller.store,
            settings: controller.settings,
            navigation: self.navigation,
            presentation: self.presentation,
            actions: self.actions)
            .frame(width: 400, height: height)
            .tint(MidasTheme.accent)
            .onExitCommand { [weak self] in self?.closePopover() }
        self.popover.contentViewController = NSHostingController(rootView: view)
        self.popover.contentSize = NSSize(width: 400, height: height)
        self.popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSApp.activate(ignoringOtherApps: true)
        self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover.contentViewController?.view.window?.makeKey()
        controller.scheduleCodexAccountMenuProjectionRevalidationIfNeeded(
            for: controller.store.enabledProvidersForDisplay())
        self.scheduleVisibleRetry()
    }

    @discardableResult
    func closePopoverIfShown() -> Bool {
        guard self.popover.isShown else { return false }
        self.closePopover()
        return true
    }

    /// Avoid an animated dismissal racing replacement content when changing status items.
    private func closePopover() {
        self.retryTask?.cancel()
        self.retryTask = nil
        let wasAnimated = self.popover.animates
        self.popover.animates = false
        self.popover.close()
        self.popover.animates = wasAnimated
        self.popover.contentViewController = nil
    }

    func popoverDidClose(_ notification: Notification) {
        // A delayed notification for an old presentation must not clear a reopened panel.
        guard !self.popover.isShown else { return }
        self.retryTask?.cancel()
        self.retryTask = nil
        self.popover.contentViewController = nil
    }

    func showUsage(provider: UsageProvider?) {
        self.closePopoverIfShown()
        self.usageNavigation.provider = provider
        if let window = self.usageWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let controller = self.controller else { return }
        let view = MidasUsageWindowView(
            store: controller.store,
            settings: controller.settings,
            navigation: self.usageNavigation,
            presentation: self.presentation,
            actions: self.actions)
            .tint(MidasTheme.accent)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Midas — Usage"
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.contentViewController = NSHostingController(rootView: view)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("MidasUsageWindow")
        if !window.setFrameUsingName("MidasUsageWindow") { window.center() }
        self.usageWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === self.usageWindow else { return }
        window.contentViewController = nil
        self.usageWindow = nil
    }

    func shutdown() {
        self.retryTask?.cancel()
        self.retryTask = nil
        self.closePopover()
        self.popover.contentViewController = nil
        self.usageWindow?.close()
        self.usageWindow = nil
    }

    private func presentation(for provider: UsageProvider) -> MidasProviderPresentation {
        guard let controller = self.controller else {
            return .make(
                provider: provider,
                card: nil,
                snapshot: nil,
                tokenSnapshot: nil,
                isRefreshing: false,
                isStale: false)
        }
        let snapshot = controller.store.snapshot(for: provider)
        let projected = controller.store.tokenSnapshot(fromProviderSnapshot: snapshot, provider: provider)
        let token = projected ?? (UsageStore.tokenCostRequiresProviderSnapshot(provider)
            ? nil : controller.store.tokenSnapshot(for: provider))
        return .make(
            provider: provider,
            card: controller.menuCardModel(for: provider),
            snapshot: snapshot,
            tokenSnapshot: token,
            isRefreshing: controller.store.shouldShowRefreshingMenuCardIndicator(for: provider),
            isStale: controller.store.isStale(provider: provider))
    }

    private var actions: MidasActions {
        MidasActions(
            refresh: { [weak self] in self?.controller?.refreshNow() },
            settings: { [weak self] in
                self?.closePopoverIfShown()
                self?.controller?.showSettingsGeneral()
            },
            accounts: { [weak self] provider in
                self?.closePopoverIfShown()
                self?.controller?.showMidasAccountSettings(provider: provider)
            },
            openUsage: { [weak self] provider in self?.showUsage(provider: provider) },
            legacyMenu: { [weak self] in
                guard let self, let button = self.anchor else { return }
                self.closePopoverIfShown()
                self.controller?.showMidasAdvancedMenu(from: button, provider: self.navigation.provider)
            },
            quit: { [weak self] in
                self?.closePopoverIfShown()
                self?.controller?.quit()
            })
    }

    private func scheduleVisibleRetry() {
        self.retryTask?.cancel()
        self.retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, !Task.isCancelled, self.popover.isShown,
                  let controller = self.controller, !controller.hasPreparedForAppShutdown
            else { return }
            let providers = self.navigation.provider.map { [$0] }
                ?? controller.store.enabledProvidersForDisplay()
            let backgroundProviders = Set(controller.store.enabledProvidersForBackgroundWork())
            await ProviderInteractionContext.$current.withValue(.background) {
                for provider in providers where backgroundProviders.contains(provider) {
                    guard !Task.isCancelled else { return }
                    if controller.store.snapshot(for: provider) == nil || controller.store.isStale(provider: provider) {
                        await controller.store.refreshProvider(provider, coalesceIfRefreshing: true)
                    }
                }
            }
        }
    }
}

extension StatusItemController {
    var usesMidasAir: Bool {
        !SettingsStore.isRunningTests && Bundle.main.object(forInfoDictionaryKey: "MidasAirEnabled") as? Bool == true
    }

    func attachMidasAir(to item: NSStatusItem) {
        item.menu = nil
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(self.showMidasAir(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        if !self.usesMidasMenuBar { button.setAccessibilityLabel("Midas") }
    }

    @objc func showMidasAir(_ sender: NSStatusBarButton) {
        let focusEnabled = self.store.enabledProvidersForDisplay().contains(self.settings.midasMenuBarFocusProvider)
        let provider = self.usesMidasMenuBar
            ? (self.settings.midasMenuBarMode == .focus && focusEnabled ? self.settings.midasMenuBarFocusProvider : nil)
            : self.statusItems.first { $0.value.button === sender }?.key
        if NSApp.currentEvent?.type == .rightMouseUp {
            self.midasAirCoordinator?.closePopoverIfShown()
            self.showMidasAdvancedMenu(from: sender, provider: provider)
            return
        }
        if self.midasAirCoordinator == nil {
            self.midasAirCoordinator = MidasAirCoordinator(controller: self)
        }
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            self.midasAirCoordinator?.showUsage(provider: provider)
            return
        }
        self.midasAirCoordinator?.toggle(from: sender, provider: provider)
    }

    func showMidasAdvancedMenu(from button: NSStatusBarButton, provider: UsageProvider?) {
        let menu = self.makeMenu(for: provider)
        let point = Self.trailingAlignedMenuPopupPoint(
            statusButtonBounds: button.bounds,
            statusButtonIsFlipped: button.isFlipped,
            menuWidth: self.renderedMenuWidth(for: menu))
        menu.popUp(positioning: nil, at: point, in: button)
    }

    func showMidasAccountSettings(provider: UsageProvider) {
        self.preferencesSelection.showProvider(provider)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(
            name: .codexbarOpenSettings,
            object: nil,
            userInfo: ["tab": PreferencesTab.providers.rawValue])
    }
}
