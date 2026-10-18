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
        var events: [EventKey: MidasUsageSyncEvent] = [:]
        events.reserveCapacity(min(
            max(previous?.events.count ?? 0, fresh.events.count), MidasUsageSyncPublication.maximumRecords))
        for event in [previous?.events ?? [], fresh.events].joined() {
            let key = EventKey(event)
            if let old = events[key], !Self.prefers(event, over: old) { continue }
            events[key] = event
        }
        var accounts: [AccountKey: MidasUsageSyncAccountDay] = [:]
        for row in [previous?.accountDays ?? [], fresh.accountDays].joined() {
            let key = AccountKey(row)
            if let old = accounts[key], !Self.prefers(row, over: old) { continue }
            accounts[key] = row
        }
        let cutoff = MidasUsageSyncPublication.day(fresh.publishedAt.addingTimeInterval(-364 * 86400))
        var retainedEvents = events.values.filter { $0.day >= cutoff }
        retainedEvents.sort {
            $0.day == $1.day ? Self.eventPrecedes($0, $1) : $0.day > $1.day
        }
        var retainedAccounts = accounts.values.filter { $0.day >= cutoff }
        retainedAccounts.sort {
            $0.day == $1.day ? $0.accountScope < $1.accountScope : $0.day > $1.day
        }
        let encoder = JSONEncoder()
        var bytes = 4096 // Reserve the header and array punctuation before checking the whole publication.
        var keptAccounts: [MidasUsageSyncAccountDay] = []
        var keptEvents: [MidasUsageSyncEvent] = []
        keptAccounts.reserveCapacity(min(retainedAccounts.count, MidasUsageSyncPublication.maximumRecords))
        for row in retainedAccounts {
            guard keptAccounts.count < MidasUsageSyncPublication.maximumRecords else { continue }
            let encodedBytes = autoreleasepool { try? encoder.encode(row).count }
            guard let encodedBytes,
                  bytes + encodedBytes + 1 <= MidasUsageSyncPublication.maximumFileBytes else { continue }
            keptAccounts.append(row)
            bytes += encodedBytes + 1
        }
        keptEvents.reserveCapacity(min(
            retainedEvents.count, MidasUsageSyncPublication.maximumRecords - keptAccounts.count))
        for row in retainedEvents {
            guard keptAccounts.count + keptEvents.count < MidasUsageSyncPublication.maximumRecords else { continue }
            let encodedBytes = autoreleasepool { try? encoder.encode(row).count }
            guard let encodedBytes,
                  bytes + encodedBytes + 1 <= MidasUsageSyncPublication.maximumFileBytes else { continue }
            keptEvents.append(row)
            bytes += encodedBytes + 1
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
        var events: [EventKey: MidasUsageSyncEvent] = [:]
        var accounts: [AccountKey: MidasUsageSyncAccountDay] = [:]
        for publication in self.publications {
            for event in publication.events {
                let key = EventKey(event)
                if let previous = events[key], !Self.prefers(event, over: previous) { continue }
                events[key] = event
            }
            for row in publication.accountDays {
                let key = AccountKey(row)
                if let previous = accounts[key], !Self.prefers(row, over: previous) { continue }
                accounts[key] = row
            }
        }
        // Keep only compact day/model totals after selecting each event. The previous implementation
        // retained another full copy of every value, then made many mapped/grouped arrays per field.
        var values: [UsageProvider: [String: DayTotals]] = [:]
        for event in events.values.sorted(by: Self.eventPrecedes) {
            values[event.provider, default: [:]][event.day, default: DayTotals()].add(event.values)
        }
        for row in accounts.values.sorted(by: Self.accountPrecedes) {
            values[row.provider, default: [:]][row.day, default: DayTotals()].add(row.values)
        }
        var providerUpdatedAt: [UsageProvider: Date] = [:]
        for publication in self.publications {
            var providers: Set<UsageProvider> = []
            for event in publication.events {
                providers.insert(event.provider)
            }
            for row in publication.accountDays {
                providers.insert(row.provider)
            }
            for provider in providers {
                providerUpdatedAt[provider] = max(providerUpdatedAt[provider] ?? .distantPast, publication.publishedAt)
            }
        }
        self.snapshots = Dictionary(uniqueKeysWithValues: values.map { provider, days in
            (provider, Self.snapshot(
                provider: provider, days: days, updatedAt: providerUpdatedAt[provider] ?? now, now: now))
        })
    }

    private struct EventKey: Hashable {
        let provider: UsageProvider
        let id: String

        init(_ event: MidasUsageSyncEvent) {
            self.provider = event.provider
            self.id = event.id
        }
    }

    private struct AccountKey: Hashable {
        let provider: UsageProvider
        let scope: String
        let day: String

        init(_ row: MidasUsageSyncAccountDay) {
            self.provider = row.provider
            self.scope = row.accountScope
            self.day = row.day
        }
    }

    private static func eventPrecedes(_ lhs: MidasUsageSyncEvent, _ rhs: MidasUsageSyncEvent) -> Bool {
        lhs.provider == rhs.provider ? lhs.id < rhs.id : lhs.provider.rawValue < rhs.provider.rawValue
    }

    private static func accountPrecedes(_ lhs: MidasUsageSyncAccountDay, _ rhs: MidasUsageSyncAccountDay) -> Bool {
        if lhs.provider != rhs.provider { return lhs.provider.rawValue < rhs.provider.rawValue }
        return lhs.accountScope == rhs.accountScope ? lhs.day < rhs.day : lhs.accountScope < rhs.accountScope
    }

    /// Merge complete records, never independently maximize monetary and token fields.
    private static func prefers(_ lhs: MidasUsageSyncEvent, over rhs: MidasUsageSyncEvent) -> Bool {
        // Streaming/copy-prefix revisions are monotonic. A later scan of an old copied prefix cannot erase completion.
        if lhs.values.tokens != rhs.values.tokens {
            return (lhs.values.tokens ?? -1) > (rhs.values.tokens ?? -1)
        }
        if lhs.observedAt != rhs.observedAt { return lhs.observedAt > rhs.observedAt }
        guard lhs != rhs else { return false }
        return self.canonical(lhs) > self.canonical(rhs)
    }

    private static func prefers(_ lhs: MidasUsageSyncAccountDay, over rhs: MidasUsageSyncAccountDay) -> Bool {
        if lhs.observedAt != rhs.observedAt { return lhs.observedAt > rhs.observedAt }
        guard lhs != rhs else { return false }
        return self.canonical(lhs) > self.canonical(rhs)
    }

    private static func prefers(_ lhs: MidasUsageSyncPublication, over rhs: MidasUsageSyncPublication) -> Bool {
        if lhs.publishedAt != rhs.publishedAt { return lhs.publishedAt > rhs.publishedAt }
        guard lhs != rhs else { return false }
        return self.canonical(lhs) > self.canonical(rhs)
    }

    private static func canonical(_ value: some Encodable) -> String {
        autoreleasepool {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }

    private static func snapshot(
        provider: UsageProvider, days: [String: DayTotals], updatedAt: Date, now: Date)
        -> CostUsageTokenSnapshot
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = MidasUsageSyncPublication.day(now)
        let start = calendar.date(byAdding: .day, value: -364, to: now) ?? now
        let firstDay = MidasUsageSyncPublication.day(start)
        let keys = days.keys.filter { $0 >= firstDay && $0 <= today }.sorted()
        let daily = keys.compactMap { day in days[day]?.entry(provider: provider, day: day) }
        let todayRows = daily.filter { $0.date == today }
        let provenance = self.provenance(keys.compactMap { days[$0]?.totals.provenance })
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

    private struct IntegerTotal {
        private var sum = 0
        private var hasValue = false
        private var valid = true

        var value: Int? {
            self.hasValue && self.valid ? self.sum : nil
        }

        mutating func add(_ value: Int?) {
            guard let value, self.valid else { return }
            let next = self.sum.addingReportingOverflow(value)
            self.valid = value >= 0 && !next.overflow
            self.sum = next.partialValue
            self.hasValue = true
        }
    }

    private struct DollarTotal {
        private var sum = 0.0
        private var hasValue = false
        private var valid = true

        var value: Double? {
            self.hasValue && self.valid ? self.sum : nil
        }

        mutating func add(_ value: Double?) {
            guard let value, self.valid else { return }
            self.sum += value
            self.valid = value.isFinite && value >= 0 && self.sum.isFinite
            self.hasValue = true
        }
    }

    private struct ValueTotals {
        var tokens = IntegerTotal()
        var requests = IntegerTotal()
        var input = IntegerTotal()
        var output = IntegerTotal()
        var cacheRead = IntegerTotal()
        var cacheCreation = IntegerTotal()
        var reasoning = IntegerTotal()
        var unpriced = IntegerTotal()
        var estimated = IntegerTotal()
        var cost = DollarTotal()
        var apiEquivalent = DollarTotal()
        var provenance = CostProvenance.unknown
        var completeLocalCache = true
        var completeLocalMix = true

        mutating func add(_ value: MidasUsageSyncValues) {
            self.tokens.add(value.tokens)
            self.requests.add(value.requests)
            self.input.add(value.tokenMix.inputTokens)
            self.output.add(value.tokenMix.outputTokens)
            self.cacheRead.add(value.tokenMix.cacheReadTokens)
            self.cacheCreation.add(value.tokenMix.cacheCreationTokens)
            self.reasoning.add(value.tokenMix.reasoningTokens)
            self.unpriced.add(max(value.unpricedRequests, value.costUSD == nil ? 1 : 0))
            self.estimated.add(value.estimatedRequests)
            self.cost.add(value.costUSD)
            self.apiEquivalent.add(value.apiEquivalentCostUSD)
            if value.provenance != .unknown {
                if self.provenance == .unknown {
                    self.provenance = value.provenance
                } else if self.provenance != value.provenance {
                    self.provenance = .mixed
                }
            }
            if let input = value.tokenMix.inputTokens, let cached = value.tokenMix.cacheReadTokens, cached <= input {
                if let output = value.tokenMix.outputTokens, let total = value.tokens {
                    let sum = input.addingReportingOverflow(output)
                    self.completeLocalMix = self.completeLocalMix && !sum.overflow && sum.partialValue == total
                } else {
                    self.completeLocalMix = false
                }
            } else {
                self.completeLocalCache = false
                self.completeLocalMix = false
            }
        }

        func model(_ name: String, provider: UsageProvider) -> CostUsageDailyReport.ModelBreakdown {
            CostUsageDailyReport.ModelBreakdown(
                modelName: name,
                costUSD: self.cost.value,
                totalTokens: self.tokens.value,
                requestCount: self.requests.value,
                inputTokens: self.input.value,
                outputTokens: self.output.value,
                cacheReadTokens: provider != .localInference || self.completeLocalMix ? self.cacheRead.value : nil,
                cacheCreationTokens: self.cacheCreation.value,
                reasoningTokens: self.reasoning.value)
        }
    }

    private struct DayTotals {
        var totals = ValueTotals()
        var models: [String: ValueTotals] = [:]

        mutating func add(_ value: MidasUsageSyncValues) {
            self.totals.add(value)
            if let model = value.model { self.models[model, default: ValueTotals()].add(value) }
        }

        func entry(provider: UsageProvider, day: String) -> CostUsageDailyReport.Entry {
            let names = self.models.keys.sorted()
            let breakdowns = names.compactMap { self.models[$0]?.model($0, provider: provider) }
            return CostUsageDailyReport.Entry(
                date: day,
                inputTokens: self.totals.input.value,
                outputTokens: self.totals.output.value,
                cacheReadTokens: provider != .localInference || self.totals.completeLocalCache
                    ? self.totals.cacheRead.value : nil,
                cacheCreationTokens: self.totals.cacheCreation.value,
                reasoningTokens: self.totals.reasoning.value,
                totalTokens: self.totals.tokens.value,
                requestCount: self.totals.requests.value,
                costUSD: self.totals.cost.value,
                apiEquivalentCostUSD: self.totals.apiEquivalent.value,
                modelsUsed: names.isEmpty ? nil : names,
                modelBreakdowns: breakdowns.isEmpty ? nil : breakdowns,
                unpricedRequestCount: self.totals.unpriced.value,
                estimatedRequestCount: self.totals.estimated.value)
        }
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
