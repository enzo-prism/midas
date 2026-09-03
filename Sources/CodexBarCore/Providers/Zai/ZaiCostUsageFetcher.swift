import Foundation

/// Builds an estimated z.ai cost report from the `model-usage` monitoring endpoint.
///
/// z.ai exposes no billing/spend API. This fetcher pulls per-model hourly token counts over the
/// requested window (chunked into week-long requests to stay within the endpoint's practical range),
/// aggregates them into daily buckets, and prices each model with a blended USD-per-token rate
/// (`CostUsagePricing.zaiCostUSD`). The result is an *estimate*, not real billing.
public struct ZaiCostUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.zaiUsage)

    /// Maximum span (in days) for a single `model-usage` request. The endpoint is designed for
    /// monitoring charts and accepts arbitrary ranges, but we chunk to keep individual responses
    /// bounded and resilient to upstream range caps.
    private static let chunkDaySpan = 7

    /// Maximum number of chunk fetches to run in parallel. z.ai's monitoring endpoint tolerates
    /// concurrent reads but we cap concurrency to be polite and to keep a single cost refresh
    /// from spawning a burst of five simultaneous HTTPS requests.
    private static let maxConcurrentChunks = 3

    /// Fetches an estimated daily cost report for z.ai over `[since, until]`.
    ///
    /// `cacheRoot` enables a 30-minute on-disk cache of the raw per-model payloads so a refresh
    /// storm (or repeated cold-launch hydrations) doesn't re-issue the same week-long chunked
    /// requests. Pricing is always recomputed from current rates at view time, so changes to the
    /// built-in GLM rate table apply on the next load without invalidating the network cache.
    public static func fetchDailyReport(
        apiKey: String,
        region: ZaiAPIRegion = .global,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        since: Date,
        until: Date,
        now: Date = Date(),
        cacheRoot: URL? = nil) async throws -> CostUsageDailyReport
    {
        guard !apiKey.isEmpty else {
            throw ZaiUsageError.invalidCredentials
        }

        let historyDays = max(1, Calendar.current.dateComponents([.day], from: since, to: until).day ?? 0)
        let cacheKey = ZaiCostUsageCacheStore.CacheKey(region: region, historyDays: historyDays)

        // Cache short-circuit: if we have fresh raw payloads for the same region+window, reprice
        // them with the current rates and return immediately.
        if let cacheRoot,
           let cached = ZaiCostUsageCacheStore.load(key: cacheKey, now: now, fileURL: cacheFile(cacheRoot: cacheRoot))
        {
            Self.log.debug("z.ai cost cache hit (region=\(region.rawValue), days=\(historyDays))")
            return Self.buildDailyReport(from: cached.collected, now: now)
        }

        let chunks = Self.dateChunks(from: since, to: until, daySpan: Self.chunkDaySpan)
        let collected: [ZaiModelUsageData]

        if chunks.count <= 1 {
            // Single chunk: no need for a TaskGroup.
            var single: [ZaiModelUsageData] = []
            for chunk in chunks {
                if let result = try? await Self.fetchChunk(
                    apiKey: apiKey,
                    region: region,
                    environment: environment,
                    chunk: chunk)
                {
                    single.append(result)
                }
            }
            collected = single
        } else {
            // Concurrent fetches bounded by `maxConcurrentChunks`. A single failed chunk is
            // logged and skipped — partial windows still produce a useful estimate.
            collected = try await Self.concurrentChunkedFetch(
                apiKey: apiKey,
                region: region,
                environment: environment,
                chunks: chunks)
        }

        if let cacheRoot {
            ZaiCostUsageCacheStore.store(
                collected: collected,
                key: cacheKey,
                since: since,
                until: until,
                now: now,
                fileURL: self.cacheFile(cacheRoot: cacheRoot))
        }

        return Self.buildDailyReport(from: collected, now: now)
    }

    private static func concurrentChunkedFetch(
        apiKey: String,
        region: ZaiAPIRegion,
        environment: [String: String],
        chunks: [(start: Date, end: Date)]) async throws -> [ZaiModelUsageData]
    {
        // Bounded-concurrency draining: process up to `maxConcurrentChunks` chunks at a time so a
        // 30-day window (≈5 chunks) doesn't spawn 5 simultaneous requests.
        var collected: [ZaiModelUsageData] = []
        collected.reserveCapacity(chunks.count)
        var index = 0
        while index < chunks.count {
            let batch = chunks[index..<min(index + Self.maxConcurrentChunks, chunks.count)]
            let batchResults = try await withThrowingTaskGroup(of: ZaiModelUsageData?
                .self)
            { group -> [ZaiModelUsageData] in
                for chunk in batch {
                    group.addTask(priority: .utility) {
                        try? await Self.fetchChunk(
                            apiKey: apiKey,
                            region: region,
                            environment: environment,
                            chunk: chunk)
                    }
                }
                var results: [ZaiModelUsageData] = []
                for try await result in group {
                    if let result { results.append(result) }
                }
                return results
            }
            collected.append(contentsOf: batchResults)
            index += batch.count
        }
        return collected
    }

    private static func fetchChunk(
        apiKey: String,
        region: ZaiAPIRegion,
        environment: [String: String],
        chunk: (start: Date, end: Date)) async throws -> ZaiModelUsageData
    {
        do {
            return try await ZaiUsageFetcher.fetchModelUsageRange(
                apiKey: apiKey,
                region: region,
                environment: environment,
                since: chunk.start,
                until: chunk.end)
        } catch {
            // A single failed chunk should not void the whole estimate; log and rethrow so the
            // caller can collapse this slot via `try?`.
            self.log.info("z.ai cost chunk failed (non-fatal): \(error.localizedDescription)")
            throw error
        }
    }

    private static func cacheFile(cacheRoot: URL) -> URL {
        // Reuse the canonical filename from ZaiCostUsageCacheStore.defaultURL when the caller
        // passes the standard Caches/CodexBar/cost-usage/ root; otherwise append the filename so
        // test overrides don't accidentally share with the production file.
        let defaultURL = ZaiCostUsageCacheStore.defaultURL()
        if cacheRoot.standardizedFileURL.path == defaultURL.deletingLastPathComponent().standardizedFileURL.path {
            return defaultURL
        }
        return cacheRoot.appendingPathComponent("zai-model-usage-v1.json", isDirectory: false)
    }

    /// Pure aggregation: hourly per-model token counts → priced daily report.
    ///
    /// Extracted from `fetchDailyReport` so it can be unit-tested with fixtures without network.
    /// `modelsDevCacheRoot` is forwarded to the pricer so tests can force built-in rates with an
    /// empty directory; production passes nil to use the shared models.dev cache.
    public static func buildDailyReport(
        from modelUsages: [ZaiModelUsageData],
        now: Date = Date(),
        modelsDevCacheRoot: URL? = nil) -> CostUsageDailyReport
    {
        var days: [String: [String: Int]] = [:]
        for modelUsage in modelUsages {
            for (index, timeString) in modelUsage.xTime.enumerated() {
                guard let hourDate = ZaiHourlyBars.parseHourDate(timeString) else { continue }
                let dayKey = Self.dayKey(for: hourDate)
                for item in modelUsage.modelDataList {
                    guard index < item.tokensUsage.count,
                          let tokenCount = item.tokensUsage[index], tokenCount > 0
                    else { continue }
                    let modelName = item.modelName ?? "Unknown"
                    days[dayKey, default: [:]][modelName, default: 0] += tokenCount
                }
            }
        }

        let entries = days.keys.sorted().map { dayKey -> CostUsageDailyReport.Entry in
            Self.entry(forDay: dayKey, modelTokens: days[dayKey] ?? [:], modelsDevCacheRoot: modelsDevCacheRoot)
        }

        let summary = CostUsageDailyReport.Summary(
            totalInputTokens: nil,
            totalOutputTokens: nil,
            cacheReadTokens: nil,
            cacheCreationTokens: nil,
            totalTokens: entries.compactMap(\.totalTokens).reduce(0, +),
            totalCostUSD: entries.compactMap(\.costUSD).reduce(0, +))
        return CostUsageDailyReport(data: entries, summary: summary)
    }

    /// Builds a single priced day entry from per-model token counts.
    private static func entry(
        forDay dayKey: String,
        modelTokens: [String: Int],
        modelsDevCacheRoot: URL? = nil) -> CostUsageDailyReport.Entry
    {
        let breakdowns: [CostUsageDailyReport.ModelBreakdown] = modelTokens
            .map { modelName, tokens in
                let cost = CostUsagePricing.zaiCostUSD(
                    model: modelName,
                    totalTokens: tokens,
                    modelsDevCacheRoot: modelsDevCacheRoot)
                return CostUsageDailyReport.ModelBreakdown(
                    modelName: modelName,
                    costUSD: cost,
                    totalTokens: tokens)
            }
            .sorted { lhs, rhs in
                let lhsCost = lhs.costUSD ?? -1
                let rhsCost = rhs.costUSD ?? -1
                if lhsCost != rhsCost { return lhsCost > rhsCost }
                let lhsTokens = lhs.totalTokens ?? -1
                let rhsTokens = rhs.totalTokens ?? -1
                return lhsTokens > rhsTokens
            }

        let dayTotalTokens = modelTokens.values.reduce(0, +)
        // Only count cost for priced models; unpriced models contribute tokens but not dollars.
        let dayCost = breakdowns.compactMap(\.costUSD).reduce(0, +)
        let modelsUsed = Array(modelTokens.keys).sorted()

        return CostUsageDailyReport.Entry(
            date: dayKey,
            inputTokens: nil,
            outputTokens: nil,
            cacheReadTokens: nil,
            cacheCreationTokens: nil,
            totalTokens: dayTotalTokens,
            requestCount: nil,
            costUSD: dayCost,
            modelsUsed: modelsUsed,
            modelBreakdowns: breakdowns)
    }

    private static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Splits `[from, to]` into non-overlapping windows of at most `daySpan` days.
    static func dateChunks(from: Date, to: Date, daySpan: Int) -> [(start: Date, end: Date)] {
        guard to > from, daySpan > 0 else { return [] }
        var chunks: [(start: Date, end: Date)] = []
        let calendar = Calendar.current
        var cursor = from
        while cursor < to {
            let next = calendar.date(byAdding: .day, value: daySpan, to: cursor) ?? to
            let end = min(next, to)
            chunks.append((start: cursor, end: end))
            cursor = end
        }
        return chunks
    }
}
