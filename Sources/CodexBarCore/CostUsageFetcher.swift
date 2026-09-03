import Foundation

public enum CostUsageError: LocalizedError, Sendable {
    case unsupportedProvider(UsageProvider)
    case sourceDisabled(UsageProvider)
    case timedOut(seconds: Int)
    case cursorPaginationIncomplete(expected: Int?, received: Int)
    case cursorPaginationInconsistent(expected: Int, received: Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedProvider(provider):
            return "Cost summary is not supported for \(provider.rawValue)."
        case let .sourceDisabled(provider):
            return "Cost summary source is disabled for \(provider.rawValue). Enable it in Settings."
        case let .cursorPaginationIncomplete(expected, received):
            if let expected {
                return "Cursor cost refresh was incomplete (received \(received) of \(expected) events)."
            }
            return "Cursor cost refresh reached its pagination safety limit after \(received) events."
        case let .cursorPaginationInconsistent(expected, received):
            return "Cursor cost pagination was inconsistent (expected \(expected), received \(received) events)."
        case let .timedOut(seconds):
            if seconds >= 60, seconds % 60 == 0 {
                return "Cost refresh timed out after \(seconds / 60)m."
            }
            return "Cost refresh timed out after \(seconds)s."
        }
    }
}

public struct CostUsageFetcher: Sendable {
    private let scannerOptions: CostUsageScanner.Options?

    public init(cacheRoot: URL? = nil) {
        self.scannerOptions = cacheRoot.map { CostUsageScanner.Options(cacheRoot: $0) }
    }

    init(scannerOptions: CostUsageScanner.Options) {
        self.scannerOptions = scannerOptions
    }

    public func loadCachedCodexTokenSnapshot(
        now: Date = Date(),
        codexHomePath: String? = nil,
        historyDays: Int = 30) async -> CostUsageTokenSnapshot?
    {
        await Self.loadCachedCodexTokenSnapshot(
            now: now,
            codexHomePath: codexHomePath,
            historyDays: historyDays,
            scannerOptions: self.scannerOptionsOverride())
    }

    public func loadTokenSnapshot(
        provider: UsageProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        forceRefresh: Bool = false,
        allowVertexClaudeFallback: Bool = false,
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        refreshPricingInBackground: Bool = true,
        zaiAPIRegion: ZaiAPIRegion? = nil,
        cursorSettings: ProviderSettingsSnapshot.CursorProviderSettings? = nil) async throws -> CostUsageTokenSnapshot
    {
        try await Self.loadTokenSnapshot(
            provider: provider,
            environment: environment,
            now: now,
            forceRefresh: forceRefresh,
            allowVertexClaudeFallback: allowVertexClaudeFallback,
            codexHomePath: codexHomePath,
            historyDays: historyDays,
            refreshPricingInBackground: refreshPricingInBackground,
            zaiAPIRegion: zaiAPIRegion,
            cursorSettings: cursorSettings,
            scannerOptions: self.scannerOptionsOverride())
    }

    @available(*, deprecated, message: "Codex token-cost scans are uncapped; this limit is ignored.")
    public func loadTokenSnapshot(
        provider: UsageProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        forceRefresh: Bool = false,
        allowVertexClaudeFallback: Bool = false,
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        refreshPricingInBackground: Bool = true,
        automaticCodexScanByteLimit _: Int64?,
        zaiAPIRegion: ZaiAPIRegion? = nil,
        cursorSettings: ProviderSettingsSnapshot.CursorProviderSettings? = nil) async throws -> CostUsageTokenSnapshot
    {
        try await self.loadTokenSnapshot(
            provider: provider,
            environment: environment,
            now: now,
            forceRefresh: forceRefresh,
            allowVertexClaudeFallback: allowVertexClaudeFallback,
            codexHomePath: codexHomePath,
            historyDays: historyDays,
            refreshPricingInBackground: refreshPricingInBackground,
            zaiAPIRegion: zaiAPIRegion,
            cursorSettings: cursorSettings)
    }

    private func scannerOptionsOverride() -> CostUsageScanner.Options? {
        self.scannerOptions
    }

