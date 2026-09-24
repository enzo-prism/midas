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

    func persistCursorSpendSnapshot(_ snapshot: CostUsageTokenSnapshot) {
        let email = self.snapshots[.cursor]?.identity?.accountEmail
        self.cursorSpendAccountKey = CursorSpendSnapshotCache.normalizedAccountKey(email)
        Task.detached(priority: .utility) {
            CursorSpendSnapshotCache.save(snapshot, accountEmail: email)
        }
    }

    /// Shows the last Cursor estimate right after launch, before cursor.com answers.
    func hydrateCachedCursorSpend() {
        guard self.settings.costUsageEnabled, self.isEnabled(.cursor), self.tokenSnapshots[.cursor] == nil else {
            return
        }
        let email = self.snapshots[.cursor]?.identity?.accountEmail
        let historyDays = self.settings.costUsageHistoryDays
        Task { @MainActor [weak self] in
            let loaded = await Task.detached(priority: .utility) {
                (
                    snapshot: CursorSpendSnapshotCache.load(accountEmail: email, historyDays: historyDays),
                    accountKey: CursorSpendSnapshotCache.cachedAccountKey())
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

    /// A cached or kept estimate belongs to the signed-in Cursor account, or the account is not yet known.
    func cursorSpendMatchesCurrentAccount() -> Bool {
        guard let current = CursorSpendSnapshotCache.normalizedAccountKey(
            self.snapshots[.cursor]?.identity?.accountEmail),
            let cached = self.cursorSpendAccountKey
        else { return true }
        return current == cached
    }
}
