import CodexBarCore
import Foundation

extension UsageStore {
    func tokenSnapshot(for provider: UsageProvider) -> CostUsageTokenSnapshot? {
        self.tokenSnapshots[provider]
    }

    func tokenError(for provider: UsageProvider) -> String? {
        self.tokenErrors[provider]
    }

    func tokenLastAttemptAt(for provider: UsageProvider) -> Date? {
        self.lastTokenFetchAt[provider]
    }

    func hydrateCachedTokenSnapshots(now: Date = Date()) {
        guard self.settings.costUsageEnabled, !self.settings.midasCloudUsageEnabled else { return }
        guard self.settings.enabledProvidersOrdered(metadataByProvider: self.providerMetadata).contains(.codex) else {
            return
        }

        let scope = self.tokenCostScope(for: .codex)
        let historyDays = self.settings.costUsageHistoryDays
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.tokenSnapshots[.codex] == nil else { return }
            guard let snapshot = await self.costUsageFetcher.loadCachedCodexTokenSnapshot(
                now: now,
                codexHomePath: scope.codexHomePath,
                codexAdditionalHomePaths: scope.additionalHomes,
                historyDays: historyDays)
            else {
                return
            }
            guard self.settings.costUsageEnabled,
                  self.isEnabled(.codex),
                  self.tokenCostScope(for: .codex).signature == scope.signature,
                  self.tokenSnapshots[.codex] == nil
            else {
                return
            }
            self.tokenSnapshots[.codex] = snapshot
            self.tokenErrors[.codex] = nil
        }
    }

    func scheduleCostUsageCacheMaintenance() {
        self.costUsageCacheMaintenanceTask?.cancel()
        let logger = self.tokenCostLogger
        self.costUsageCacheMaintenanceTask = Task.detached(priority: .utility) {
            let result = CostUsageCacheMaintenance.pruneStaleArtifacts()
            if !result.failedRemovals.isEmpty {
                logger.warning(
                    "Cost usage cache maintenance had removal failures",
                    metadata: [
                        "failures": "\(result.failedRemovals.count)",
                    ])
            }
            if !result.removedPaths.isEmpty {
                logger.info(
                    "Cost usage cache maintenance pruned stale artifacts",
                    metadata: [
                        "removed": "\(result.removedPaths.count)",
                    ])
            }
        }
    }

    func isTokenRefreshInFlight(for provider: UsageProvider) -> Bool {
        self.tokenRefreshInFlight.contains(provider)
    }

    func tokenCostScope(for provider: UsageProvider)
    -> (codexHomePath: String?, additionalHomes: [String], signature: String) {
        if provider == .cursor {
            // Cursor spend is account-owned; a different signed-in account is a different history.
            return (nil, [], "cursor:" + (self.cursorStatusAccountKey ?? "unknown"))
        }
        guard provider == .codex else {
            return (nil, [], provider.rawValue)
        }
        if self.settings.midasTrackAllAccounts {
            let homes = self.settings.codexAccountReconciliationSnapshot.storedAccounts
                .map(\.managedHomePath).sorted()
            return (nil, homes, "codex:all:" + homes.joined(separator: "|"))
        }
        // Local spend is machine-level session history. Managed account homes may contain only
        // authentication, so choosing a quota account must not replace the ambient history source.
        return (nil, [], "codex:ambient")
    }

    func tokenSnapshot(
        fromProviderSnapshot snapshot: UsageSnapshot?,
        provider: UsageProvider)
        -> CostUsageTokenSnapshot?
    {
        switch provider {
        case .openai:
            snapshot?.openAIAPIUsage?.toCostUsageTokenSnapshot()
        case .anthropic:
            snapshot?.claudeAdminAPIUsage?.toCostUsageTokenSnapshot()
        case .mistral:
            snapshot?.mistralUsage?.toCostUsageTokenSnapshot(historyDays: self.settings.costUsageHistoryDays)
        default:
            nil
        }
    }

    nonisolated static func tokenCostRequiresProviderSnapshot(_ provider: UsageProvider) -> Bool {
        switch provider {
        case .mistral, .openai, .anthropic:
            true
        default:
            false
        }
    }

    nonisolated static func costUsageCacheDirectory(
        fileManager: FileManager = .default) -> URL
    {
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root
            .appendingPathComponent(MidasIdentity.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("cost-usage", isDirectory: true)
    }

    func clearCostUsageCache() async -> String? {
        let errorMessage: String? = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let cacheDirs = [
                Self.costUsageCacheDirectory(fileManager: fm),
            ]

            for cacheDir in cacheDirs {
                do {
                    try fm.removeItem(at: cacheDir)
                } catch let error as NSError {
                    if error.domain == NSCocoaErrorDomain, error.code == NSFileNoSuchFileError { continue }
                    return error.localizedDescription
                }
            }
            return nil
        }.value

        guard errorMessage == nil else { return errorMessage }

        self.tokenSnapshots.removeAll()
        self.tokenErrors.removeAll()
        self.lastTokenFetchAt.removeAll()
        self.lastTokenFetchScope.removeAll()
        self.tokenFailureGates[.codex]?.reset()
        self.tokenFailureGates[.claude]?.reset()
        return nil
    }

    nonisolated static func tokenCostNoDataMessage(for provider: UsageProvider) -> String {
        ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.noDataMessage()
    }
}