    static func loadTokenSnapshot(
        provider: UsageProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        forceRefresh: Bool = false,
        allowVertexClaudeFallback: Bool = false,
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        refreshPricingInBackground: Bool = true,
        zaiAPIRegion: ZaiAPIRegion? = nil,
        cursorSettings: ProviderSettingsSnapshot.CursorProviderSettings? = nil,
        scannerOptions overrideScannerOptions: CostUsageScanner.Options? = nil,
        piScannerOptions overridePiScannerOptions: PiSessionCostScanner
            .Options? = nil) async throws -> CostUsageTokenSnapshot
    {
        guard provider == .codex || provider == .claude || provider == .vertexai || provider == .bedrock || provider ==
            .zai || provider == .meta || provider == .openai || provider == .cursor
        else {
            throw CostUsageError.unsupportedProvider(provider)
        }

        let until = now
        let clampedHistoryDays = max(1, min(365, historyDays))
        // Rolling window is inclusive, so a 30-day display starts 29 days before `now`.
        let since = Calendar.current.date(byAdding: .day, value: -(clampedHistoryDays - 1), to: now) ?? now

        if provider == .bedrock {
            let daily = try await Self.loadBedrockDailyReport(
                environment: environment,
                since: since,
                until: until)
            return Self.tokenSnapshot(from: daily, now: now, historyDays: clampedHistoryDays)
        }

        if provider == .openai {
            return try await Self.loadOpenAIDailyReport(
                environment: environment,
                now: now,
                historyDays: clampedHistoryDays)
        }

        if provider == .cursor {
            return try await Self.loadCursorTokenSnapshot(
                cursorSettings: cursorSettings,
                now: now,
                historyDays: clampedHistoryDays)
        }

        if provider == .zai {
            let zaiCacheRoot = (overrideScannerOptions ?? CostUsageScanner.Options()).cacheRoot
            return try await Self.loadZaiDailyReport(
                environment: environment,
                apiRegion: zaiAPIRegion,
                since: since,
                until: until,
                now: now,
                historyDays: clampedHistoryDays,
                cacheRoot: zaiCacheRoot)
        }

        if provider == .meta {
            return try await CostUsageScanExecutor.run { _ in
                let summary = MuseSessionLogScanner.loadSummary(since: since, until: until, now: now)
                let daily = Self.metaDailyReport(from: summary)
                var snapshot = Self.tokenSnapshot(from: daily, now: now, historyDays: clampedHistoryDays)
                let apiEquivalent = daily.data.compactMap(\.apiEquivalentCostUSD).reduce(0, +)
                snapshot = CostUsageTokenSnapshot(
                    sessionTokens: snapshot.sessionTokens,
                    sessionCostUSD: snapshot.sessionCostUSD,
                    sessionRequests: snapshot.sessionRequests,
                    last30DaysTokens: snapshot.last30DaysTokens,
                    last30DaysCostUSD: snapshot.last30DaysCostUSD,
                    last30DaysAPIEquivalentCostUSD: apiEquivalent > 0 ? apiEquivalent : nil,
                    last30DaysRequests: snapshot.last30DaysRequests,
                    currencyCode: snapshot.currencyCode,
                    historyDays: snapshot.historyDays,
                    historyLabel: "Last \(clampedHistoryDays) days (local Muse log)",
                    daily: snapshot.daily,
                    updatedAt: snapshot.updatedAt)
                return snapshot
            }
        }

        var options = overrideScannerOptions ?? CostUsageScanner.Options()
        if provider == .codex,
           let codexHomePath = codexHomePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHomePath.isEmpty
        {
            options.codexSessionsRoot = URL(fileURLWithPath: codexHomePath, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }
        if provider == .codex || provider == .claude {
            let pricingCacheRoot = options.cacheRoot
            if refreshPricingInBackground {
                Task.detached(priority: .utility) {
                    await ModelsDevPricingPipeline.refreshIfNeeded(now: now, cacheRoot: pricingCacheRoot)
                }
            } else {
                await ModelsDevPricingPipeline.refreshIfNeeded(now: now, cacheRoot: pricingCacheRoot)
            }
        }

        if provider == .vertexai {
            options.claudeLogProviderFilter = allowVertexClaudeFallback ? .all : .vertexAIOnly
        } else if provider == .claude {
            options.claudeLogProviderFilter = .excludeVertexAI
        }
        if forceRefresh {
            options.refreshMinIntervalSeconds = 0
        }
        var resolvedPiOptions = overridePiScannerOptions ?? PiSessionCostScanner.Options()
        if resolvedPiOptions.cacheRoot == nil {
            resolvedPiOptions.cacheRoot = options.cacheRoot
        }
        if forceRefresh {
            resolvedPiOptions.refreshMinIntervalSeconds = 0
        }
        let piOptions = resolvedPiOptions

        try Task.checkCancellation()
        // The corpus scans below are synchronous and can run for minutes on large session
        // archives. They execute on the dedicated scan queue so they never occupy a cooperative
        // pool thread; CostUsageScanExecutor bridges this task's cancellation into the
        // scanner-level checks.
        let scanOptions = options
        let daily = try await CostUsageScanExecutor.run { checkCancellation in
            var daily = try CostUsageScanner.loadDailyReportCancellable(
                provider: provider,
                since: since,
                until: until,
                now: now,
                options: scanOptions,
                checkCancellation: checkCancellation)
            try checkCancellation()

            if provider == .vertexai,
               !allowVertexClaudeFallback,
               scanOptions.claudeLogProviderFilter == .vertexAIOnly,
               daily.data.isEmpty
            {
                var fallback = scanOptions
                fallback.claudeLogProviderFilter = .all
                daily = try CostUsageScanner.loadDailyReportCancellable(
                    provider: provider,
                    since: since,
                    until: until,
                    now: now,
                    options: fallback,
                    checkCancellation: checkCancellation)
                try checkCancellation()
            }

            if provider == .codex || provider == .claude {
                let piReport = try PiSessionCostScanner.loadDailyReportCancellable(
                    provider: provider,
                    since: since,
                    until: until,
                    now: now,
                    options: piOptions,
                    checkCancellation: checkCancellation)
                try checkCancellation()
                daily = CostUsageDailyReport.merged([daily, piReport])
            }
            return daily
        }

        return Self.tokenSnapshot(from: daily, now: now, historyDays: clampedHistoryDays)
    }

    static func loadCachedCodexTokenSnapshot(
        now: Date = Date(),
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        scannerOptions overrideScannerOptions: CostUsageScanner.Options? = nil) async -> CostUsageTokenSnapshot?
    {
        if let codexHomePath = codexHomePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHomePath.isEmpty
        {
            return nil
        }

        // Decoding the persisted scan cache parses multi-megabyte JSON; keep it off the
        // cooperative pool alongside the scans themselves.
        let cachedSnapshot: CostUsageTokenSnapshot?? = try? await CostUsageScanExecutor.run { _ in
            let clampedHistoryDays = max(1, min(365, historyDays))
            let until = now
            let since = Calendar.current.date(byAdding: .day, value: -(clampedHistoryDays - 1), to: now) ?? now
            let range = CostUsageScanner.CostUsageDayRange(since: since, until: until)
            let options = overrideScannerOptions ?? CostUsageScanner.Options()
            let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: options.cacheRoot)
            var reports: [CostUsageDailyReport] = []

            if !cache.days.isEmpty,
               cache.roots == CostUsageScanner.codexRootsFingerprint(options: options),
               !CostUsageScanner.requestedWindowExpandsCache(range: range, cache: cache)
            {
                let daily = CostUsageScanner.buildCodexReportFromCache(
                    cache: cache,
                    range: range,
                    modelsDevCacheRoot: options.cacheRoot)
                if !daily.data.isEmpty {
                    reports.append(daily)
                }
            }

            if let piDaily = PiSessionCostScanner.loadCachedDailyReport(
                provider: .codex,
                since: since,
                until: until,
                now: now,
                cacheRoot: options.cacheRoot)
            {
                reports.append(piDaily)
            }

            guard !reports.isEmpty else { return nil }
            return Self.tokenSnapshot(
                from: CostUsageDailyReport.merged(reports),
                now: now,
                historyDays: clampedHistoryDays)
        }
        return cachedSnapshot.flatMap(\.self)
    }

