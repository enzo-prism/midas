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
        var result = MidasProviderPresentation.make(
            provider: provider,
            card: self.menuCardModel(for: provider),
            snapshot: snapshot,
            tokenSnapshot: token,
            isRefreshing: self.store.shouldShowRefreshingMenuCardIndicator(for: provider),
            isStale: self.store.isStale(provider: provider)
                || (self.settings.midasMenuBarMode != .orbit && self.store.tokenErrors[provider] != nil))
        if provider == .codex, self.settings.midasCloudUsageEnabled {
            // Cloud coverage follows all connected accounts independently of the quota layout.
            let rows = self.settings.codexVisibleAccountProjection.visibleAccounts.map { account in
                MidasCloudUsagePresentation.Account(
                    id: account.id,
                    name: self.settings
                        .hidePersonalInfo ? "Account" : (self.accountInfo(for: account).email ?? "Account"),
                    usage: self.store.midasCloudAccounts[account.id],
                    error: self.store.midasCloudErrors[account.id])
            }
            let cloudToken = self.store.lastTokenFetchScope[.codex]?.hasPrefix("cloud:") == true ? token : nil
            let estimate = self.store.midasCodexEstimate
            result.spend = nil
            if let estimate, let amount = cloudToken?.last30DaysCostUSD, amount.isFinite,
               let updatedAt = cloudToken?.updatedAt
            {
                result.spend = MidasSpendPresentation(
                    title: "Estimated inference spend",
                    value: amount.formatted(.currency(code: "USD")),
                    period: "Last 30 days",
                    detail: estimate.detail + " "
                        + "Missing account histories and reporting delays are excluded.",
                    updatedAt: updatedAt,
                    amount: amount,
                    currency: "USD",
                    secondaryValue: nil,
                    secondaryLabel: nil,
                    isEstimate: true)
            }
            result.cloudUsage = MidasCloudUsagePresentation(
                accounts: rows, tokens: cloudToken?.last30DaysTokens, hasEstimate: result.spend != nil)
        } else if provider == .codex, self.settings.midasTrackAllAccounts, result.spend != nil {
            result.spend?.detail = "Combined local Codex history across accounts, counted once. "
                + "Other devices and account-by-account cost attribution are unavailable. "
                + "This is an API-rate estimate, not a bill."
        }
        return self.midasPeriodPresentation(result, token: token)
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
        let incidents = Dictionary(uniqueKeysWithValues: providers.compactMap { provider -> (UsageProvider, String)? in
            guard let status = self.store.statuses[provider],
                  status.indicator != .none, status.indicator != .unknown else { return nil }
            let name = ProviderDefaults.metadata[provider]?.displayName ?? provider.rawValue
            return (provider, "\(name) service status: \(status.indicator.label)")
        })
        let presentation = MidasMenuBarPresentation(
            mode: self.settings.midasMenuBarMode,
            presentations: presentations,
            focusProvider: self.settings.midasMenuBarFocusProvider,
            refreshingProviders: visibleActivity,
            hideSpend: self.settings.midasMenuBarHideSpend,
            incidentDescriptions: providers.compactMap { incidents[$0] },
            incidentDescriptionsByProvider: incidents,
            spendStatusDescriptions: providers.compactMap { provider in
                guard self.store.tokenErrors[provider] != nil else { return nil }
                let name = ProviderDefaults.metadata[provider]?.displayName ?? provider.rawValue
                return "\(name) token spend: refresh failed; any displayed value is last known"
            })
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
        if self.settings.midasMenuBarMode == .orbit {
            let tokens = Dictionary(uniqueKeysWithValues: providers.compactMap { provider in
                let snapshot = self.store.tokenSnapshot(
                    fromProviderSnapshot: self.store.snapshot(for: provider), provider: provider)
                    ?? (UsageStore.tokenCostRequiresProviderSnapshot(provider)
                        ? nil : self.store.tokenSnapshot(for: provider))
                return snapshot.map { (provider, $0) }
            })
            button.toolTip = MidasTokenTooltip.text(
                favorite: self.settings.midasMenuBarFocusProvider, providers: providers, snapshots: tokens)
        } else {
            button.toolTip = presentation.tooltip
        }
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
