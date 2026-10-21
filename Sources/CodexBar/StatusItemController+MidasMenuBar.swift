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
        let token = self.store.displayTokenSnapshot(for: provider)
        var result = MidasProviderPresentation.make(
            provider: provider,
            card: self.menuCardModel(for: provider),
            snapshot: snapshot,
            tokenSnapshot: token,
            isRefreshing: self.store.shouldShowRefreshingMenuCardIndicator(for: provider),
            isStale: self.store.isStale(provider: provider)
                || (self.settings.midasMenuBarMode != .orbit && self.store.tokenErrors[provider] != nil))
        let usesSyncedUsage = self.store.usesSyncedUsage(for: provider)
        if usesSyncedUsage, provider != .localInference {
            result.spend?.detail = provider == .cursor
                ? "Shared Cursor history, counted once per account and UTC day. An API-rate estimate, not a bill."
                : "Combined recorded session history across Macs, counted once. An API-rate estimate, not a bill."
        }
        if provider == .codex, self.settings.midasCloudUsageEnabled {
            // Cloud coverage follows all connected accounts independently of the quota layout.
            let accounts = self.settings.codexVisibleAccountProjection.visibleAccounts
            let hasCurrentCloudScope = self.store.lastTokenFetchScope[.codex]
                == "cloud:" + UsageStore.cloudAccountSignature(accounts)
            let rows = accounts.map { account in
                MidasCloudUsagePresentation.Account(
                    id: account.id,
                    name: self.settings
                        .hidePersonalInfo ? "Account" : (self.accountInfo(for: account).email ?? "Account"),
                    usage: hasCurrentCloudScope ? self.store.midasCloudAccounts[account.id] : nil,
                    error: hasCurrentCloudScope ? self.store.midasCloudErrors[account.id] : nil)
            }
            // The display snapshot can be shared session history. Cloud account history has its own scope.
            let cloudToken = self.store.lastTokenFetchScope[.codex]?.hasPrefix("cloud:") == true
                ? self.store.tokenSnapshot(for: .codex) : nil
            result = MidasCloudUsagePresentation.attachingAccountHistory(
                to: result,
                accounts: rows,
                tokenSnapshot: cloudToken,
                estimate: self.store.midasCodexEstimate,
                usesSyncedUsage: usesSyncedUsage)
        } else if !usesSyncedUsage, provider == .codex, self.settings.midasTrackAllAccounts, result.spend != nil {
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
        let providers = self.store.midasProvidersForUsageDisplay()
        let presentations = providers.map { provider in
            MidasMenuBarAccountSelection.project(
                providerPresentation: self.midasProviderPresentation(for: provider),
                accounts: self.midasAccountPresentations(for: provider, includeAll: true),
                selectedAccountID: self.settings.midasMenuBarAccountID(for: provider),
                hidePersonalInfo: self.settings.hidePersonalInfo)
        }
        let inFlight = self.store.refreshingProviders.union(self.store.tokenRefreshInFlight)
        // Background work preserves the cached display. Only real initial/manual work moves.
        let visibleActivity = Set(inFlight.filter { provider in
            self.menuCardRefreshMonitor.isManualRefreshInFlight
                || (self.store.snapshot(for: provider) == nil && self.store.displayTokenSnapshot(for: provider) == nil)
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
                let snapshot = self.store.displayTokenSnapshot(for: provider)
                return snapshot.map { (provider, $0) }
            })
            button.toolTip = MidasTokenTooltip.text(
                favorite: self.settings.midasMenuBarFocusProvider, providers: providers, snapshots: tokens)
            if let focused = presentations.first(where: { $0.provider == self.settings.midasMenuBarFocusProvider }) {
                let quota = presentation.orbitRemainingPercent.map {
                    "\($0.formatted())% remaining, \(focused.orbitQuota?.title ?? "Quota")"
                }
                    ?? "Quota unavailable"
                button.toolTip = [button.toolTip, "\(focused.name): \(quota)"].compactMap(\.self)
                    .joined(separator: "\n")
            }
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