    /// Daily token report built from local Muse session logs. Each priced day carries
    /// `costUSD` at its Meta tier (contributor when every model is a contributor build,
    /// otherwise standard) and `apiEquivalentCostUSD` at standard Meta Model API rates,
    /// so menu/CLI can show both what contributor usage costs and its API equivalent.
    /// Days with mixed or unknown model mixes stay unpriced rather than misattributed.
    public static func metaDailyReport(from summary: MetaUsageSummary) -> CostUsageDailyReport {
        let entries = summary.daily.map { day in
            let tier = CostUsagePricing.metaPricingTier(forModels: day.modelsUsed)
            let costUSD = tier.map {
                CostUsagePricing.metaCost(
                    inputTokens: day.usage.inputTokens,
                    outputTokens: day.usage.outputTokens,
                    reasoningTokens: day.usage.reasoningTokens,
                    cacheReadTokens: day.usage.cachedTokens,
                    tier: $0)
            }
            let apiEquivalentCostUSD = tier.map { _ in
                CostUsagePricing.metaCost(
                    inputTokens: day.usage.inputTokens,
                    outputTokens: day.usage.outputTokens,
                    reasoningTokens: day.usage.reasoningTokens,
                    cacheReadTokens: day.usage.cachedTokens,
                    tier: .standard)
            }
            return CostUsageDailyReport.Entry(
                date: day.dayKey,
                inputTokens: day.usage.inputTokens,
                outputTokens: day.usage.outputTokens,
                cacheReadTokens: day.usage.cachedTokens > 0 ? day.usage.cachedTokens : nil,
                cacheCreationTokens: nil,
                totalTokens: day.usage.totalTokens,
                requestCount: day.usage.requests,
                costUSD: costUSD,
                apiEquivalentCostUSD: apiEquivalentCostUSD,
                modelsUsed: day.modelsUsed.isEmpty ? nil : day.modelsUsed,
                modelBreakdowns: nil)
        }
        return CostUsageDailyReport(data: entries, summary: nil)
    }

