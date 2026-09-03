import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Z.ai usage limit types from the API
public enum ZaiLimitType: String, Sendable, Codable {
    case timeLimit = "TIME_LIMIT"
    case tokensLimit = "TOKENS_LIMIT"
}

/// Z.ai usage limit unit types
public enum ZaiLimitUnit: Int, Sendable, Codable {
    case unknown = 0
    case days = 1
    case hours = 3
    case minutes = 5
    case weeks = 6
}

/// Interprets a z.ai epoch reset stamp that may arrive in milliseconds or seconds.
///
/// z.ai's quota API has historically returned `nextResetTime` in milliseconds, but the field is
/// untyped and individual limit rows (or future API revisions) can hand back plain seconds. Dividing
/// unconditionally by 1000 would then place the reset back near 1970 and surface a nonsense "resets"
/// label. We disambiguate with the same `10_000_000_000` threshold the other providers use
/// (T3Chat, Devin, MiniMax, Kilo): a millisecond stamp for any realistic reset date is far above it,
/// while a seconds stamp stays well below, so this is a no-op for today's millisecond payloads.
enum ZaiEpoch {
    /// Epoch values above this are treated as milliseconds; at or below, as seconds.
    /// 1e10 seconds is the year 2286 and 1e10 ms is April 1970, so any plausible reset date is
    /// classified unambiguously.
    static let millisecondThreshold = 10_000_000_000

    static func date(fromMillisOrSeconds raw: Int64) -> Date {
        let magnitude = raw == Int64.min ? Int64.max : Swift.abs(raw)
        let seconds = magnitude > self.millisecondThreshold ? Double(raw) / 1000.0 : Double(raw)
        return Date(timeIntervalSince1970: seconds)
    }
}

/// A single limit entry from the z.ai API
public struct ZaiLimitEntry: Sendable, Codable {
    public let type: ZaiLimitType
    public let unit: ZaiLimitUnit
    public let number: Int
    public let usage: Int?
    public let currentValue: Int?
    public let remaining: Int?
    public let percentage: Double
    public let usageDetails: [ZaiUsageDetail]
    public let nextResetTime: Date?

    public init(
        type: ZaiLimitType,
        unit: ZaiLimitUnit,
        number: Int,
        usage: Int?,
        currentValue: Int?,
        remaining: Int?,
        percentage: Double,
        usageDetails: [ZaiUsageDetail],
        nextResetTime: Date?)
    {
        self.type = type
        self.unit = unit
        self.number = number
        self.usage = usage
        self.currentValue = currentValue
        self.remaining = remaining
        self.percentage = percentage
        self.usageDetails = usageDetails
        self.nextResetTime = nextResetTime
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case unit
        case number
        case usage
        case currentValue
        case remaining
        case percentage
        case usageDetails
        case nextResetTime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(ZaiLimitType.self, forKey: .type)
        self.unit = try container.decode(ZaiLimitUnit.self, forKey: .unit)
        self.number = try container.decode(Int.self, forKey: .number)
        self.usage = try container.decodeIfPresent(Int.self, forKey: .usage)
        self.currentValue = try container.decodeIfPresent(Int.self, forKey: .currentValue)
        self.remaining = try container.decodeIfPresent(Int.self, forKey: .remaining)
        self.percentage = try container.decodeIfPresent(Double.self, forKey: .percentage) ?? 0
        self.usageDetails = try container.decodeIfPresent([ZaiUsageDetail].self, forKey: .usageDetails) ?? []
        self.nextResetTime = try container.decodeIfPresent(Date.self, forKey: .nextResetTime)
    }
}

extension ZaiLimitEntry {
    public var usedPercent: Double {
        if let computed = self.computedUsedPercent {
            return computed
        }
        return self.percentage
    }

    public var windowMinutes: Int? {
        guard self.number > 0 else { return nil }
        switch self.unit {
        case .minutes:
            return self.number
        case .hours:
            return self.number * 60
        case .days:
            return self.number * 24 * 60
        case .weeks:
            return self.number * 7 * 24 * 60
        case .unknown:
            return nil
        }
    }

