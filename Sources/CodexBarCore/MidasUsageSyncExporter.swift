import Foundation

/// Exports only numeric local usage after the user opts into a shared workspace.
/// Account quotas are not device events: they must never be summed by this exporter.
public enum MidasUsageSyncExporter {
    public struct Options: Sendable {
        public var codexSessionsRoot: URL?
        public var codexAdditionalSessionsRoots: [URL]
        public var claudeProjectsRoots: [URL]?
        public var metaSessionsRoot: URL?
        public var cacheRoot: URL?
        public var codexTraceDatabaseURL: URL?
        public var historyDays: Int
        public var forceRescan: Bool
        /// Leave room for provider-account history and publication metadata.
        var maximumEventBytes = MidasUsageSyncPublication.maximumFileBytes - 4 * 1024 * 1024

        public init(
            codexSessionsRoot: URL? = nil,
            codexAdditionalSessionsRoots: [URL] = [],
            claudeProjectsRoots: [URL]? = nil,
            metaSessionsRoot: URL? = nil,
            cacheRoot: URL? = nil,
            codexTraceDatabaseURL: URL? = nil,
            historyDays: Int = 365,
            forceRescan: Bool = false)
        {
            self.codexSessionsRoot = codexSessionsRoot
            self.codexAdditionalSessionsRoots = codexAdditionalSessionsRoots
            self.claudeProjectsRoots = claudeProjectsRoots
            self.metaSessionsRoot = metaSessionsRoot
            self.cacheRoot = cacheRoot
            self.codexTraceDatabaseURL = codexTraceDatabaseURL
            self.historyDays = historyDays
            self.forceRescan = forceRescan
        }
    }

    public struct ExportResult: Sendable {
        public let events: [MidasUsageSyncEvent]
        /// Usage records with unsafe/missing identity, missing time, or outside the publication limit.
        public let excludedRecords: Int
    }

    public static func export(
        workspace: MidasUsageSyncWorkspace,
        providers: [UsageProvider] = [.codex, .claude, .meta],
        now: Date = Date(),
        options: Options = Options()) async throws -> ExportResult
    {
        try workspace.validate()
        let resolvedOptions = self.resolvingCacheRoot(options)
        if options.cacheRoot == nil, providers.contains(.codex) || providers.contains(.claude) {
            // Only live default exports refresh the public catalog. Explicit fixture and CLI roots stay isolated.
            await ModelsDevPricingPipeline.refreshIfNeeded(now: now, cacheRoot: resolvedOptions.cacheRoot)
            try Task.checkCancellation()
        }
        return try await CostUsageScanExecutor.run { checkCancellation in
            try self.exportSynchronously(
                workspace: workspace,
                providers: providers,
                now: now,
                options: resolvedOptions,
                checkCancellation: checkCancellation)
        }
    }

