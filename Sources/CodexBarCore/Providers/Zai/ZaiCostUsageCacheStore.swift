import Foundation

/// On-disk cache for the estimated z.ai cost report's raw per-model token payloads.
///
/// z.ai exposes no billing API; the cost report is built from per-model token counts × public GLM
/// rates (see `ZaiCostUsageFetcher`). Pricing comes from two sources: a built-in rate table
/// (`CostUsagePricing.zai`) and the upstream `models.dev` catalog. The priced report itself is
/// cheap to derive from the raw token data, so this cache stores the **raw per-model payloads**
/// (the part that requires network I/O) and lets callers recompute the priced report at view time.
///
/// This means:
/// - A change to the built-in GLM rates (`CostUsagePricing.zaiBuiltInPricingFingerprint`) is
///   reflected the next time the cache is read — the priced report is rebuilt with current rates.
/// - The expensive week-long chunked fetches are cached for up to `maxAgeSeconds`, so a refresh
///   storm (e.g. multiple manual refreshes) doesn't re-hit the endpoint.
/// - A region change naturally invalidates: the cache key includes `region.rawValue`.
public enum ZaiCostUsageCacheStore {
    private static let currentVersion = 1
    private static let cacheFilename = "zai-model-usage-v1.json"

    private struct Payload: Codable {
        let version: Int
        let cacheKey: String
        let savedAt: Date
        let since: Date
        let until: Date
        let collected: [ZaiModelUsageData]
    }

    public struct CacheKey: Hashable, Sendable {
        public let region: ZaiAPIRegion
        public let historyDays: Int

        public var stringValue: String {
            // Note: pricing fingerprint intentionally NOT included — the cache stores raw tokens,
            // and pricing changes invalidate via re-pricing at view time, not via cache eviction.
            "region=\(self.region.rawValue)|days=\(self.historyDays)"
        }
    }

    public struct CachedPayload: Sendable {
        public let collected: [ZaiModelUsageData]
        public let since: Date
        public let until: Date
        public let savedAt: Date
    }

    /// Maximum age for a cache entry to be considered fresh. The z.ai cost path runs on a 1-hour
    /// token-cost timer anyway, so a 30-minute TTL keeps disk hits cheap without serving stale
    /// data for very long after a model-usage change.
    private static let maxAgeSeconds: TimeInterval = 30 * 60

    public static func defaultURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return caches
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent(self.cacheFilename, isDirectory: false)
    }

    public static func load(
        key: CacheKey,
        now: Date = Date(),
        fileURL: URL = defaultURL()) -> CachedPayload?
    {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL)
        else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data),
              payload.version == currentVersion,
              payload.cacheKey == key.stringValue
        else {
            return nil
        }

        let age = now.timeIntervalSince(payload.savedAt)
        guard age >= 0, age <= self.maxAgeSeconds else { return nil }

        return CachedPayload(
            collected: payload.collected,
            since: payload.since,
            until: payload.until,
            savedAt: payload.savedAt)
    }

    public static func store(
        collected: [ZaiModelUsageData],
        key: CacheKey,
        since: Date,
        until: Date,
        now: Date = Date(),
        fileURL: URL = defaultURL())
    {
        let payload = Payload(
            version: currentVersion,
            cacheKey: key.stringValue,
            savedAt: now,
            since: since,
            until: until,
            collected: collected)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }

        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
            #if os(macOS)
            try? FileManager.default.setAttributes([
                .posixPermissions: NSNumber(value: Int16(0o600)),
            ], ofItemAtPath: fileURL.path)
            #endif
        } catch {
            // Cache persistence is best-effort; never fail the report over a disk write.
        }
    }
}