    public var windowDescription: String? {
        guard self.number > 0 else { return nil }
        let unitLabel: String? = switch self.unit {
        case .minutes: "minute"
        case .hours: "hour"
        case .days: "day"
        case .weeks: "week"
        case .unknown: nil
        }
        guard let unitLabel else { return nil }
        let suffix = self.number == 1 ? unitLabel : "\(unitLabel)s"
        return "\(self.number) \(suffix)"
    }

    public var windowLabel: String? {
        guard let description = self.windowDescription else { return nil }
        return "\(description) window"
    }

    var isMCPMonthlyMarker: Bool {
        self.type == .timeLimit && self.unit == .minutes && self.number == 1
    }

    private var computedUsedPercent: Double? {
        guard let limit = self.usage, limit > 0 else { return nil }

        // z.ai sometimes omits quota fields; don't invent zeros (can yield 100% used incorrectly).
        var usedRaw: Int?
        if let remaining = self.remaining {
            let usedFromRemaining = limit - remaining
            if let currentValue = self.currentValue {
                usedRaw = max(usedFromRemaining, currentValue)
            } else {
                usedRaw = usedFromRemaining
            }
        } else if let currentValue = self.currentValue {
            usedRaw = currentValue
        }
        guard let usedRaw else { return nil }

        let used = max(0, min(limit, usedRaw))
        let percent = (Double(used) / Double(limit)) * 100
        return min(100, max(0, percent))
    }
}

/// Usage detail for MCP tools
public struct ZaiUsageDetail: Sendable, Codable {
    public let modelCode: String
    public let usage: Int

    public init(modelCode: String, usage: Int) {
        self.modelCode = modelCode
        self.usage = usage
    }
}

/// Complete z.ai usage response
public struct ZaiUsageSnapshot: Sendable, Codable {
    public let tokenLimit: ZaiLimitEntry?
    /// Shorter-window TOKENS_LIMIT (e.g. 5-hour), present only when the API returns two TOKENS_LIMIT entries.
    public let sessionTokenLimit: ZaiLimitEntry?
    public let timeLimit: ZaiLimitEntry?
    public let planName: String?
    public let modelUsage: ZaiModelUsageData?
    public let updatedAt: Date

    public init(
        tokenLimit: ZaiLimitEntry?,
        sessionTokenLimit: ZaiLimitEntry? = nil,
        timeLimit: ZaiLimitEntry?,
        planName: String?,
        modelUsage: ZaiModelUsageData? = nil,
        updatedAt: Date)
    {
        self.tokenLimit = tokenLimit
        self.sessionTokenLimit = sessionTokenLimit
        self.timeLimit = timeLimit
        self.planName = planName
        self.modelUsage = modelUsage
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case tokenLimit
        case sessionTokenLimit
        case timeLimit
        case planName
        case modelUsage
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tokenLimit = try container.decodeIfPresent(ZaiLimitEntry.self, forKey: .tokenLimit)
        self.sessionTokenLimit = try container.decodeIfPresent(ZaiLimitEntry.self, forKey: .sessionTokenLimit)
        self.timeLimit = try container.decodeIfPresent(ZaiLimitEntry.self, forKey: .timeLimit)
        self.planName = try container.decodeIfPresent(String.self, forKey: .planName)
        // modelUsage is intentionally optional — it's not persisted across launches (it's a
        // best-effort 24h fetch, cheap to refetch, and would bloat the snapshot cache).
        self.modelUsage = nil
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.tokenLimit, forKey: .tokenLimit)
        try container.encodeIfPresent(self.sessionTokenLimit, forKey: .sessionTokenLimit)
        try container.encodeIfPresent(self.timeLimit, forKey: .timeLimit)
        try container.encodeIfPresent(self.planName, forKey: .planName)
        // modelUsage is excluded from encoding so the cache stays compact.
        try container.encode(self.updatedAt, forKey: .updatedAt)
    }

    /// Returns true if this snapshot contains valid z.ai data
    public var isValid: Bool {
        self.tokenLimit != nil || self.timeLimit != nil
    }
}

