import Foundation

/// Last successful Cursor spend estimate, persisted so Midas can show it immediately after launch
/// and keep it through transient cursor.com failures instead of blanking the estimate.
///
/// Cursor's estimate is rebuilt from the dashboard's usage-events API on every refresh; unlike
/// Codex and Claude there is no local log to rescan. The cached value keeps its original
/// `updatedAt`, so freshness indicators still report its real age.
public enum CursorSpendSnapshotCache {
    public static let fileName = "cursor-spend-v1.json"
    private static let version = 1

    private struct Payload: Codable {
        let version: Int
        /// Normalized Cursor account email when known; a different account never reuses this value.
        let accountKey: String?
        let snapshot: StoredSnapshot
    }

    private struct StoredSnapshot: Codable {
        let sessionTokens: Int?
        let sessionCostUSD: Double?
        let sessionRequests: Int?
        let last30DaysTokens: Int?
        let last30DaysCostUSD: Double?
        let last30DaysAPIEquivalentCostUSD: Double?
        let last30DaysRequests: Int?
        let currencyCode: String
        let historyDays: Int
        let historyLabel: String?
        let meteredCostUSD: Double?
        let costProvenance: CostProvenance
        let daily: [CostUsageDailyReport.Entry]
        let updatedAt: Date
    }

    public static func fileURL(cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(MidasIdentity.supportDirectoryName, isDirectory: true)
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent(self.fileName, isDirectory: false)
    }

    public static func normalizedAccountKey(_ email: String?) -> String? {
        let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.flatMap { $0.isEmpty ? nil : $0 }
    }

    @discardableResult
    public static func save(
        _ snapshot: CostUsageTokenSnapshot,
        accountEmail: String?,
        cacheRoot: URL? = nil) -> Bool
    {
        let payload = Payload(
            version: self.version,
            accountKey: self.normalizedAccountKey(accountEmail),
            snapshot: StoredSnapshot(
                sessionTokens: snapshot.sessionTokens,
                sessionCostUSD: snapshot.sessionCostUSD,
                sessionRequests: snapshot.sessionRequests,
                last30DaysTokens: snapshot.last30DaysTokens,
                last30DaysCostUSD: snapshot.last30DaysCostUSD,
                last30DaysAPIEquivalentCostUSD: snapshot.last30DaysAPIEquivalentCostUSD,
                last30DaysRequests: snapshot.last30DaysRequests,
                currencyCode: snapshot.currencyCode,
                historyDays: snapshot.historyDays,
                historyLabel: snapshot.historyLabel,
                meteredCostUSD: snapshot.meteredCostUSD,
                costProvenance: snapshot.costProvenance,
                daily: snapshot.daily,
                updatedAt: snapshot.updatedAt))
        let url = self.fileURL(cacheRoot: cacheRoot)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            try encoder.encode(payload).write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    /// The cached snapshot, or nil when missing, unreadable, from another version or history window, or
    /// from a different account. Pass nil while the account is not yet known (for example at launch); the
    /// first successful refresh then replaces the value.
    public static func load(
        accountEmail: String?,
        historyDays: Int,
        cacheRoot: URL? = nil) -> CostUsageTokenSnapshot?
    {
        let url = self.fileURL(cacheRoot: cacheRoot)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let payload = try? decoder.decode(Payload.self, from: data),
              payload.version == self.version,
              payload.snapshot.historyDays == historyDays
        else { return nil }
        let current = self.normalizedAccountKey(accountEmail)
        if let current {
            guard payload.accountKey == nil || payload.accountKey == current else { return nil }
        }
        let stored = payload.snapshot
        return CostUsageTokenSnapshot(
            sessionTokens: stored.sessionTokens,
            sessionCostUSD: stored.sessionCostUSD,
            sessionRequests: stored.sessionRequests,
            last30DaysTokens: stored.last30DaysTokens,
            last30DaysCostUSD: stored.last30DaysCostUSD,
            last30DaysAPIEquivalentCostUSD: stored.last30DaysAPIEquivalentCostUSD,
            last30DaysRequests: stored.last30DaysRequests,
            currencyCode: stored.currencyCode,
            historyDays: stored.historyDays,
            historyLabel: stored.historyLabel,
            meteredCostUSD: stored.meteredCostUSD,
            costProvenance: stored.costProvenance,
            daily: stored.daily,
            updatedAt: stored.updatedAt)
    }

    /// The account email the cache was written for, if any.
    public static func cachedAccountKey(cacheRoot: URL? = nil) -> String? {
        guard let data = try? Data(contentsOf: self.fileURL(cacheRoot: cacheRoot)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(Payload.self, from: data))?.accountKey
    }

    public static func remove(cacheRoot: URL? = nil) {
        try? FileManager.default.removeItem(at: self.fileURL(cacheRoot: cacheRoot))
    }
}