    /// List-price 30-day USD for the global rollup: Meta uses the standard-API
    /// equivalent (not contributor pricing); every other provider uses its snapshot
    /// cost, which is already priced at public API rates (or a labeled estimate).
    public static func listPriceCostUSD(provider: UsageProvider, snapshot: CostUsageTokenSnapshot) -> Double? {
        if provider == .meta {
            return snapshot.last30DaysAPIEquivalentCostUSD ?? snapshot.last30DaysCostUSD
        }
        return snapshot.last30DaysCostUSD
    }

    /// OpenAI cost report from the Admin API organization spend endpoints (real billed
    /// costs, not an estimate). Requires `OPENAI_ADMIN_KEY`/`OPENAI_API_KEY` or a key in
    /// Settings; otherwise throws `OpenAIAPISettingsError.missingToken`.
    private static func loadOpenAIDailyReport(
        environment: [String: String],
        now: Date,
        historyDays: Int) async throws -> CostUsageTokenSnapshot
    {
        guard let credential = OpenAIAPIUsageCredential(environment: environment) else {
            throw OpenAIAPISettingsError.missingToken
        }
        let usage = try await OpenAIAPIUsageFetcher.fetchUsage(
            apiKey: credential.apiKey,
            projectID: credential.projectID,
            historyDays: historyDays)
        var snapshot = usage.toCostUsageTokenSnapshot()
        snapshot = CostUsageTokenSnapshot(
            sessionTokens: snapshot.sessionTokens,
            sessionCostUSD: snapshot.sessionCostUSD,
            sessionRequests: snapshot.sessionRequests,
            last30DaysTokens: snapshot.last30DaysTokens,
            last30DaysCostUSD: snapshot.last30DaysCostUSD,
            last30DaysRequests: snapshot.last30DaysRequests,
            currencyCode: snapshot.currencyCode,
            historyDays: snapshot.historyDays,
            historyLabel: "Last \(historyDays) days (OpenAI Admin API)",
            daily: snapshot.daily,
            updatedAt: snapshot.updatedAt)
        return snapshot
    }