extension ZaiUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let primaryLimit = self.tokenLimit ?? self.timeLimit
        let secondaryLimit = (self.tokenLimit != nil && self.timeLimit != nil) ? self.timeLimit : nil
        let primary = primaryLimit.map { Self.rateWindow(for: $0) } ?? RateWindow(
            usedPercent: 0,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: nil)
        let secondary = secondaryLimit.map { Self.rateWindow(for: $0) }
        let tertiary = self.sessionTokenLimit.map { Self.rateWindow(for: $0) }

        let planName = self.planName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginMethod = (planName?.isEmpty ?? true) ? nil : planName
        let identity = ProviderIdentitySnapshot(
            providerID: .zai,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: loginMethod)
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            providerCost: nil,
            zaiUsage: self,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private static func rateWindow(for limit: ZaiLimitEntry) -> RateWindow {
        RateWindow(
            usedPercent: limit.usedPercent,
            windowMinutes: limit.type == .tokensLimit ? limit.windowMinutes : nil,
            resetsAt: limit.nextResetTime,
            resetDescription: self.resetDescription(for: limit))
    }

    private static func resetDescription(for limit: ZaiLimitEntry) -> String? {
        if limit.isMCPMonthlyMarker {
            return "Monthly"
        }
        if let label = limit.windowLabel {
            return label
        }
        if limit.type == .timeLimit {
            return "Monthly"
        }
        return nil
    }
}

/// Z.ai quota limit API response
private struct ZaiQuotaLimitResponse: Decodable {
    let code: Int
    let msg: String
    let data: ZaiQuotaLimitData?
    let success: Bool

    var isSuccess: Bool {
        self.success && self.code == 200
    }
}

private struct ZaiQuotaLimitData: Decodable {
    let limits: [ZaiLimitRaw]
    let planName: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.limits = try container.decodeIfPresent([ZaiLimitRaw].self, forKey: .limits) ?? []
        let explicitPlan = try [
            container.decodeIfPresent(String.self, forKey: .planName),
            container.decodeIfPresent(String.self, forKey: .plan),
            container.decodeIfPresent(String.self, forKey: .planType),
            container.decodeIfPresent(String.self, forKey: .packageName),
        ].compactMap(\.self).first
        // The live quota API reports the subscription tier only as a lowercase `level` code
        // (e.g. "pro", "max"). Surface it as the plan when no explicit name field is present, and
        // upper-case the leading character so it reads like the z.ai console ("Pro").
        let levelTier = try container.decodeIfPresent(String.self, forKey: .level)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0.prefix(1).uppercased() + $0.dropFirst() }
        let trimmed = (explicitPlan ?? levelTier)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.planName = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case limits
        case planName
        case plan
        case planType = "plan_type"
        case packageName
        case level
    }
}

private struct ZaiLimitRaw: Decodable {
    let type: String
    let unit: Int
    let number: Int
    let usage: Int?
    let currentValue: Int?
    let remaining: Int?
    let percentage: Double
    let usageDetails: [ZaiUsageDetail]?
    let nextResetTime: Int64?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(String.self, forKey: .type)
        self.unit = container.decodeZaiLossyIntIfPresent(forKey: .unit) ?? ZaiLimitUnit.unknown.rawValue
        self.number = container.decodeZaiLossyIntIfPresent(forKey: .number) ?? 0
        self.usage = container.decodeZaiLossyIntIfPresent(forKey: .usage)
        self.currentValue = container.decodeZaiLossyIntIfPresent(forKey: .currentValue)
        self.remaining = container.decodeZaiLossyIntIfPresent(forKey: .remaining)
        self.percentage = container.decodeZaiLossyDoubleIfPresent(forKey: .percentage) ?? 0
        self.usageDetails = try container.decodeIfPresent([ZaiUsageDetail].self, forKey: .usageDetails)
        self.nextResetTime = container.decodeZaiLossyInt64IfPresent(forKey: .nextResetTime)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case unit
        case number
        case usage
        case currentValue
        case remaining
        case percentage
        case usageDetails
        case nextResetTime
    }

    func toLimitEntry() -> ZaiLimitEntry? {
        guard let limitType = ZaiLimitType(rawValue: type) else { return nil }
        let limitUnit = ZaiLimitUnit(rawValue: unit) ?? .unknown
        let nextReset = self.nextResetTime.map(ZaiEpoch.date(fromMillisOrSeconds:))
        return ZaiLimitEntry(
            type: limitType,
            unit: limitUnit,
            number: self.number,
            usage: self.usage,
            currentValue: self.currentValue,
            remaining: self.remaining,
            percentage: self.percentage,
            usageDetails: self.usageDetails ?? [],
            nextResetTime: nextReset)
    }
}

