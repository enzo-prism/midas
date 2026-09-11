import CodexBarCore
import Foundation

extension UsageStore {
    func refreshMidasCloudUsage(
        force: Bool,
        loader: (([String: String], Date) async throws -> CodexCloudAccountUsage)? = nil) async
    {
        guard self.settings.costUsageEnabled, self.isEnabled(.codex) else {
            self.tokenSnapshots[.codex] = nil
            return
        }
        guard !self.midasCloudRefreshInFlight else { return }
        let accounts = self.settings.codexVisibleAccountProjection.visibleAccounts
        let signature = Self.cloudAccountSignature(accounts)
        let now = Date()
        if !force, self.lastTokenFetchScope[.codex] == "cloud:" + signature,
           let last = self.lastTokenFetchAt[.codex], now.timeIntervalSince(last) < 300 { return }
        self.midasCloudRefreshInFlight = true
        self.tokenRefreshInFlight.insert(.codex)
        defer {
            self.midasCloudRefreshInFlight = false
            self.tokenRefreshInFlight.remove(.codex)
        }
        let stored = self.settings.codexAccountReconciliationSnapshot.storedAccounts
        var results = self.lastTokenFetchScope[.codex] == "cloud:" + signature
            ? self.midasCloudAccounts.filter { key, _ in accounts.contains { $0.id == key } }
            : (SettingsStore.isRunningTests ? [:] : Self.loadCloudCache(signature: signature))
        var errors: [String: String] = [:]
        for account in accounts {
            if Task.isCancelled { return }
            var environment = self.environmentBase
            if let id = account.storedAccountID, let saved = stored.first(where: { $0.id == id }) {
                environment["CODEX_HOME"] = saved.managedHomePath
            }
            do {
                if let loader {
                    results[account.id] = try await loader(environment, now)
                } else {
                    results[account.id] = try await CodexCloudUsageFetcher.fetch(env: environment, now: now)
                }
            } catch {
                if error is CancellationError { return }
                errors[account.id] = error.localizedDescription
            }
        }
        guard !Task.isCancelled, self.settings.midasCloudUsageEnabled,
              self.settings.costUsageEnabled, self.isEnabled(.codex),
              Self.cloudAccountSignature(self.settings.codexVisibleAccountProjection.visibleAccounts)
              == signature else { return }
        self.midasCloudAccounts = results
        self.midasCloudErrors = errors
        if !SettingsStore.isRunningTests { Self.saveCloudCache(results, signature: signature) }
        self.lastTokenFetchAt[.codex] = now
        self.lastTokenFetchScope[.codex] = "cloud:" + signature
        self.tokenSnapshots[.codex] = Self.cloudTokenSnapshot(
            accounts: Array(results.values), rate: self.settings.midasCloudUSDPerMillionTokens, now: now)
        self.tokenErrors[.codex] = errors.isEmpty ? nil : "Some cloud account histories could not refresh."
        self.persistWidgetSnapshot(reason: "cloud-token-usage")
    }

    private struct CloudCache: Codable {
        let signature: String
        let accounts: [String: CodexCloudAccountUsage]
    }

    private nonisolated static var cloudCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexBar/midas-cloud-usage.json")
    }

    private nonisolated static func loadCloudCache(signature: String) -> [String: CodexCloudAccountUsage] {
        guard let data = try? Data(contentsOf: self.cloudCacheURL),
              let cache = try? JSONDecoder().decode(CloudCache.self, from: data),
              cache.signature == signature else { return [:] }
        return cache.accounts
    }

    private nonisolated static func saveCloudCache(
        _ accounts: [String: CodexCloudAccountUsage], signature: String)
    {
        guard let data = try? JSONEncoder().encode(CloudCache(signature: signature, accounts: accounts)) else { return }
        try? FileManager.default.createDirectory(
            at: self.cloudCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: self.cloudCacheURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.cloudCacheURL.path)
    }

    private nonisolated static func cloudAccountSignature(_ accounts: [CodexVisibleAccount]) -> String {
        accounts.map {
            "\($0.id)|\($0.workspaceAccountID ?? "")|\($0.storedAccountID?.uuidString ?? "live")"
        }.sorted().joined(separator: ";")
    }

    nonisolated static func cloudTokenSnapshot(
        accounts: [CodexCloudAccountUsage], rate: Double, now: Date) -> CostUsageTokenSnapshot
    {
        let range = CodexCloudAccountUsage.window(now: now)
        var days: [String: Int] = [:]
        for account in accounts {
            for day in account.days where day.date >= range.start && day.date <= range.end {
                let sum = (days[day.date] ?? 0).addingReportingOverflow(day.tokens)
                guard !sum.overflow else {
                    return CostUsageTokenSnapshot(
                        sessionTokens: nil,
                        sessionCostUSD: nil,
                        last30DaysTokens: nil,
                        last30DaysCostUSD: nil,
                        historyDays: 30,
                        daily: [],
                        updatedAt: now)
                }
                days[day.date] = sum.partialValue
            }
        }
        let validRate = rate.isFinite && rate > 0
        let entries = days.sorted { $0.key < $1.key }.map { date, tokens in
            CostUsageDailyReport.Entry(
                date: date,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: tokens,
                costUSD: validRate ? Double(tokens) / 1_000_000 * rate : nil,
                modelsUsed: nil,
                modelBreakdowns: nil)
        }
        let tokens: Int? = entries.isEmpty ? nil : entries.reduce(Int?.some(0)) { total, entry in
            guard let total else { return nil }
            let added = total.addingReportingOverflow(entry.totalTokens ?? 0)
            return added.overflow ? nil : added.partialValue
        }
        return CostUsageTokenSnapshot(
            sessionTokens: days[range.end],
            sessionCostUSD: days[range.end].flatMap {
                validRate ? Double($0) / 1_000_000 * rate : nil
            },
            last30DaysTokens: tokens,
            last30DaysCostUSD: tokens.flatMap { validRate ? Double($0) / 1_000_000 * rate : nil },
            historyDays: 30,
            historyLabel: "Last 30 days",
            costProvenance: .unknown,
            daily: entries,
            updatedAt: accounts.map(\.fetchedAt).min() ?? now)
    }
}