    /// Snap a Cursor window start to the local day boundary so the dashboard query keeps full days.
    /// `since` arrives as the current instant N-1 days back, so a 1-day window would otherwise become
    /// an empty exact-instant range; snapping to 00:00 keeps all of today (and the first day's early
    /// hours for wider windows).
    static func cursorWindowStart(_ since: Date?, calendar: Calendar = .current) -> Date? {
        since.map { calendar.startOfDay(for: $0) }
    }

    /// Fetch Cursor's per-day token-cost plus its Cursor-metered total via the cookie-authenticated
    /// dashboard API, reusing the same session resolution as the Cursor status probe. Like Codex and
    /// Claude, the report covers the rolling `historyDays` window.
    private static func loadCursorTokenSnapshot(
        cursorSettings: ProviderSettingsSnapshot.CursorProviderSettings?,
        now: Date,
        historyDays: Int) async throws -> CostUsageTokenSnapshot
    {
        guard cursorSettings?.cookieSource != .off else {
            throw CostUsageError.sourceDisabled(.cursor)
        }
        let manual: String? = if cursorSettings?.cookieSource == .manual {
            CookieHeaderNormalizer.normalize(cursorSettings?.manualCookieHeader)
        } else {
            nil
        }
        #if os(macOS)
        // `since` arrives as the current instant N-1 days back; snap it to the local day boundary so
        // the dashboard query keeps the full first day (and all of today for a 1-day window) instead
        // of filtering out earlier events at the same time-of-day.
        let since = Calendar.current.date(byAdding: .day, value: -(historyDays - 1), to: now) ?? now
        let probe = CursorStatusProbe(browserDetection: BrowserDetection())
        let report = try await probe.fetchCostReport(
            since: Self.cursorWindowStart(since),
            until: now,
            cookieHeaderOverride: manual)
        return Self.tokenSnapshot(
            from: report.daily,
            now: now,
            historyDays: historyDays,
            meteredCostUSD: report.meteredCostUSD,
            costProvenance: Self.cursorCostProvenance(
                meteredCostUSD: report.meteredCostUSD,
                daily: report.daily.data))
        #else
        let probe = CursorStatusProbe(browserDetection: BrowserDetection())
        let snapshot = try await probe.fetch(cookieHeaderOverride: manual)
        let daily = Self.cursorDailyReport(from: snapshot, now: now)
        var tokenSnapshot = Self.tokenSnapshot(from: daily, now: now, historyDays: historyDays)
        tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: tokenSnapshot.sessionTokens,
            sessionCostUSD: tokenSnapshot.sessionCostUSD,
            sessionRequests: tokenSnapshot.sessionRequests,
            last30DaysTokens: tokenSnapshot.last30DaysTokens,
            last30DaysCostUSD: tokenSnapshot.last30DaysCostUSD,
            last30DaysRequests: tokenSnapshot.last30DaysRequests,
            currencyCode: tokenSnapshot.currencyCode,
            historyDays: tokenSnapshot.historyDays,
            historyLabel: "Current billing cycle (Cursor web session)",
            daily: tokenSnapshot.daily,
            updatedAt: tokenSnapshot.updatedAt)
        return tokenSnapshot
        #endif
    }

    static func cursorCostProvenance(
        meteredCostUSD: Double?,
        daily: [CostUsageDailyReport.Entry]) -> CostProvenance
    {
        let hasDailyCosts = daily.contains { $0.costUSD != nil }
        if meteredCostUSD != nil, hasDailyCosts {
            return .mixed
        }
        if meteredCostUSD != nil {
            return .vendorMetered
        }
        if hasDailyCosts {
            return .listPriceEstimate
        }
        return .unknown
    }

    /// Single-entry cycle report from a Cursor status snapshot.
    public static func cursorDailyReport(
        from snapshot: CursorStatusSnapshot,
        now: Date = Date(),
        calendar: Calendar = Calendar.current) -> CostUsageDailyReport
    {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var breakdowns: [CostUsageDailyReport.ModelBreakdown] = [
            CostUsageDailyReport.ModelBreakdown(
                modelName: "Plan",
                costUSD: snapshot.planUsedUSD,
                totalTokens: nil,
                requestCount: nil),
            CostUsageDailyReport.ModelBreakdown(
                modelName: "On-demand",
                costUSD: snapshot.onDemandUsedUSD,
                totalTokens: nil,
                requestCount: nil),
        ]
        if snapshot.botUsedUSD > 0 || snapshot.botLimitUSD != nil {
            breakdowns.append(CostUsageDailyReport.ModelBreakdown(
                modelName: "Bot",
                costUSD: snapshot.botUsedUSD,
                totalTokens: nil,
                requestCount: nil))
        }
        let total = snapshot.planUsedUSD + snapshot.onDemandUsedUSD + snapshot.botUsedUSD
        let entry = CostUsageDailyReport.Entry(
            date: formatter.string(from: now),
            inputTokens: nil,
            outputTokens: nil,
            cacheReadTokens: nil,
            cacheCreationTokens: nil,
            totalTokens: nil,
            requestCount: snapshot.requestsUsed,
            costUSD: total,
            modelsUsed: nil,
            modelBreakdowns: breakdowns)
        return CostUsageDailyReport(data: [entry], summary: nil)
    }

    private static func loadBedrockDailyReport(
        environment: [String: String],
        since: Date,
        until: Date) async throws -> CostUsageDailyReport
    {
        let resolved = try await BedrockCredentialResolver.resolve(environment: environment)
        return try await BedrockUsageFetcher.fetchDailyReport(
            credentials: resolved.credentials,
            since: since,
            until: until,
            environment: environment)
    }

    /// Estimated z.ai cost report. z.ai has no spend API, so this pulls per-model token counts from
    /// the `model-usage` monitoring endpoint and prices them with blended GLM rates. The snapshot's
    /// `historyLabel` marks it as an estimate.
    ///
    /// `apiRegion` lets callers forward the in-app region picker selection (Preferences →
    /// Providers → z.ai → API region). When nil, the region is inferred from `Z_AI_API_HOST`
    /// containing "bigmodel" to preserve legacy behavior.
    private static func loadZaiDailyReport(
        environment: [String: String],
        apiRegion: ZaiAPIRegion?,
        since: Date,
        until: Date,
        now: Date,
        historyDays: Int,
        cacheRoot: URL? = nil) async throws -> CostUsageTokenSnapshot
    {
        guard let apiKey = ProviderTokenResolver.zaiToken(environment: environment), !apiKey.isEmpty else {
            throw ZaiSettingsError.missingToken
        }
        // Prefer the in-app picker region when supplied; otherwise fall back to the env-only
        // heuristic (host contains "bigmodel"). Previously the cost path always used the env
        // heuristic, which silently mismatched users who selected BigModel CN in Preferences but
        // didn't set Z_AI_API_HOST.
        let region: ZaiAPIRegion = apiRegion ?? {
            if let host = ZaiSettingsReader.apiHost(environment: environment)?.lowercased(),
               host.contains("bigmodel")
            {
                return .bigmodelCN
            }
            return .global
        }()

        // Warm the shared models.dev cache in the background so subsequent refreshes can use the
        // real `zai` provider rates instead of the built-in fallbacks. This is fire-and-forget; the
        // current fetch falls back to built-ins if the cache is cold.
        Task.detached(priority: .utility) {
            await ModelsDevPricingPipeline.refreshIfNeeded(now: now, cacheRoot: nil)
        }

        let daily = try await ZaiCostUsageFetcher.fetchDailyReport(
            apiKey: apiKey,
            region: region,
            environment: environment,
            since: since,
            until: until,
            now: now,
            cacheRoot: cacheRoot)

        var snapshot = Self.tokenSnapshot(from: daily, now: now, historyDays: historyDays)
        // Re-label as an estimate so the menu card / chart is honest about the data source.
        // Mention the region for the CN variant because that's billed in CNY (the estimate uses
        // USD-equivalent pricing; the label flags the mismatch).
        let regionSuffix = region == .bigmodelCN ? ", BigModel CN" : ""
        snapshot = CostUsageTokenSnapshot(
            sessionTokens: snapshot.sessionTokens,
            sessionCostUSD: snapshot.sessionCostUSD,
            sessionRequests: snapshot.sessionRequests,
            last30DaysTokens: snapshot.last30DaysTokens,
            last30DaysCostUSD: snapshot.last30DaysCostUSD,
            last30DaysRequests: snapshot.last30DaysRequests,
            currencyCode: snapshot.currencyCode,
            historyDays: snapshot.historyDays,
            historyLabel: "Last \(historyDays) days (est.\(regionSuffix))",
            daily: snapshot.daily,
            updatedAt: snapshot.updatedAt)
        return snapshot
    }

    static func tokenSnapshot(
        from daily: CostUsageDailyReport,
        now: Date,
        historyDays: Int = 30,
        meteredCostUSD: Double? = nil,
        costProvenance: CostProvenance = .unknown) -> CostUsageTokenSnapshot
    {
        // Pick the most recent day; break ties by cost/tokens to keep a stable "session" row.
        let currentDay = daily.data.max { lhs, rhs in
            let lDate = CostUsageDateParser.parse(lhs.date) ?? .distantPast
            let rDate = CostUsageDateParser.parse(rhs.date) ?? .distantPast
            if lDate != rDate { return lDate < rDate }
            let lCost = lhs.costUSD ?? -1
            let rCost = rhs.costUSD ?? -1
            if lCost != rCost { return lCost < rCost }
            let lTokens = lhs.totalTokens ?? -1
            let rTokens = rhs.totalTokens ?? -1
            if lTokens != rTokens { return lTokens < rTokens }
            return lhs.date < rhs.date
        }
        // Prefer summary totals when present; fall back to summing daily entries.
        let totalFromSummary = daily.summary?.totalCostUSD
        let totalFromEntries = daily.data.compactMap(\.costUSD).reduce(0, +)
        let last30DaysCostUSD = totalFromSummary ?? (totalFromEntries > 0 ? totalFromEntries : nil)
        let totalTokensFromSummary = daily.summary?.totalTokens
        let totalTokensFromEntries = daily.data.compactMap(\.totalTokens).reduce(0, +)
        let last30DaysTokens = totalTokensFromSummary ?? (totalTokensFromEntries > 0 ? totalTokensFromEntries : nil)

        return CostUsageTokenSnapshot(
            sessionTokens: currentDay?.totalTokens,
            sessionCostUSD: currentDay?.costUSD,
            last30DaysTokens: last30DaysTokens,
            last30DaysCostUSD: last30DaysCostUSD,
            historyDays: historyDays,
            meteredCostUSD: meteredCostUSD,
            costProvenance: costProvenance,
            daily: daily.data,
            updatedAt: now)
    }

    static func selectCurrentSession(from sessions: [CostUsageSessionReport.Entry])
        -> CostUsageSessionReport.Entry?
    {
        if sessions.isEmpty { return nil }
        return sessions.max { lhs, rhs in
            let lDate = CostUsageDateParser.parse(lhs.lastActivity) ?? .distantPast
            let rDate = CostUsageDateParser.parse(rhs.lastActivity) ?? .distantPast
            if lDate != rDate { return lDate < rDate }
            let lCost = lhs.costUSD ?? -1
            let rCost = rhs.costUSD ?? -1
            if lCost != rCost { return lCost < rCost }
            let lTokens = lhs.totalTokens ?? -1
            let rTokens = rhs.totalTokens ?? -1
            if lTokens != rTokens { return lTokens < rTokens }
            return lhs.session < rhs.session
        }
    }

    static func selectMostRecentMonth(from months: [CostUsageMonthlyReport.Entry])
        -> CostUsageMonthlyReport.Entry?
    {
        if months.isEmpty { return nil }
        return months.max { lhs, rhs in
            let lDate = CostUsageDateParser.parseMonth(lhs.month) ?? .distantPast
            let rDate = CostUsageDateParser.parseMonth(rhs.month) ?? .distantPast
            if lDate != rDate { return lDate < rDate }
            let lCost = lhs.costUSD ?? -1
            let rCost = rhs.costUSD ?? -1
            if lCost != rCost { return lCost < rCost }
            let lTokens = lhs.totalTokens ?? -1
            let rTokens = rhs.totalTokens ?? -1
            if lTokens != rTokens { return lTokens < rTokens }
            return lhs.month < rhs.month
        }
    }
}