/// Fetches usage stats from the z.ai API
public struct ZaiUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.zaiUsage)

    /// Path for z.ai quota API
    private static let quotaAPIPath = "api/monitor/usage/quota/limit"

    /// Resolves the quota URL using (in order):
    /// 1) `Z_AI_QUOTA_URL` environment override (full URL).
    /// 2) `Z_AI_API_HOST` environment override (host/base URL).
    /// 3) Region selection (global default).
    public static func resolveQuotaURL(
        region: ZaiAPIRegion,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let override = ZaiSettingsReader.quotaURL(environment: environment) {
            return override
        }
        if let host = ZaiSettingsReader.apiHost(environment: environment),
           let hostURL = self.quotaURL(baseURLString: host)
        {
            return hostURL
        }
        return region.quotaLimitURL
    }

    /// Fetches usage stats from z.ai using the provided API key
    public static func fetchUsage(
        apiKey: String,
        region: ZaiAPIRegion = .global,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> ZaiUsageSnapshot
    {
        guard !apiKey.isEmpty else {
            throw ZaiUsageError.invalidCredentials
        }

        let quotaURL = self.resolveQuotaURL(region: region, environment: environment)

        var request = URLRequest(url: quotaURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")

        let response = try await ProviderHTTPClient.shared.response(
            for: request,
            retryPolicy: .transientIdempotent)
        let data = response.data
        guard response.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            Self.log.error("z.ai API returned \(response.statusCode): \(errorMessage)")
            throw ZaiUsageError.apiError("HTTP \(response.statusCode): \(errorMessage)")
        }

        // Some upstream issues (wrong endpoint/region/proxy) can yield HTTP 200 with an empty body.
        // JSONDecoder will otherwise throw an opaque Cocoa error ("data is missing").
        guard !data.isEmpty else {
            Self.log.error("z.ai API returned empty body (HTTP 200) for \(Self.safeURLForLogging(quotaURL))")
            throw ZaiUsageError.parseFailed(
                "Empty response body (HTTP 200). Check z.ai API region (Global vs BigModel CN) and your API token.")
        }

        // Log raw response for debugging
        if let jsonString = String(data: data, encoding: .utf8) {
            Self.log.debug("z.ai API response: \(jsonString)")
        }

        do {
            return try Self.parseUsageSnapshot(from: data)
        } catch let error as DecodingError {
            Self.log.error("z.ai JSON decoding error: \(error.localizedDescription)")
            throw ZaiUsageError.parseFailed(error.localizedDescription)
        } catch let error as ZaiUsageError {
            throw error
        } catch {
            Self.log.error("z.ai parsing error: \(error.localizedDescription)")
            throw ZaiUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func safeURLForLogging(_ url: URL) -> String {
        let host = url.host ?? "<unknown-host>"
        let port = url.port.map { ":\($0)" } ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        return "\(host)\(port)\(path)"
    }

    static func parseUsageSnapshot(from data: Data) throws -> ZaiUsageSnapshot {
        guard !data.isEmpty else {
            throw ZaiUsageError.parseFailed("Empty response body")
        }

        let decoder = JSONDecoder()
        let apiResponse = try decoder.decode(ZaiQuotaLimitResponse.self, from: data)

        guard apiResponse.isSuccess else {
            throw ZaiUsageError.apiError(apiResponse.msg)
        }

        guard let responseData = apiResponse.data else {
            throw ZaiUsageError.parseFailed("Missing data")
        }

        var tokenLimits: [ZaiLimitEntry] = []
        var timeLimit: ZaiLimitEntry?

        for limit in responseData.limits {
            if let entry = limit.toLimitEntry() {
                switch entry.type {
                case .tokensLimit:
                    tokenLimits.append(entry)
                case .timeLimit:
                    timeLimit = entry
                }
            }
        }

        // Multiple TOKENS_LIMIT entries: shortest window → sessionTokenLimit (tertiary),
        // longest → tokenLimit (primary).
        let tokenLimit: ZaiLimitEntry?
        let sessionTokenLimit: ZaiLimitEntry?
        if tokenLimits.count >= 2 {
            let sorted = tokenLimits.sorted {
                ($0.windowMinutes ?? Int.max) < ($1.windowMinutes ?? Int.max)
            }
            sessionTokenLimit = sorted.first
            tokenLimit = sorted.last
        } else {
            tokenLimit = tokenLimits.first
            sessionTokenLimit = nil
        }

        return ZaiUsageSnapshot(
            tokenLimit: tokenLimit,
            sessionTokenLimit: sessionTokenLimit,
            timeLimit: timeLimit,
            planName: responseData.planName,
            modelUsage: nil,
            updatedAt: Date())
    }

    private static func quotaURL(baseURLString: String) -> URL? {
        guard let cleaned = ZaiSettingsReader.cleaned(baseURLString) else { return nil }

        if let url = URL(string: cleaned), url.scheme != nil {
            if url.path.isEmpty || url.path == "/" {
                return url.appendingPathComponent(Self.quotaAPIPath)
            }
            return url
        }
        guard let base = URL(string: "https://\(cleaned)") else { return nil }
        if base.path.isEmpty || base.path == "/" {
            return base.appendingPathComponent(Self.quotaAPIPath)
        }
        return base
    }
}

// MARK: - Model Usage Data

/// Per-model hourly token usage from the z.ai model-usage API
public struct ZaiModelUsageData: Sendable, Codable {
    public let xTime: [String]
    public let modelDataList: [ZaiModelDataItem]

    public init(xTime: [String], modelDataList: [ZaiModelDataItem]) {
        self.xTime = xTime
        self.modelDataList = modelDataList
    }

    enum CodingKeys: String, CodingKey {
        case xTime
        case x_time
        case modelDataList
        case model_data_list
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.xTime = try container.decodeIfPresent([String].self, forKey: .xTime)
            ?? container.decodeIfPresent([String].self, forKey: .x_time)
            ?? []
        self.modelDataList = try container.decodeIfPresent([ZaiModelDataItem].self, forKey: .modelDataList)
            ?? container.decodeIfPresent([ZaiModelDataItem].self, forKey: .model_data_list)
            ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.xTime, forKey: .xTime)
        try container.encode(self.modelDataList, forKey: .modelDataList)
    }

    public var modelNames: [String] {
        self.modelDataList.compactMap(\.modelName)
    }
}

public struct ZaiModelDataItem: Sendable, Codable {
    public let modelName: String?
    public let tokensUsage: [Int?]

    public init(modelName: String?, tokensUsage: [Int?]) {
        self.modelName = modelName
        self.tokensUsage = tokensUsage
    }

    enum CodingKeys: String, CodingKey {
        case modelName
        case model_name
        case tokensUsage
        case tokens_usage
        case tokenUsage
        case token_usage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
            ?? container.decodeIfPresent(String.self, forKey: .model_name)
        self.tokensUsage = try container.decodeIfPresent([Int?].self, forKey: .tokensUsage)
            ?? container.decodeIfPresent([Int?].self, forKey: .tokens_usage)
            ?? container.decodeIfPresent([Int?].self, forKey: .tokenUsage)
            ?? container.decodeIfPresent([Int?].self, forKey: .token_usage)
            ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.modelName, forKey: .modelName)
        try container.encode(self.tokensUsage, forKey: .tokensUsage)
    }
}

