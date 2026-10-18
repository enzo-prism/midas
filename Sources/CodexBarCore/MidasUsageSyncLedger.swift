import Foundation

/// Deterministic union of local activity and provider-account reports. It never adds quota percentages.
public struct MidasUsageSyncLedger: Sendable {
    public let publications: [MidasUsageSyncPublication]
    public let snapshots: [UsageProvider: CostUsageTokenSnapshot]
    public let excludedRecords: Int

    /// Retain this Mac's older numeric history when source logs roll off or an offline publication must retry.
    public static func retainingLocalHistory(
        previous: MidasUsageSyncPublication?, fresh: MidasUsageSyncPublication) -> MidasUsageSyncPublication
    {
        let previous = previous.flatMap {
            $0.workspaceID == fresh.workspaceID && $0.deviceID == fresh.deviceID ? $0 : nil
        }
        var events: [String: MidasUsageSyncEvent] = [:]
        for event in (previous?.events ?? []) + fresh.events {
            let key = event.provider.rawValue + ":" + event.id
            if let old = events[key], !Self.prefers(event, over: old) { continue }
            events[key] = event
        }
        var accounts: [String: MidasUsageSyncAccountDay] = [:]
        for row in (previous?.accountDays ?? []) + fresh.accountDays {
            let key = row.provider.rawValue + ":" + row.accountScope + ":" + row.day
            if let old = accounts[key], !Self.prefers(row, over: old) { continue }
            accounts[key] = row
        }
        let cutoff = MidasUsageSyncPublication.day(fresh.publishedAt.addingTimeInterval(-364 * 86400))
        let retainedEvents = events.values.filter { $0.day >= cutoff }.sorted {
            $0.day == $1.day ? $0.provider.rawValue + $0.id < $1.provider.rawValue + $1.id : $0.day > $1.day
        }
        let retainedAccounts = accounts.values.filter { $0.day >= cutoff }.sorted {
            $0.day == $1.day ? $0.accountScope < $1.accountScope : $0.day > $1.day
        }
        let encoder = JSONEncoder()
        var bytes = 4096 // Reserve the header and array punctuation before checking the whole publication.
        var keptAccounts: [MidasUsageSyncAccountDay] = []
        var keptEvents: [MidasUsageSyncEvent] = []
        for row in retainedAccounts {
            guard keptAccounts.count < MidasUsageSyncPublication.maximumRecords,
                  let encoded = try? encoder.encode(row),
                  bytes + encoded.count + 1 <= MidasUsageSyncPublication.maximumFileBytes else { continue }
            keptAccounts.append(row)
            bytes += encoded.count + 1
        }
        for row in retainedEvents {
            guard keptAccounts.count + keptEvents.count < MidasUsageSyncPublication.maximumRecords,
                  let encoded = try? encoder.encode(row),
                  bytes + encoded.count + 1 <= MidasUsageSyncPublication.maximumFileBytes else { continue }
            keptEvents.append(row)
            bytes += encoded.count + 1
        }
        let dropped = retainedEvents.count - keptEvents.count + retainedAccounts.count - keptAccounts.count
        return MidasUsageSyncPublication(
            workspaceID: fresh.workspaceID,
            deviceID: fresh.deviceID,
            deviceName: fresh.deviceName,
            publishedAt: fresh.publishedAt,
            events: keptEvents,
            accountDays: keptAccounts,
            excludedRecords: fresh.excludedRecords.addingReportingOverflow(dropped).overflow
                ? Int.max : fresh.excludedRecords + dropped)
    }