// MARK: - Cursor last-known spend

extension UsageStore {
    func recordTokenRefreshFailure(provider: UsageProvider, error: Error) {
        let hadPriorData = self.tokenSnapshots[provider] != nil
        let shouldSurface = self.tokenFailureGates[provider]?
            .shouldSurfaceError(onFailureWithPriorData: hadPriorData) ?? true
        if shouldSurface, self.keepsLastKnownCursorSpend(provider: provider, error: error) {
            // Cursor's estimate is rebuilt from cursor.com on every refresh. Keep the last good value,
            // labeled last known through the token error, instead of blanking it after two failures.
            self.tokenErrors[provider] = error.localizedDescription
        } else if shouldSurface {
            self.tokenErrors[provider] = error.localizedDescription
            self.tokenSnapshots.removeValue(forKey: provider)
        } else {
            self.tokenErrors[provider] = nil
        }
    }

    /// Cursor's spend comes from cursor.com on every refresh, so a failed or slow fetch must not blank it.
    func keepsLastKnownCursorSpend(provider: UsageProvider, error: Error) -> Bool {
        guard provider == .cursor, self.tokenSnapshots[.cursor] != nil else { return false }
        if case CostUsageError.sourceDisabled = error { return false }
        return self.cursorSpendMatchesCurrentAccount()
    }

    /// The signed-in Cursor account from the latest usage snapshot. A token-account label stands in for a
    /// missing email there, so only an address identifies an account.
    var cursorStatusAccountKey: String? {
        CursorSpendSnapshotCache.normalizedAccountKey(self.snapshots[.cursor]?.identity?.accountEmail)
            .flatMap { $0.contains("@") ? $0 : nil }
    }

    /// Accepts a fresh Cursor estimate only for the signed-in account, then records and caches its owner.
    /// Returns false when the cost report came from a different Cursor session than the usage limits.
    func acceptCursorSpendSnapshot(_ snapshot: CostUsageTokenSnapshot) -> Bool {
        let reported = CursorSpendSnapshotCache.normalizedAccountKey(snapshot.accountEmail)
        let current = self.cursorStatusAccountKey
        if let reported, let current, reported != current {
            self.tokenSnapshots.removeValue(forKey: .cursor)
            self.tokenErrors[.cursor] = "Cursor spend came from a different signed-in Cursor account than usage; "
                + "sign out of the other account in your browser or set a manual cookie."
            self.cursorSpendAccountKey = nil
            return false
        }
        let owner = reported ?? current
        self.cursorSpendAccountKey = owner
        let cacheRoot = self.cursorSpendCacheRoot
        // Like the other on-disk stores, test stores persist only to an explicit root.
        guard self.startupBehavior.automaticallyStartsBackgroundWork || cacheRoot != nil else { return true }
        Task.detached(priority: .utility) {
            CursorSpendSnapshotCache.save(snapshot, accountEmail: owner, cacheRoot: cacheRoot)
        }
        return true
    }

    /// Drops a shown Cursor estimate once the signed-in account is known to be someone else. Unowned estimates
    /// (an older cache, or a report whose account was unknown) cannot be attributed, so they are dropped too.
    func dropCursorSpendFromAnotherAccount() {
        guard self.tokenSnapshots[.cursor] != nil, !self.cursorSpendMatchesCurrentAccount() else { return }
        self.tokenSnapshots.removeValue(forKey: .cursor)
        self.tokenErrors[.cursor] = nil
        self.cursorSpendAccountKey = nil
    }

    /// Shows the last Cursor estimate right after launch, before cursor.com answers.
    func hydrateCachedCursorSpend() {
        guard self.settings.costUsageEnabled, self.isEnabled(.cursor), self.tokenSnapshots[.cursor] == nil else {
            return
        }
        let email = self.cursorStatusAccountKey
        let historyDays = self.settings.costUsageHistoryDays
        let cacheRoot = self.cursorSpendCacheRoot
        Task { @MainActor [weak self] in
            let loaded = await Task.detached(priority: .utility) {
                (
                    snapshot: CursorSpendSnapshotCache.load(
                        accountEmail: email,
                        historyDays: historyDays,
                        cacheRoot: cacheRoot),
                    accountKey: CursorSpendSnapshotCache.cachedAccountKey(cacheRoot: cacheRoot))
            }.value
            guard let self, let snapshot = loaded.snapshot,
                  self.settings.costUsageEnabled, self.isEnabled(.cursor),
                  self.settings.costUsageHistoryDays == historyDays,
                  self.tokenSnapshots[.cursor] == nil
            else { return }
            self.cursorSpendAccountKey = loaded.accountKey
            guard self.cursorSpendMatchesCurrentAccount() else { return }
            self.tokenSnapshots[.cursor] = snapshot
        }
    }

    /// A cached or kept estimate belongs to the signed-in Cursor account, or that account is not yet known.
    /// Once it is known, an estimate without a recorded owner no longer matches.
    func cursorSpendMatchesCurrentAccount() -> Bool {
        guard let current = self.cursorStatusAccountKey else { return true }
        return self.cursorSpendAccountKey == current
    }
}