// MARK: - Hourly Chart Data

public enum ZaiHourlyRange: Equatable, Sendable {
    case today(referenceDate: Date)
    case last24h

    public var isToday: Bool {
        if case .today = self { return true }
        return false
    }
}

public struct ZaiHourlyBar: Sendable {
    public let label: String
    public let segments: [(model: String, tokens: Int)]

    public init(label: String, segments: [(model: String, tokens: Int)]) {
        self.label = label
        self.segments = segments
    }

    public var totalTokens: Int {
        self.segments.reduce(0) { $0 + $1.tokens }
    }
}

public enum ZaiHourlyBars: Sendable {
    public static func from(modelData: ZaiModelUsageData, range: ZaiHourlyRange, now: Date = Date()) -> [ZaiHourlyBar] {
        let calendar = Calendar.current
        let referenceDate: Date = switch range {
        case let .today(ref): ref
        case .last24h: now
        }

        let todayStart = calendar.startOfDay(for: referenceDate)
        let cutoff: Date = switch range {
        case .today: todayStart
        case .last24h: calendar.date(byAdding: .hour, value: -24, to: now) ?? now
        }

        var bars: [ZaiHourlyBar] = []
        for (index, timeString) in modelData.xTime.enumerated() {
            guard let hourDate = parseHourDate(timeString) else { continue }

            if hourDate < cutoff { continue }

            var segments: [(model: String, tokens: Int)] = []
            for item in modelData.modelDataList {
                guard index < item.tokensUsage.count,
                      let tokenCount = item.tokensUsage[index], tokenCount > 0
                else { continue }
                segments.append((model: item.modelName ?? "Unknown", tokens: tokenCount))
            }

            let total = segments.reduce(0) { $0 + $1.tokens }
            guard total > 0 else { continue }

            let label = self.formatHourLabel(hourDate: hourDate)
            bars.append(ZaiHourlyBar(label: label, segments: segments))
        }

        return bars
    }

