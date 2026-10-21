#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A workspace is an opt-in, private numeric ledger. It contains no provider authentication.
public struct MidasUsageSyncWorkspace: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public let id: UUID
    public let identitySalt: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        identitySalt: String = UUID().uuidString + UUID().uuidString,
        createdAt: Date = Date(),
        schemaVersion: Int = 1)
    {
        self.schemaVersion = schemaVersion
        self.id = id
        self.identitySalt = identitySalt
        self.createdAt = createdAt
    }

    /// Salted identities are portable within this workspace, without exposing account or session identifiers.
    public func opaqueID(provider: UsageProvider, components: [String]) -> String {
        let value = [self.identitySalt, provider.rawValue] + components
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        let digest = SHA256.hash(data: data)
        // These IDs must remain byte-compatible with previous versions. Formatting each
        // byte separately creates 32 Foundation strings for every scanned usage event.
        return String(unsafeUninitializedCapacity: SHA256.byteCount * 2) { buffer in
            var index = 0
            for byte in digest {
                let high = byte >> 4
                let low = byte & 15
                buffer[index] = high + (high < 10 ? 48 : 87)
                buffer[index + 1] = low + (low < 10 ? 48 : 87)
                index += 2
            }
            return index
        }
    }

    public func validate() throws {
        guard self.schemaVersion == 1 else { throw MidasUsageSyncError.unsupportedSchema }
        guard (32...256).contains(self.identitySalt.utf8.count), self.createdAt.timeIntervalSince1970.isFinite else {
            throw MidasUsageSyncError.invalidRecord
        }
    }
}

public enum MidasUsageSyncError: Error, LocalizedError, Sendable {
    case unsupportedSchema
    case invalidRecord
    case wrongWorkspace
    case limitExceeded
    case folderUnavailable
    case unsafeFile

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "This sync folder requires a newer version of Midas."
        case .invalidRecord: "A usage record could not be validated."
        case .wrongWorkspace: "The sync folder changed. Choose it again to reconnect."
        case .limitExceeded: "A usage file exceeds the sync safety limits."
        case .folderUnavailable: "The sync folder is unavailable. Your last received usage is retained."
        case .unsafeFile: "The sync folder contains an unsupported file or link."
        }
    }
}

/// Only numeric measurements and public model names cross devices. Unknown values remain unknown.
public struct MidasUsageSyncValues: Codable, Sendable, Equatable {
    public let tokens: Int?
    public let requests: Int?
    public let costUSD: Double?
    public let apiEquivalentCostUSD: Double?
    public let tokenMix: CostUsageTokenMix
    public let provenance: CostProvenance
    public let model: String?
    public let unpricedRequests: Int
    public let estimatedRequests: Int
    /// Controlled catalog generation. Missing legacy values are generation zero.
    public let pricingRevision: Int?

    public init(
        tokens: Int?,
        requests: Int? = nil,
        costUSD: Double?,
        apiEquivalentCostUSD: Double? = nil,
        tokenMix: CostUsageTokenMix = .init(),
        provenance: CostProvenance = .listPriceEstimate,
        model: String? = nil,
        unpricedRequests: Int = 0,
        estimatedRequests: Int = 0,
        pricingRevision: Int? = nil)
    {
        self.tokens = tokens
        self.requests = requests
        self.costUSD = costUSD
        self.apiEquivalentCostUSD = apiEquivalentCostUSD
        self.tokenMix = tokenMix
        self.provenance = provenance
        self.model = model
        self.unpricedRequests = unpricedRequests
        self.estimatedRequests = estimatedRequests
        self.pricingRevision = pricingRevision
    }

    public func validate() throws {
        // Bound imported values so the capped two-million-record ledger remains safe in every existing chart
        // aggregator.
        guard Self.validCount(self.tokens), Self.validCount(self.requests),
              Self.validCount(self.tokenMix.inputTokens), Self.validCount(self.tokenMix.outputTokens),
              Self.validCount(self.tokenMix.cacheReadTokens), Self.validCount(self.tokenMix.cacheCreationTokens),
              Self.validCount(self.tokenMix.reasoningTokens), Self.validCount(self.unpricedRequests),
              Self.validCount(self.estimatedRequests), Self.validCost(self.costUSD),
              Self.validCost(self.apiEquivalentCostUSD),
              self.pricingRevision.map({ (0...2_147_483_647).contains($0) }) ?? true,
              self.model
                  .map({
                      $0.utf8.count <= 160 && !$0.unicodeScalars
                          .contains(where: CharacterSet.controlCharacters.contains) }) ??
                  true
        else { throw MidasUsageSyncError.invalidRecord }
    }

    func withPricingRevision(_ revision: Int) -> Self {
        Self(
            tokens: self.tokens,
            requests: self.requests,
            costUSD: self.costUSD,
            apiEquivalentCostUSD: self.apiEquivalentCostUSD,
            tokenMix: self.tokenMix,
            provenance: self.provenance,
            model: self.model,
            unpricedRequests: self.unpricedRequests,
            estimatedRequests: self.estimatedRequests,
            pricingRevision: revision)
    }

    private static func validCount(_ value: Int?) -> Bool {
        value.map { (0...1_000_000_000_000).contains($0) } ?? true
    }

    private static func validCost(_ value: Double?) -> Bool {
        value.map { $0.isFinite && (0...1_000_000_000).contains($0) } ?? true
    }
}

/// One stable local request/turn. Repeated imports of the same provider event are selected, never added.
public struct MidasUsageSyncEvent: Codable, Sendable, Equatable {
    public let id: String
    public let provider: UsageProvider
    public let day: String
    public let observedAt: Date
    public let values: MidasUsageSyncValues