    public init(publications: [MidasUsageSyncPublication], workspaceID: UUID, now: Date = Date()) throws {
        // The coordinator reconciles up to 128 cached + 128 received + one local revision.
        guard publications.count <= 257 else { throw MidasUsageSyncError.limitExceeded }
        var devices: [UUID: MidasUsageSyncPublication] = [:]
        for publication in publications {
            try publication.validate(workspaceID: workspaceID, now: now)
            if let previous = devices[publication.deviceID], !Self.prefers(publication, over: previous) { continue }
            devices[publication.deviceID] = publication
        }
        self.publications = devices.values.sorted { $0.deviceID.uuidString < $1.deviceID.uuidString }
        guard self.publications.count <= 128 else { throw MidasUsageSyncError.limitExceeded }
        let recordCount = self.publications.reduce(0) { $0 + $1.events.count + $1.accountDays.count }
        guard recordCount <= 250_000 else { throw MidasUsageSyncError.limitExceeded }
        self.excludedRecords = Self.sumIntegers(self.publications.map(\.excludedRecords)) ?? Int.max
        var events: [String: MidasUsageSyncEvent] = [:]
        var accounts: [String: MidasUsageSyncAccountDay] = [:]
        for publication in self.publications {
            for event in publication.events {
                let key = event.provider.rawValue + ":" + event.id
                if let previous = events[key], !Self.prefers(event, over: previous) { continue }
                events[key] = event
            }
            for row in publication.accountDays {
                let key = row.provider.rawValue + ":" + row.accountScope + ":" + row.day
                if let previous = accounts[key], !Self.prefers(row, over: previous) { continue }
                accounts[key] = row
            }
        }
        var values: [UsageProvider: [String: [MidasUsageSyncValues]]] = [:]
        for key in events.keys.sorted() {
            guard let event = events[key] else { continue }
            values[event.provider, default: [:]][event.day, default: []].append(event.values)
        }
        for key in accounts.keys.sorted() {
            guard let row = accounts[key] else { continue }
            values[row.provider, default: [:]][row.day, default: []].append(row.values)
        }
        var providerUpdatedAt: [UsageProvider: Date] = [:]
        for publication in self.publications {
            let providers = Set(publication.events.map(\.provider) + publication.accountDays.map(\.provider))
            for provider in providers {
                providerUpdatedAt[provider] = max(providerUpdatedAt[provider] ?? .distantPast, publication.publishedAt)
            }
        }
        self.snapshots = Dictionary(uniqueKeysWithValues: values.map { provider, days in
            (provider, Self.snapshot(
                provider: provider, days: days, updatedAt: providerUpdatedAt[provider] ?? now, now: now))
        })
    }

    /// Merge complete records, never independently maximize monetary and token fields.
    private static func prefers(_ lhs: MidasUsageSyncEvent, over rhs: MidasUsageSyncEvent) -> Bool {
        // Streaming/copy-prefix revisions are monotonic. A later scan of an old copied prefix cannot erase completion.
        if lhs.values.tokens != rhs.values.tokens {
            return (lhs.values.tokens ?? -1) > (rhs.values.tokens ?? -1)
        }
        if lhs.observedAt != rhs.observedAt { return lhs.observedAt > rhs.observedAt }
        return self.canonical(lhs) > self.canonical(rhs)
    }

    private static func prefers(_ lhs: MidasUsageSyncAccountDay, over rhs: MidasUsageSyncAccountDay) -> Bool {
        if lhs.observedAt != rhs.observedAt { return lhs.observedAt > rhs.observedAt }
        return self.canonical(lhs) > self.canonical(rhs)
    }

    private static func prefers(_ lhs: MidasUsageSyncPublication, over rhs: MidasUsageSyncPublication) -> Bool {
        if lhs.publishedAt != rhs.publishedAt { return lhs.publishedAt > rhs.publishedAt }
        return self.canonical(lhs) > self.canonical(rhs)
    }

    private static func canonical(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private static func snapshot(
        provider: UsageProvider, days: [String: [MidasUsageSyncValues]], updatedAt: Date, now: Date)
        -> CostUsageTokenSnapshot
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = MidasUsageSyncPublication.day(now)
        let start = calendar.date(byAdding: .day, value: -364, to: now) ?? now
        let firstDay = MidasUsageSyncPublication.day(start)
        let keys = days.keys.filter { $0 >= firstDay && $0 <= today }.sorted()
        let daily = keys.map { self.entry(provider: provider, day: $0, values: days[$0] ?? []) }
        let todayRows = daily.filter { $0.date == today }
        let provenance = self.provenance(keys.flatMap { days[$0] ?? [] }.map(\.provenance))
        let totalCost = self.sumDoubles(daily.map(\.costUSD))
        return CostUsageTokenSnapshot(
            sessionTokens: self.sumIntegers(todayRows.map(\.totalTokens)),
            sessionCostUSD: self.sumDoubles(todayRows.map(\.costUSD)),
            sessionRequests: self.sumIntegers(todayRows.map(\.requestCount)),
            last30DaysTokens: self.sumIntegers(daily.map(\.totalTokens)),
            last30DaysCostUSD: totalCost,
            last30DaysAPIEquivalentCostUSD: self.sumDoubles(daily.map(\.apiEquivalentCostUSD)),
            last30DaysRequests: self.sumIntegers(daily.map(\.requestCount)),
            historyDays: 365,
            historyLabel: "Across devices · 12 months",
            meteredCostUSD: provenance == .vendorMetered ? totalCost : nil,
            costProvenance: provenance,
            daily: daily,
            updatedAt: updatedAt)
    }