    public static func parseHourDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss"] {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        return ISO8601DateFormatter().date(from: trimmed)
    }

    private static func formatHourLabel(hourDate: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: hourDate)
    }
}

// MARK: - Model Usage Fetcher Extension

extension ZaiUsageFetcher {
    /// Fetches hourly model usage data for the last 24 hours
    public static func fetchModelUsage(
        apiKey: String,
        region: ZaiAPIRegion = .global,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> ZaiModelUsageData
    {
        guard !apiKey.isEmpty else {
            throw ZaiUsageError.invalidCredentials
        }

        let now = Date()
        let calendar = Calendar.current
        guard let startDate = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) else {
            throw ZaiUsageError.parseFailed("Invalid date calculation")
        }

        return try await Self.fetchModelUsageRange(
            apiKey: apiKey,
            region: region,
            environment: environment,
            since: startDate,
            until: now)
    }

    /// Fetches hourly model usage data for an arbitrary `[since, until]` window.
    ///
    /// Used by the estimated-cost path to pull up to ~30 days of per-model token counts, which the
    /// z.ai quota API does not expose. The endpoint accepts `startTime`/`endTime` query params and
    /// returns hourly buckets; callers aggregate into daily buckets.
    ///
    /// `until` is truncated to the **minute**, not the hour, so the current hour shows up in the
    /// chart within minutes of generation. Set `ZAI_MODEL_USAGE_HOUR_PRECISION=1` to restore the
    /// legacy hour-truncated behavior in case an upstream endpoint rejects minute precision.
    public static func fetchModelUsageRange(
        apiKey: String,
        region: ZaiAPIRegion = .global,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        since: Date,
        until: Date) async throws -> ZaiModelUsageData
    {
        guard !apiKey.isEmpty else {
            throw ZaiUsageError.invalidCredentials
        }

        let baseURL: URL = if let host = ZaiSettingsReader.apiHost(environment: environment),
                              let resolved = Self.modelUsageURL(baseURLString: host)
        {
            resolved
        } else {
            region.modelUsageURL
        }

        let hourPrecision = environment["ZAI_MODEL_USAGE_HOUR_PRECISION"] == "1"

        let calendar = Calendar.current
        let startComponents = calendar.dateComponents([.year, .month, .day, .hour], from: since)
        let endComponents: DateComponents = if hourPrecision {
            calendar.dateComponents([.year, .month, .day, .hour], from: until)
        } else {
            calendar.dateComponents([.year, .month, .day, .hour, .minute], from: until)
        }
        let startTime = String(
            format: "%04d-%02d-%02d %02d:00:00",
            startComponents.year!,
            startComponents.month!,
            startComponents.day!,
            startComponents.hour!)
        let endTime = if hourPrecision {
            String(
                format: "%04d-%02d-%02d %02d:59:59",
                endComponents.year!,
                endComponents.month!,
                endComponents.day!,
                endComponents.hour!)
        } else {
            String(
                format: "%04d-%02d-%02d %02d:%02d:59",
                endComponents.year!,
                endComponents.month!,
                endComponents.day!,
                endComponents.hour!,
                endComponents.minute ?? 0)
        }

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ZaiUsageError.networkError("Invalid URL")
        }
        components.queryItems = [
            URLQueryItem(name: "startTime", value: startTime),
            URLQueryItem(name: "endTime", value: endTime),
        ]