    public init(
        id: String,
        provider: UsageProvider,
        day: String,
        observedAt: Date,
        values: MidasUsageSyncValues)
    {
        self.id = id
        self.provider = provider
        self.day = day
        self.observedAt = observedAt
        self.values = values
    }
}

/// Provider-account history, such as Cursor. Two Macs' copies of one account/day count once.
public struct MidasUsageSyncAccountDay: Codable, Sendable, Equatable {
    public let accountScope: String
    public let provider: UsageProvider
    public let day: String
    public let observedAt: Date
    public let values: MidasUsageSyncValues

    public init(
        accountScope: String,
        provider: UsageProvider,
        day: String,
        observedAt: Date,
        values: MidasUsageSyncValues)
    {
        self.accountScope = accountScope
        self.provider = provider
        self.day = day
        self.observedAt = observedAt
        self.values = values
    }
}

public struct MidasUsageSyncPublication: Codable, Sendable, Equatable {
    public static let maximumRecords = 100_000
    /// Canonical data is paged; this count bounds aggregate arithmetic and working memory independently of wire pages.
    public static let maximumCanonicalRecords = 2_000_000
    public static let maximumFileBytes = 32 * 1024 * 1024
    public var schemaVersion: Int
    public let workspaceID: UUID
    public let deviceID: UUID
    public let deviceName: String
    public let publishedAt: Date
    public let events: [MidasUsageSyncEvent]
    public let accountDays: [MidasUsageSyncAccountDay]
    public let excludedRecords: Int

    public init(
        workspaceID: UUID,
        deviceID: UUID,
        deviceName: String,
        publishedAt: Date,
        events: [MidasUsageSyncEvent] = [],
        accountDays: [MidasUsageSyncAccountDay] = [],
        excludedRecords: Int = 0,
        schemaVersion: Int = 1)
    {
        self.schemaVersion = schemaVersion
        self.workspaceID = workspaceID
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.publishedAt = publishedAt
        self.events = events
        self.accountDays = accountDays
        self.excludedRecords = excludedRecords
    }

    public func validate(workspaceID: UUID, now: Date = Date()) throws {
        try self.validate(workspaceID: workspaceID, now: now, maximumRecords: Self.maximumRecords)
    }

    public func validateCanonical(workspaceID: UUID, now: Date = Date()) throws {
        try self.validate(workspaceID: workspaceID, now: now, maximumRecords: Self.maximumCanonicalRecords)
    }

    /// Legacy aggregates survive migration, but their erased member identities cannot be reconstructed.
    public var legacyAggregateDayCount: Int {
        Set(self.events.filter { MidasUsageSyncRollup.isRollup($0, deviceID: self.deviceID) }
            .map { $0.provider.rawValue + ":" + $0.day }).count
    }

    private func validate(workspaceID: UUID, now: Date, maximumRecords: Int) throws {
        guard self.schemaVersion == 1 else { throw MidasUsageSyncError.unsupportedSchema }
        guard self.workspaceID == workspaceID else { throw MidasUsageSyncError.wrongWorkspace }
        guard self.events.count <= maximumRecords,
              self.accountDays.count <= maximumRecords - self.events.count
        else { throw MidasUsageSyncError.limitExceeded }
        guard self.excludedRecords >= 0, self.publishedAt.timeIntervalSince1970.isFinite,
              self.publishedAt <= now.addingTimeInterval(300), self.publishedAt >= Date(timeIntervalSince1970: 0),
              (1...80).contains(self.deviceName.utf8.count),
              !self.deviceName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw MidasUsageSyncError.invalidRecord }
        let latestDay = Self.day(self.publishedAt.addingTimeInterval(300))
        // Compute each distinct UTC day once. Calendar/date-formatting per event used
        // to generate hundreds of thousands of temporary objects each sync cycle.
        var dayStarts: [String: TimeInterval] = [:]
        for event in self.events where dayStarts[event.day] == nil {
            guard event.day <= latestDay, let start = Self.dayStart(event.day) else {
                throw MidasUsageSyncError.invalidRecord
            }
            dayStarts[event.day] = start
        }
        for row in self.accountDays where dayStarts[row.day] == nil {
            guard row.day <= latestDay, let start = Self.dayStart(row.day) else {
                throw MidasUsageSyncError.invalidRecord
            }
            dayStarts[row.day] = start
        }
        for event in self.events {
            guard [.codex, .claude, .meta, .localInference].contains(event.provider), Self.isOpaqueID(event.id),
                  Self.validObservation(event.observedAt, publishedAt: self.publishedAt),
                  let start = dayStarts[event.day],
                  event.observedAt.timeIntervalSince1970 >= start,
                  event.observedAt.timeIntervalSince1970 < start + 86400
            else { throw MidasUsageSyncError.invalidRecord }
            try event.values.validate()
        }
        for row in self.accountDays {
            guard row.provider == .cursor, Self.isOpaqueID(row.accountScope),
                  Self.validObservation(row.observedAt, publishedAt: self.publishedAt)
            else { throw MidasUsageSyncError.invalidRecord }
            try row.values.validate()
        }
    }

    public static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    public static func isDay(_ value: String) -> Bool {
        self.dayStart(value) != nil
    }

    private static func dayStart(_ value: String) -> TimeInterval? {
        guard value.utf8.count == 10 else { return nil }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return nil }
        return self.day(date) == value ? date.timeIntervalSince1970 : nil
    }

    private static func isOpaqueID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func validObservation(_ value: Date, publishedAt: Date) -> Bool {
        value.timeIntervalSince1970.isFinite && value >= Date(timeIntervalSince1970: 0)
            && value <= publishedAt.addingTimeInterval(300)
    }
}
