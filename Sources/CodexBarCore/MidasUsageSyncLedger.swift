import Foundation

/// Deterministic union of local activity and provider-account reports. It never adds quota percentages.
public struct MidasUsageSyncLedger: Sendable {
    public let publications: [MidasUsageSyncPublication]
    public let snapshots: [UsageProvider: CostUsageTokenSnapshot]
    public let excludedRecords: Int

    /// Retain this Mac's older numeric history when source logs roll off or an offline publication must retry.
    /// Days that no longer fit the publication as individual events are published as this device's day rollups.
    public static func retainingLocalHistory(
        previous: MidasUsageSyncPublication?,
        fresh: MidasUsageSyncPublication,
        maximumBytes: Int = MidasUsageSyncPublication.maximumFileBytes) -> MidasUsageSyncPublication
    {
        let previous = previous.flatMap {
            $0.workspaceID == fresh.workspaceID && $0.deviceID == fresh.deviceID ? $0 : nil
        }
        let deviceID = fresh.deviceID
        let cutoff = MidasUsageSyncPublication.day(fresh.publishedAt.addingTimeInterval(-364 * 86400))
        var events: [EventKey: MidasUsageSyncEvent] = [:]
        events.reserveCapacity(min(
            max(previous?.events.count ?? 0, fresh.events.count), MidasUsageSyncPublication.maximumRecords))
        var previousRollups: [MidasUsageSyncRollup.DayKey: [MidasUsageSyncEvent]] = [:]
        var freshRollups: [MidasUsageSyncRollup.DayKey: [MidasUsageSyncEvent]] = [:]
        for (isFresh, source) in [
            (false, previous.map(Self.canonicalDisplayEvents) ?? []),
            (true, Self.canonicalDisplayEvents(fresh)),
        ] {
            for event in source where event.day >= cutoff {
                if MidasUsageSyncRollup.isRollup(event, deviceID: deviceID) {
                    let key = MidasUsageSyncRollup.DayKey(event)
                    if isFresh { freshRollups[key, default: []].append(event) } else {
                        previousRollups[key, default: []].append(event)
                    }
                    continue
                }
                let key = EventKey(event)
                if let old = events[key], !Self.prefers(event, over: old) { continue }
                events[key] = event
            }
        }
        var fineDays: [MidasUsageSyncRollup.DayKey: [MidasUsageSyncEvent]] = [:]
        for event in events.values {
            fineDays[MidasUsageSyncRollup.DayKey(event), default: []].append(event)
        }
        // A rolled-up provider day stays rolled up. Choose its most complete whole version, never a sum of versions.
        var rolled: [MidasUsageSyncRollup.DayKey: [MidasUsageSyncEvent]] = [:]
        for key in Set(previousRollups.keys).union(freshRollups.keys) {
            let candidates = [
                freshRollups[key],
                fineDays.removeValue(forKey: key).map { MidasUsageSyncRollup.rollUp($0, deviceID: deviceID) },
                previousRollups[key],
            ].compactMap(\.self)
            rolled[key] = candidates.max { Self.tokenTotal($0) < Self.tokenTotal($1) }
        }

        var accounts: [AccountKey: MidasUsageSyncAccountDay] = [:]
        for row in [previous?.accountDays ?? [], fresh.accountDays].joined() {
            let key = AccountKey(row)
            if let old = accounts[key], !Self.prefers(row, over: old) { continue }
            accounts[key] = row
        }
        var retainedAccounts = accounts.values.filter { $0.day >= cutoff }
        retainedAccounts.sort {
            $0.day == $1.day ? $0.accountScope < $1.accountScope : $0.day > $1.day
        }
        let encoder = JSONEncoder()
        let encodedSize: (MidasUsageSyncEvent) -> Int? = { event in
            autoreleasepool { try? encoder.encode(event).count + 1 }
        }
        var bytes = 4096 // Reserve the header and array punctuation before checking the whole publication.
        var keptAccounts: [MidasUsageSyncAccountDay] = []
        keptAccounts.reserveCapacity(min(retainedAccounts.count, MidasUsageSyncPublication.maximumRecords))
        for row in retainedAccounts {
            guard keptAccounts.count < MidasUsageSyncPublication.maximumRecords else { continue }
            let encodedBytes = autoreleasepool { try? encoder.encode(row).count }
            guard let encodedBytes,
                  bytes + encodedBytes + 1 <= maximumBytes else { continue }
            keptAccounts.append(row)
            bytes += encodedBytes + 1
        }

        // Newest days stay individual (cross-device copy detection) while they fit. Reserve room for
        // every remaining day's rollup first, so an older day is summarized rather than dropped.
        let days = Set(fineDays.keys.map(\.day)).sorted(by: >)
        var dayEvents: [String: [MidasUsageSyncEvent]] = [:]
        for (key, values) in fineDays {
            dayEvents[key.day, default: []] += values
        }
        var dayRollups: [String: [MidasUsageSyncEvent]] = [:]
        var reserve = 0
        for day in days {
            let rollups = MidasUsageSyncRollup.rollUp(dayEvents[day] ?? [], deviceID: deviceID)
            dayRollups[day] = rollups
            reserve += rollups.reduce(0) { $0 + (encodedSize($1) ?? 0) }
        }
        let rolledBytes = rolled.values.joined().reduce(0) { $0 + (encodedSize($1) ?? 0) }
        let rolledCount = rolled.values.reduce(0) { $0 + $1.count }
        var keptEvents: [MidasUsageSyncEvent] = []
        var keepingIndividualEvents = true
        for day in days {
            let individual = dayEvents[day] ?? []
            let rollups = dayRollups[day] ?? []
            reserve -= rollups.reduce(0) { $0 + (encodedSize($1) ?? 0) }
            if keepingIndividualEvents {
                let size = individual.reduce(0) { $0 + (encodedSize($1) ?? 0) }
                let count = keptAccounts.count + keptEvents.count + individual.count + rolledCount
                    + dayRollups.values.reduce(0) { $0 + $1.count } - rollups.count
                if count <= MidasUsageSyncPublication.maximumRecords,
                   bytes + size + reserve + rolledBytes <= maximumBytes
                {
                    keptEvents += individual
                    bytes += size
                    dayRollups[day] = []
                    continue
                }
                keepingIndividualEvents = false
            }
            for event in rollups {
                rolled[MidasUsageSyncRollup.DayKey(event), default: []].append(event)
            }
            dayRollups[day] = []
        }

        // Summaries are tiny; only a pathological history can still exceed the limits here.
        var summaries = Array(rolled.values.joined())
        summaries.sort { $0.day == $1.day ? Self.eventPrecedes($0, $1) : $0.day > $1.day }
        var dropped = 0
        for event in summaries {
            guard keptAccounts.count + keptEvents.count < MidasUsageSyncPublication.maximumRecords,
                  let size = encodedSize(event),
                  bytes + size <= maximumBytes
            else {
                dropped += 1
                continue
            }
            keptEvents.append(event)
            bytes += size
        }
        keptEvents.sort {
            $0.day == $1.day ? Self.eventPrecedes($0, $1) : $0.day > $1.day
        }
        dropped += retainedAccounts.count - keptAccounts.count
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

    /// The durable source of truth keeps identities. Absence in a later partial scan never deletes one.
    /// Legacy aggregates are retained alongside recovered constituents; display resolves their overlap conservatively.
    public static func retainingCanonicalHistory(
        previous: MidasUsageSyncPublication?,
        fresh: MidasUsageSyncPublication) throws -> MidasUsageSyncPublication
    {
        let previous = previous.flatMap {
            $0.workspaceID == fresh.workspaceID && $0.deviceID == fresh.deviceID ? $0 : nil
        }
        let validationDate = max(previous?.publishedAt ?? fresh.publishedAt, fresh.publishedAt)
        try fresh.validateCanonical(workspaceID: fresh.workspaceID, now: validationDate)
        if let previous { try previous.validateCanonical(workspaceID: fresh.workspaceID, now: validationDate) }
        var events: [EventKey: MidasUsageSyncEvent] = [:]
        for event in (previous?.events ?? []) + fresh.events {
            let key = EventKey(event)
            if let old = events[key], !Self.prefers(event, over: old) { continue }
            events[key] = event
        }
        var accounts: [AccountKey: MidasUsageSyncAccountDay] = [:]
        for row in (previous?.accountDays ?? []) + fresh.accountDays {
            let key = AccountKey(row)
            if let old = accounts[key], !Self.prefers(row, over: old) { continue }
            accounts[key] = row
        }
        let result = MidasUsageSyncPublication(
            workspaceID: fresh.workspaceID,
            deviceID: fresh.deviceID,
            deviceName: fresh.deviceName,
            publishedAt: max(previous?.publishedAt ?? fresh.publishedAt, fresh.publishedAt),
            events: events.values.sorted(by: Self.eventPrecedes),
            accountDays: accounts.values.sorted(by: Self.accountPrecedes),
            excludedRecords: fresh.excludedRecords)
        try result.validateCanonical(workspaceID: fresh.workspaceID, now: result.publishedAt)
        return result
    }

    /// A legacy aggregate has unknown constituents. Keep all raw candidates in canonical storage,
    /// but never add fine rows on top of an overlapping opaque provider/day aggregate in the display.
    public static func canonicalDisplayEvents(_ publication: MidasUsageSyncPublication) -> [MidasUsageSyncEvent] {
        var fine: [MidasUsageSyncRollup.DayKey: [MidasUsageSyncEvent]] = [:]
        var legacy: [MidasUsageSyncRollup.DayKey: [MidasUsageSyncEvent]] = [:]
        var unique: [EventKey: MidasUsageSyncEvent] = [:]
        for event in publication.events {
            let key = EventKey(event)
            if let old = unique[key], !Self.prefers(event, over: old) { continue }
            unique[key] = event
        }
        for event in unique.values.sorted(by: Self.eventPrecedes) {
            let key = MidasUsageSyncRollup.DayKey(event)
            if MidasUsageSyncRollup.isRollup(event, deviceID: publication.deviceID) {
                legacy[key, default: []].append(event)
            } else {
                fine[key, default: []].append(event)
            }
        }
        var result: [MidasUsageSyncEvent] = []
        for key in Set(fine.keys).union(legacy.keys).sorted() {
            let individuals = fine[key] ?? []
            let aggregates = legacy[key] ?? []
            if aggregates.isEmpty {
                result += individuals
            } else if individuals.isEmpty {
                result += aggregates
            } else {
                result += Self.coversLegacyBaseline(individuals, aggregates: aggregates) ? individuals : aggregates
            }
        }
        return result.sorted(by: Self.eventPrecedes)
    }

    private static func coversLegacyBaseline(
        _ individuals: [MidasUsageSyncEvent], aggregates: [MidasUsageSyncEvent]) -> Bool
    {
        // Erased membership cannot prove exact coverage. Preserve every known baseline metric
        // until the independently retained fine evidence covers it, and continue reporting uncertainty.
        let metrics: [(MidasUsageSyncValues) -> Double?] = [
            { $0.tokens.map(Double.init) }, { $0.requests.map(Double.init) },
            { $0.costUSD }, { $0.apiEquivalentCostUSD },
        ]
        return metrics.allSatisfy { metric in
            let baseline = aggregates.compactMap { metric($0.values) }
            guard !baseline.isEmpty else { return true }
            let fine = individuals.compactMap { metric($0.values) }
            return !fine.isEmpty && fine.reduce(0, +) >= baseline.reduce(0, +)
        }
    }

    private static func tokenTotal(_ events: [MidasUsageSyncEvent]) -> Int {
        events.reduce(0) { total, event in
            let next = total.addingReportingOverflow(event.values.tokens ?? 0)
            return next.overflow ? Int.max : next.partialValue
        }
    }

    public enum Validation: Sendable { case legacy, canonical }

    public init(
        publications: [MidasUsageSyncPublication],
        workspaceID: UUID,
        now: Date = Date(),
        validation: Validation = .legacy) throws
    {
        // The coordinator reconciles up to 128 cached + 128 received + one local revision.
        guard publications.count <= 257 else { throw MidasUsageSyncError.limitExceeded }
        var devices: [UUID: MidasUsageSyncPublication] = [:]
        for publication in publications {
            if validation == .canonical {
                try publication.validateCanonical(workspaceID: workspaceID, now: now)
            } else {
                try publication.validate(workspaceID: workspaceID, now: now)
            }
            if let previous = devices[publication.deviceID], !Self.prefers(publication, over: previous) { continue }
            devices[publication.deviceID] = publication
        }
        self.publications = devices.values.sorted { $0.deviceID.uuidString < $1.deviceID.uuidString }
        guard self.publications.count <= 128 else { throw MidasUsageSyncError.limitExceeded }
        let recordCount = self.publications.reduce(0) { $0 + $1.events.count + $1.accountDays.count }
        let maximumRecords = validation == .canonical ? MidasUsageSyncPublication.maximumCanonicalRecords : 250_000
        guard recordCount <= maximumRecords else { throw MidasUsageSyncError.limitExceeded }
        self.excludedRecords = Self.sumIntegers(self.publications.map(\.excludedRecords)) ?? Int.max
        var events: [EventKey: MidasUsageSyncEvent] = [:]
        var accounts: [AccountKey: MidasUsageSyncAccountDay] = [:]
        for publication in self.publications {
            for event in validation == .canonical ? Self.canonicalDisplayEvents(publication) : publication.events {
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
        MidasUsageSyncRecordOrder.prefers(lhs, over: rhs)
    }

    private static func prefers(_ lhs: MidasUsageSyncAccountDay, over rhs: MidasUsageSyncAccountDay) -> Bool {
        MidasUsageSyncRecordOrder.prefers(lhs, over: rhs)
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