        guard let requestURL = components.url else {
            throw ZaiUsageError.networkError("Invalid URL")
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let response = try await ProviderHTTPClient.shared.response(
            for: request,
            retryPolicy: .transientIdempotent)
        let data = response.data
        guard response.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            Self.log.error("z.ai model-usage API returned \(response.statusCode): \(errorMessage)")
            throw ZaiUsageError.apiError("HTTP \(response.statusCode): \(errorMessage)")
        }

        guard !data.isEmpty else { return ZaiModelUsageData(xTime: [], modelDataList: []) }

        return try Self.parseModelUsage(from: data)
    }

    static func parseModelUsage(from data: Data) throws -> ZaiModelUsageData {
        let decoder = JSONDecoder()
        let apiResponse = try decoder.decode(ZaiModelUsageAPIResponse.self, from: data)

        guard apiResponse.isSuccess else {
            throw ZaiUsageError.apiError(apiResponse.msg)
        }

        guard let responseData = apiResponse.data else {
            return ZaiModelUsageData(xTime: [], modelDataList: [])
        }

        let items = responseData.modelDataList?.map { raw in
            ZaiModelDataItem(
                modelName: raw.modelName,
                tokensUsage: raw.tokensUsage ?? [])
        } ?? []

        return ZaiModelUsageData(
            xTime: responseData.xTime ?? [],
            modelDataList: items)
    }

    /// Fetches required quota data and attaches optional model usage when available.
    public static func fetchUsageWithModelUsage(
        apiKey: String,
        region: ZaiAPIRegion = .global,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> ZaiUsageSnapshot
    {
        let snapshot = try await Self.fetchUsage(apiKey: apiKey, region: region, environment: environment)
        let modelUsage: ZaiModelUsageData?
        do {
            modelUsage = try await Self.fetchModelUsage(apiKey: apiKey, region: region, environment: environment)
        } catch {
            Self.log.info("z.ai model usage fetch failed (non-fatal): \(error.localizedDescription)")
            modelUsage = nil
        }

        guard modelUsage != nil else { return snapshot }

        return ZaiUsageSnapshot(
            tokenLimit: snapshot.tokenLimit,
            sessionTokenLimit: snapshot.sessionTokenLimit,
            timeLimit: snapshot.timeLimit,
            planName: snapshot.planName,
            modelUsage: modelUsage,
            updatedAt: snapshot.updatedAt)
    }

    private static func modelUsageURL(baseURLString: String) -> URL? {
        guard let cleaned = ZaiSettingsReader.cleaned(baseURLString) else { return nil }
        let path = "api/monitor/usage/model-usage"

        if let url = URL(string: cleaned), url.scheme != nil {
            if url.path.isEmpty || url.path == "/" {
                return url.appendingPathComponent(path)
            }
            return url
        }
        guard let base = URL(string: "https://\(cleaned)") else { return nil }
        if base.path.isEmpty || base.path == "/" {
            return base.appendingPathComponent(path)
        }
        return base
    }
}

// MARK: - Model Usage API Response (private)

private struct ZaiModelUsageAPIResponse: Decodable {
    let code: Int
    let msg: String
    let data: ZaiModelUsageRawData?
    let success: Bool

    var isSuccess: Bool {
        self.success && self.code == 200
    }
}

