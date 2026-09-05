import AppKit
import CodexBarCore

extension StatusItemController {
    var usesMidasMenuBar: Bool {
        self.usesMidasAir && self.settings.midasMenuBarMode != .legacy
    }

    func renderMidasMenuBarIcon() -> Bool {
        self.updateMidasMenuBar()
        return false
    }

    func midasProviderPresentation(for provider: UsageProvider) -> MidasProviderPresentation {
        let snapshot = self.store.snapshot(for: provider)
        let projected = self.store.tokenSnapshot(fromProviderSnapshot: snapshot, provider: provider)
        let token = projected ?? (UsageStore.tokenCostRequiresProviderSnapshot(provider)
            ? nil : self.store.tokenSnapshot(for: provider))
        return .make(
            provider: provider,
            card: self.menuCardModel(for: provider),
            snapshot: snapshot,
            tokenSnapshot: token,
            isRefreshing: self.store.shouldShowRefreshingMenuCardIndicator(for: provider),
            isStale: self.store.isStale(provider: provider) || self.store.tokenErrors[provider] != nil)
    }

    func updateMidasMenuBar() {
        guard self.usesMidasMenuBar, !self.hasPreparedForAppShutdown,
              let button = self.statusItem.button else { return }
        self.menuBarCountdownRefreshTask?.cancel()
        self.menuBarCountdownRefreshTask = nil
        let providers = self.store.enabledProvidersForDisplay()
        let presentations = providers.map { self.midasProviderPresentation(for: $0) }
        let inFlight = self.store.refreshingProviders.union(self.store.tokenRefreshInFlight)
        // Background work preserves the cached display. Only real initial/manual work moves.
        let visibleActivity = Set(inFlight.filter { provider in
            self.menuCardRefreshMonitor.isManualRefreshInFlight
                || (self.store.snapshot(for: provider) == nil && self.store.tokenSnapshot(for: provider) == nil)
        })
        let incidents = providers.compactMap { provider -> String? in
            guard let status = self.store.statuses[provider],
                  status.indicator != .none, status.indicator != .unknown else { return nil }
            let name = ProviderDefaults.metadata[provider]?.displayName ?? provider.rawValue
            return "\(name) service status: \(status.indicator.label)"
        }
        let presentation = MidasMenuBarPresentation(
            mode: self.settings.midasMenuBarMode,
            presentations: presentations,
            focusProvider: self.settings.midasMenuBarFocusProvider,
            refreshingProviders: visibleActivity,
            hideSpend: self.settings.midasMenuBarHideSpend,
            incidentDescriptions: incidents)
        self.statusItem.length = presentation.width
        button.image = nil
        button.title = ""
        let view: MidasMenuBarView
        if let existing = self.midasMenuBarView, existing.superview === button {
            view = existing
        } else {
            self.midasMenuBarView?.removeFromSuperview()
            view = MidasMenuBarView(frame: button.bounds)
            view.autoresizingMask = [.width, .height]
            button.addSubview(view)
            self.midasMenuBarView = view
        }
        view.frame = NSRect(x: 0, y: 0, width: presentation.width, height: button.bounds.height)
        view.update(
            presentation: presentation,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        button.toolTip = presentation.tooltip
        button.setAccessibilityTitle(presentation.accessibilityLabel)
        button.setAccessibilityLabel(presentation.accessibilityLabel)
        self.startMidasFreshnessUpdatesIfNeeded()
    }

    private func startMidasFreshnessUpdatesIfNeeded() {
        if !self.observesMidasAccessibility {
            NSWorkspace.shared.notificationCenter.addObserver(
                self,
                selector: #selector(self.midasAccessibilityChanged),
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil)
            self.observesMidasAccessibility = true
        }
        guard self.midasMenuBarFreshnessTask == nil else { return }
        self.midasMenuBarFreshnessTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, self.usesMidasMenuBar, !self.hasPreparedForAppShutdown else { return }
                self.updateMidasMenuBar()
            }
        }
    }

    @objc private func midasAccessibilityChanged() {
        self.updateMidasMenuBar()
    }

    func removeMidasMenuBar() {
        guard self.midasMenuBarView != nil || self.midasMenuBarFreshnessTask != nil else { return }
        self.midasMenuBarView?.removeFromSuperview()
        self.midasMenuBarView = nil
        self.midasMenuBarFreshnessTask?.cancel()
        self.midasMenuBarFreshnessTask = nil
        if self.observesMidasAccessibility {
            NSWorkspace.shared.notificationCenter.removeObserver(
                self, name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            self.observesMidasAccessibility = false
        }
        self.statusItem.length = NSStatusItem.variableLength
        self.statusItem.button?.toolTip = "Midas"
        self.statusItem.button?.setAccessibilityTitle("Midas")
        self.statusItem.button?.setAccessibilityLabel("Midas")
        self.lastAppliedMergedIconRenderSignature = nil
    }
}