    private static func entry(
        provider: UsageProvider, day: String, values: [MidasUsageSyncValues]) -> CostUsageDailyReport.Entry
    {
        let models = Dictionary(grouping: values.compactMap { value -> (String, MidasUsageSyncValues)? in
            value.model.map { ($0, value) }
        }, by: { $0.0 })
        let breakdowns = models.keys.sorted().map { model in
            let rows = (models[model] ?? []).map(\.1)
            let completeLocalMix = provider != .localInference || rows.allSatisfy { value in
                guard let input = value.tokenMix.inputTokens, let output = value.tokenMix.outputTokens,
                      let cached = value.tokenMix.cacheReadTokens, let total = value.tokens,
                      cached <= input else { return false }
                let sum = input.addingReportingOverflow(output)
                return !sum.overflow && sum.partialValue == total
            }
            return CostUsageDailyReport.ModelBreakdown(
                modelName: model,
                costUSD: self.sumDoubles(rows.map(\.costUSD)),
                totalTokens: self.sumIntegers(rows.map(\.tokens)),
                requestCount: self.sumIntegers(rows.map(\.requests)),
                inputTokens: self.sumIntegers(rows.map(\.tokenMix.inputTokens)),
                outputTokens: self.sumIntegers(rows.map(\.tokenMix.outputTokens)),
                // A cached-input subtotal cannot establish the missing mix of another local model record.
                cacheReadTokens: completeLocalMix ? self.sumIntegers(rows.map(\.tokenMix.cacheReadTokens)) : nil,
                cacheCreationTokens: self.sumIntegers(rows.map(\.tokenMix.cacheCreationTokens)),
                reasoningTokens: self.sumIntegers(rows.map(\.tokenMix.reasoningTokens)))
        }
        let completeLocalCache = provider != .localInference || values.allSatisfy { value in
            guard let input = value.tokenMix.inputTokens, let cached = value.tokenMix.cacheReadTokens else {
                return false
            }
            return cached <= input
        }
        return CostUsageDailyReport.Entry(
            date: day,
            inputTokens: self.sumIntegers(values.map(\.tokenMix.inputTokens)),
            outputTokens: self.sumIntegers(values.map(\.tokenMix.outputTokens)),
            cacheReadTokens: completeLocalCache ? self.sumIntegers(values.map(\.tokenMix.cacheReadTokens)) : nil,
            cacheCreationTokens: self.sumIntegers(values.map(\.tokenMix.cacheCreationTokens)),
            reasoningTokens: self.sumIntegers(values.map(\.tokenMix.reasoningTokens)),
            totalTokens: self.sumIntegers(values.map(\.tokens)),
            requestCount: self.sumIntegers(values.map(\.requests)),
            costUSD: self.sumDoubles(values.map(\.costUSD)),
            apiEquivalentCostUSD: self.sumDoubles(values.map(\.apiEquivalentCostUSD)),
            modelsUsed: models.isEmpty ? nil : models.keys.sorted(),
            modelBreakdowns: breakdowns.isEmpty ? nil : breakdowns,
            unpricedRequestCount: self.sumIntegers(values.map { value in
                max(value.unpricedRequests, value.costUSD == nil ? 1 : 0)
            }),
            estimatedRequestCount: self.sumIntegers(values.map(\.estimatedRequests)))
    }

    private static func provenance(_ values: [CostProvenance]) -> CostProvenance {
        let known = Set(values.filter { $0 != .unknown }.map(\.rawValue))
        guard let first = known.first else { return .unknown }
        return known.count == 1 ? CostProvenance(rawValue: first) ?? .unknown : .mixed
    }

    static func sumIntegers(_ values: [Int?]) -> Int? {
        var result = 0
        var hasValue = false
        for value in values {
            guard let value else { continue }
            let next = result.addingReportingOverflow(value)
            guard value >= 0, !next.overflow else { return nil }
            result = next.partialValue
            hasValue = true
        }
        return hasValue ? result : nil
    }

    static func sumDoubles(_ values: [Double?]) -> Double? {
        var result = 0.0
        var hasValue = false
        for value in values {
            guard let value else { continue }
            result += value
            guard value.isFinite, value >= 0, result.isFinite else { return nil }
            hasValue = true
        }
        return hasValue ? result : nil
    }
}