private struct ZaiModelUsageRawData: Decodable {
    let xTime: [String]?
    let modelDataList: [ZaiModelDataItemRaw]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.xTime = try container.decodeIfPresent([String].self, forKey: .xTimeSnake)
            ?? container.decodeIfPresent([String].self, forKey: .xTimeCamel)
        self.modelDataList = try container.decodeIfPresent([ZaiModelDataItemRaw].self, forKey: .modelDataList)
            ?? container.decodeIfPresent([ZaiModelDataItemRaw].self, forKey: .modelDataListSnake)
    }

    private enum CodingKeys: String, CodingKey {
        case xTimeSnake = "x_time"
        case xTimeCamel = "xTime"
        case modelDataListSnake = "model_data_list"
        case modelDataList
    }
}

private struct ZaiModelDataItemRaw: Decodable {
    let modelName: String?
    let tokensUsage: [Int?]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
            ?? container.decodeIfPresent(String.self, forKey: .modelNameSnake)
            ?? container.decodeIfPresent(String.self, forKey: .modelCode)
        let usage = try container.decodeIfPresent([ZaiFlexibleOptionalInt].self, forKey: .tokensUsage)
            ?? container.decodeIfPresent([ZaiFlexibleOptionalInt].self, forKey: .tokensUsageSnake)
            ?? container.decodeIfPresent([ZaiFlexibleOptionalInt].self, forKey: .tokenUsage)
        self.tokensUsage = usage?.map(\.value)
    }

    private enum CodingKeys: String, CodingKey {
        case modelName
        case modelNameSnake = "model_name"
        case modelCode
        case tokensUsage
        case tokensUsageSnake = "tokens_usage"
        case tokenUsage
    }
}

private struct ZaiFlexibleOptionalInt: Decodable {
    let value: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = nil
        } else if let intValue = try? container.decode(Int.self) {
            self.value = intValue
        } else if let int64Value = try? container.decode(Int64.self) {
            self.value = Int(exactly: int64Value)
        } else if let doubleValue = try? container.decode(Double.self), doubleValue.isFinite {
            self.value = Int(doubleValue.rounded())
        } else if let stringValue = try? container.decode(String.self) {
            self.value = Self.parseInt(stringValue)
        } else {
            self.value = nil
        }
    }

    fileprivate static func parseInt(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let intValue = Int(trimmed) {
            return intValue
        }
        guard let doubleValue = Double(trimmed), doubleValue.isFinite else {
            return nil
        }
        return Int(doubleValue.rounded())
    }
}

extension KeyedDecodingContainer where K: CodingKey {
    fileprivate func decodeZaiLossyIntIfPresent(forKey key: K) -> Int? {
        if let value = try? self.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? self.decodeIfPresent(Int64.self, forKey: key) {
            return Int(exactly: value)
        }
        if let value = try? self.decodeIfPresent(Double.self, forKey: key), value.isFinite {
            return Int(value.rounded())
        }
        if let stringValue = try? self.decodeIfPresent(String.self, forKey: key) {
            return ZaiFlexibleOptionalInt.parseInt(stringValue)
        }
        return nil
    }

    fileprivate func decodeZaiLossyInt64IfPresent(forKey key: K) -> Int64? {
        if let value = try? self.decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let value = try? self.decodeIfPresent(Int.self, forKey: key) {
            return Int64(value)
        }
        if let value = try? self.decodeIfPresent(Double.self, forKey: key), value.isFinite {
            return Int64(value.rounded())
        }
        if let stringValue = try? self.decodeIfPresent(String.self, forKey: key) {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Int64(trimmed) {
                return value
            }
            guard let doubleValue = Double(trimmed), doubleValue.isFinite else { return nil }
            return Int64(doubleValue.rounded())
        }
        return nil
    }

    fileprivate func decodeZaiLossyDoubleIfPresent(forKey key: K) -> Double? {
        if let value = try? self.decodeIfPresent(Double.self, forKey: key), value.isFinite {
            return value
        }
        if let value = try? self.decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let stringValue = try? self.decodeIfPresent(String.self, forKey: key) {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Double(trimmed), value.isFinite else { return nil }
            return value
        }
        return nil
    }
}

/// Errors that can occur during z.ai usage fetching
public enum ZaiUsageError: LocalizedError, Sendable {
    case invalidCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "Invalid z.ai API credentials"
        case let .networkError(message):
            "z.ai network error: \(message)"
        case let .apiError(message):
            "z.ai API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse z.ai response: \(message)"
        }
    }
}