    /// Normal cost views retain a narrower history window. Sharing their cache would make each
    /// 365-day sync expand backward and reparse the corpus after an ordinary 30-day refresh.
    static func resolvingCacheRoot(
        _ options: Options,
        cachesDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]) -> Options
    {
        guard options.cacheRoot == nil else { return options }
        var resolved = options
        resolved.cacheRoot = cachesDirectory
            .appendingPathComponent(MidasIdentity.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("usage-sync-scan", isDirectory: true)
        return resolved
    }

    /// The scanner callback is Sendable; this lock protects its value-only cache snapshot.
    /// No mutable scanner state or file handles escape the serialized scan operation.
    private final class CacheSnapshot: @unchecked Sendable {
        private let lock = NSLock()
        private var cache = CostUsageCache()

        func store(_ cache: CostUsageCache) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.cache = cache
        }

        func load() -> CostUsageCache {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.cache
        }
    }

    private struct CodexEventKey: Hashable {
        let turn: String?
        let timestamp: String?
    }

    private struct Window {
        let since: Date
        let until: Date
    }

    private struct Accumulator {
        var events: [String: MidasUsageSyncEvent] = [:]
        var excludedRecords = 0
        let maximumBytes: Int
        private var bytes = 0
        private var sizes: [String: Int] = [:]
        private var heap: [String] = []
        private var positions: [String: Int] = [:]

        init(maximumBytes: Int) {
            self.maximumBytes = min(
                max(0, maximumBytes),
                MidasUsageSyncPublication.maximumFileBytes - 4 * 1024 * 1024)
        }

        mutating func add(_ event: MidasUsageSyncEvent) {
            guard (try? event.values.validate()) != nil,
                  let data = try? JSONEncoder().encode(event)
            else {
                self.excludedRecords += 1
                return
            }
            if let existing = self.events[event.id] {
                // Copied logs and streaming observations are selected, never summed.
                let moreComplete = (event.values.tokens ?? -1) > (existing.values.tokens ?? -1)
                let newer = event.values.tokens == existing.values.tokens && event.observedAt > existing.observedAt
                guard moreComplete || newer else { return }
                self.events[event.id] = event
                self.bytes += data.count + 1 - (self.sizes[event.id] ?? 0)
                self.sizes[event.id] = data.count + 1
                if let index = self.positions[event.id] {
                    self.siftUp(index)
                    self.siftDown(self.positions[event.id] ?? index)
                }
            } else {
                self.events[event.id] = event
                self.bytes += data.count + 1
                self.sizes[event.id] = data.count + 1
                self.positions[event.id] = self.heap.count
                self.heap.append(event.id)
                self.siftUp(self.heap.count - 1)
            }
            // Preserve the newest history when a large corpus reaches either cap.
            // Heap pruning bounds both memory and work, independent of provider/file scan order.
            while self.events.count > MidasUsageSyncPublication.maximumRecords - 4096
                || self.bytes > self.maximumBytes
            {
                self.removeOldest()
                self.excludedRecords += 1
            }
        }

        private func precedes(_ left: Int, _ right: Int) -> Bool {
            guard let lhs = self.events[self.heap[left]], let rhs = self.events[self.heap[right]] else { return false }
            if lhs.observedAt != rhs.observedAt { return lhs.observedAt < rhs.observedAt }
            return lhs.id < rhs.id
        }

        private mutating func swap(_ left: Int, _ right: Int) {
            self.heap.swapAt(left, right)
            self.positions[self.heap[left]] = left
            self.positions[self.heap[right]] = right
        }

        private mutating func siftUp(_ initial: Int) {
            var index = initial
            while index > 0 {
                let parent = (index - 1) / 2
                guard self.precedes(index, parent) else { return }
                self.swap(index, parent)
                index = parent
            }
        }

        private mutating func siftDown(_ initial: Int) {
            var index = initial
            while 2 * index + 1 < self.heap.count {
                var child = 2 * index + 1
                if child + 1 < self.heap.count, self.precedes(child + 1, child) { child += 1 }
                guard self.precedes(child, index) else { return }
                self.swap(index, child)
                index = child
            }
        }

        private mutating func removeOldest() {
            guard let first = self.heap.first else { return }
            if self.heap.count > 1 { self.swap(0, self.heap.count - 1) }
            self.heap.removeLast()
            self.positions.removeValue(forKey: first)
            self.events.removeValue(forKey: first)
            self.bytes -= self.sizes.removeValue(forKey: first) ?? 0
            if !self.heap.isEmpty { self.siftDown(0) }
        }
    }

    private static func exportSynchronously(
        workspace: MidasUsageSyncWorkspace,
        providers: [UsageProvider],
        now: Date,
        options: Options,
        checkCancellation: @escaping @Sendable () throws -> Void) throws -> ExportResult
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let days = min(max(options.historyDays, 1), 365)
        let since = calendar.date(
            byAdding: .day,
            value: 1 - days,
            to: calendar.startOfDay(for: now)) ?? now
        var output = Accumulator(maximumBytes: options.maximumEventBytes)
        for provider in Set(providers).sorted(by: { $0.rawValue < $1.rawValue }) {
            try checkCancellation()
            switch provider {
            case .codex, .claude:
                var scanOptions = CostUsageScanner.Options(
                    codexSessionsRoot: options.codexSessionsRoot,
                    claudeProjectsRoots: options.claudeProjectsRoots,
                    cacheRoot: options.cacheRoot,
                    codexTraceDatabaseURL: options.codexTraceDatabaseURL,
                    claudeLogProviderFilter: .excludeVertexAI,
                    forceRescan: options.forceRescan)
                scanOptions.codexAdditionalSessionsRoots = options.codexAdditionalSessionsRoots
                scanOptions.retainSyncRows = true
                scanOptions.refreshMinIntervalSeconds = 0
                let snapshot = CacheSnapshot()
                scanOptions.cacheSnapshot = { snapshot.store($0) }
                _ = try CostUsageScanner.loadDailyReportCancellable(
                    provider: provider,
                    since: since,
                    until: now,
                    now: now,
                    options: scanOptions,
                    checkCancellation: checkCancellation)
                let cache = snapshot.load()
                if provider == .codex {
                    self.appendCodex(
                        cache: cache,
                        workspace: workspace,
                        window: Window(
                            since: since,
                            until: now),
                        options: options,
                        output: &output)
                } else {
                    self.appendClaude(
                        cache: cache,
                        workspace: workspace,
                        window: Window(
                            since: since,
                            until: now),
                        options: options,
                        output: &output)
                }
            case .meta:
                try self.appendMeta(
                    root: options.metaSessionsRoot ?? MuseSessionLogScanner.defaultSessionsRoot(),
                    workspace: workspace,
                    window: Window(
                        since: since,
                        until: now),
                    checkCancellation: checkCancellation,
                    output: &output)
            default:
                break
            }
        }
        return ExportResult(
            events: output.events.values.sorted { $0.id < $1.id },
            excludedRecords: output.excludedRecords)
    }

    private static func appendCodex(
        cache: CostUsageCache,
        workspace: MidasUsageSyncWorkspace,
        window: Window,
        options: Options,
        output: inout Accumulator)
    {
        let catalog = CostUsagePricing.modelsDevCatalog(
            now: window.until,
            cacheRoot: options.cacheRoot)
        let range = CostUsageScanner.CostUsageDayRange(
            since: window.since,
            until: window.until)
        let priority = CostUsageScanner.codexPriorityTurns(
            databaseURL: options.codexTraceDatabaseURL,
            sinceDayKey: range.scanSinceKey,
            untilDayKey: range.scanUntilKey)
        for path in cache.files.keys.sorted() {
            guard let file = cache.files[path] else { continue }
            output.excludedRecords += file.syncExcludedRecords ?? 0
            let rows = file.codexSyncRows ?? []
            let counts = Dictionary(grouping: rows) { CodexEventKey(turn: $0.turnID, timestamp: $0.timestamp) }
                .mapValues(\.count)
            for row in rows {
                guard row.unsafeNumericSource != true else { continue }
                guard let timestamp = row.timestamp,
                      let at = CostUsageScanner.dateFromTimestamp(timestamp)
                else {
                    output.excludedRecords += 1
                    continue
                }
                guard at >= window.since, at <= window.until else { continue }
                guard let session = self.nonempty(file.sessionId), let turn = self.nonempty(row.turnID) else {
                    output.excludedRecords += 1
                    continue
                }
                guard counts[CodexEventKey(turn: turn, timestamp: timestamp)] == 1 else {
                    output.excludedRecords += 1
                    continue
                }
                let cost = CostUsageScanner.codexRowCostBreakdown(
                    rows: [row],
                    priorityTurns: priority,
                    modelsDevCatalog: catalog,
                    modelsDevCacheRoot: options.cacheRoot).totalCostUSD
                let values = MidasUsageSyncValues(
                    tokens: self.sum([row.input, row.output]),
                    requests: nil,
                    costUSD: cost,
                    tokenMix: CostUsageTokenMix(
                        inputTokens: row.input,
                        outputTokens: row.output,
                        cacheReadTokens: row.cached),
                    provenance: cost == nil ? .unknown : .listPriceEstimate,
                    model: cost == nil ? nil : self.publicModel(row.model),
                    unpricedRequests: cost == nil ? 1 : 0,
                    estimatedRequests: cost == nil ? 0 : 1)
                output.add(MidasUsageSyncEvent(
                    id: workspace.opaqueID(
                        provider: .codex,
                        components: [session, turn, timestamp]),
                    provider: .codex,
                    day: MidasUsageSyncPublication.day(at),
                    observedAt: at,
                    values: values))
            }
        }
    }

    private static func appendClaude(
        cache: CostUsageCache,
        workspace: MidasUsageSyncWorkspace,
        window: Window,
        options: Options,
        output: inout Accumulator)
    {
        let catalog = CostUsagePricing.modelsDevCatalog(
            now: window.until,
            cacheRoot: options.cacheRoot)
        output.excludedRecords += cache.files.values.reduce(0) { $0 + ($1.syncExcludedRecords ?? 0) }
        for row in CostUsageScanner.reconciledClaudeRows(cache: cache) {
            guard let milliseconds = row.timestampUnixMs else {
                output.excludedRecords += 1
                continue
            }
            let at = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
            guard at >= window.since, at <= window.until else { continue }
            guard let message = self.nonempty(row.messageId), let request = self.nonempty(row.requestId) else {
                output.excludedRecords += 1
                continue
            }
            let currentCost = CostUsagePricing.claudeCostUSD(
                model: row.model,
                inputTokens: row.input,
                cacheReadInputTokens: row.cacheRead,
                cacheCreationInputTokens: row.cacheCreate,
                cacheCreationInputTokens1h: row.cacheCreate1h ?? 0,
                outputTokens: row.output,
                speed: row.speed,
                inferenceGeo: row.inferenceGeo,
                webSearchRequests: row.webSearchRequests ?? 0,
                pricingDate: at,
                modelsDevCatalog: catalog,
                modelsDevCacheRoot: options.cacheRoot)
            let wasPriced = row.costPriced ?? (row.costNanos > 0)
            let cost: Double? = if wasPriced, row.costNanos == 0 {
                0
            } else if let currentCost {
                currentCost
            } else if wasPriced {
                Double(row.costNanos) / CostUsageScanner.costScale
            } else {
                nil
            }
            output.add(MidasUsageSyncEvent(
                id: workspace.opaqueID(
                    provider: .claude,
                    components: [message, request]),
                provider: .claude,
                day: MidasUsageSyncPublication.day(at),
                observedAt: at,
                values: MidasUsageSyncValues(
                    tokens: self.sum([row.input, row.cacheRead, row.cacheCreate, row.output]),
                    requests: 1,
                    costUSD: cost,
                    tokenMix: CostUsageTokenMix(
                        inputTokens: row.input,
                        outputTokens: row.output,
                        cacheReadTokens: row.cacheRead,
                        cacheCreationTokens: row.cacheCreate),
                    provenance: cost == nil ? .unknown : .listPriceEstimate,
                    model: cost == nil ? nil : self.publicModel(row.model),
                    unpricedRequests: cost == nil ? 1 : 0,
                    estimatedRequests: cost == nil ? 0 : 1)))
        }
    }

    private static func appendMeta(
        root: URL,
        workspace: MidasUsageSyncWorkspace,
        window: Window,
        checkCancellation: @escaping @Sendable () throws -> Void,
        output: inout Accumulator) throws
    {
        let files = MuseSessionLogScanner.listSessionFiles(
            root: root,
            since: window.since).sorted { $0.path < $1.path }
        if files.count >= MuseSessionLogScanner.maxFilesPerScan { output.excludedRecords += 1 }
        for file in files {
            try checkCancellation()
            _ = try CostUsageJsonl.scan(
                fileURL: file,
                offset: 0,
                maxLineBytes: MuseSessionLogScanner.maxLineBytes,
                prefixBytes: MuseSessionLogScanner.maxLineBytes,
                checkCancellation: checkCancellation,
                onLine: { line in
                    guard !line.wasTruncated, String(data: line.bytes, encoding: .utf8) != nil else {
                        output.excludedRecords += 1
                        return
                    }
                    // Most transcript lines have no usage. Keep Unicode-escaped JSON as candidates too,
                    // including escaped record_json children, so this optimization never drops valid counters.
                    guard line.bytes.containsAscii("model_completed") || line.bytes.containsAscii("\\u") else { return }
                    let parsed = MuseSessionLogScanner.parseResponsesForSync(fromData: line.bytes)
                    output.excludedRecords = CostUsageScanner.boundedAdd(output.excludedRecords, parsed.excludedRecords)
                    for response in parsed.responses {
                        guard response.hasRecordedTimestamp, let identity = response.sourceIDComponents else {
                            output.excludedRecords += 1
                            continue
                        }
                        guard response.at >= window.since, response.at <= window.until else { continue }
                        output.add(MidasUsageSyncEvent(
                            id: workspace.opaqueID(
                                provider: .meta,
                                components: identity),
                            provider: .meta,
                            day: MidasUsageSyncPublication.day(response.at),
                            observedAt: response.at,
                            values: self.metaValues(response)))
                    }
                })
        }
    }

    private static func metaValues(_ response: MetaCompletedResponse) -> MidasUsageSyncValues {
        let usage = response.usage
        let tier = response.model.flatMap { CostUsagePricing.metaPricingTier(forModel: $0) }
        let cost = tier.map {
            CostUsagePricing.metaCost(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                reasoningTokens: usage.reasoningTokens,
                cacheReadTokens: usage.cachedTokens,
                tier: $0)
        }
        let apiEquivalent = tier.map { _ in
            CostUsagePricing.metaCost(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                reasoningTokens: usage.reasoningTokens,
                cacheReadTokens: usage.cachedTokens,
                tier: .standard)
        }
        return MidasUsageSyncValues(
            tokens: self.sum([usage.inputTokens, usage.outputTokens, usage.reasoningTokens]),
            requests: usage.requests,
            costUSD: cost,
            apiEquivalentCostUSD: apiEquivalent,
            tokenMix: CostUsageTokenMix(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cacheReadTokens: usage.cachedTokens,
                reasoningTokens: usage.reasoningTokens),
            provenance: cost == nil ? .unknown : .listPriceEstimate,
            model: self.publicModel(response.model),
            unpricedRequests: cost == nil ? usage.requests : 0,
            estimatedRequests: cost == nil ? 0 : usage.requests)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// Unrecognized model text is omitted instead of transmitting arbitrary local strings.
    private static func publicModel(_ value: String?) -> String? {
        let pattern = #"^(gpt-[0-9][a-z0-9.\-]*|o[1-9][a-z0-9.\-]*|"#
            + #"claude-[a-z0-9.\-]+|muse-spark-[0-9.]+(?:-contributor)?)$"#
        guard let value, value.utf8.count <= 160,
              value.range(
                  of: pattern,
                  options: .regularExpression) != nil
        else { return nil }
        return value
    }

    private static func sum(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            guard value >= 0 else { return nil }
            let next = total.addingReportingOverflow(value)
            guard !next.overflow else { return nil }
            total = next.partialValue
        }
        return total
    }
}
