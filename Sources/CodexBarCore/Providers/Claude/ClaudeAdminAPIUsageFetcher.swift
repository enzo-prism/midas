import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ClaudeAdminAPIUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case networkError(String)
    case apiError(endpoint: String, statusCode: Int, message: String? = nil)
    case parseFailed(endpoint: String, message: String)
    case paginationLimitExceeded(endpoint: String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Anthropic Admin API key."
        case let .networkError(message):
            "Anthropic API usage network error: \(message)"
        case let .apiError(endpoint, statusCode, message):
            Self.apiErrorDescription(endpoint: endpoint, statusCode: statusCode, message: message)
        case let .parseFailed(endpoint, message):
            "Failed to parse Anthropic API usage \(endpoint): \(message)"
        case let .paginationLimitExceeded(endpoint):
            "Anthropic API usage \(endpoint) returned more pages than expected."
        }
    }

    /// 401/403 mean the key is not an organization Admin API credential (or was revoked).
    public var isCredentialRejected: Bool {
        switch self {
        case let .apiError(_, statusCode, _):
            statusCode == 401 || statusCode == 403
        default:
            false
        }
    }

    private static func apiErrorDescription(endpoint: String, statusCode: Int, message: String?) -> String {
        var description = "Anthropic API usage \(endpoint) error: HTTP \(statusCode)"
        if let message, !message.isEmpty {
            description += " – \(message)"
        }
        if statusCode == 401 || statusCode == 403 {
            description += ". Usage and cost reports need an organization Admin API key (sk-ant-admin…)."
        }
        return description
    }
}

/// Anthropic Usage & Cost Admin API client, shared by the Anthropic provider and Claude's Admin API source.
public enum ClaudeAdminAPIUsageFetcher {
    public static let costReportURL = URL(string: "https://api.anthropic.com/v1/organizations/cost_report")!
    public static let messagesUsageURL =
        URL(string: "https://api.anthropic.com/v1/organizations/usage_report/messages")!
    public static let organizationURL = URL(string: "https://api.anthropic.com/v1/organizations/me")!

    private static let anthropicVersion = "2023-06-01"
    private static let timeoutSeconds: TimeInterval = 20
    /// Both reports cap daily buckets at 31 per page.
    private static let maxDailyBuckets = 31
    private static let maxHistoryDays = 365
    private static let maxPagesPerRange = 20
    private static let maxErrorMessageLength = 200

    private struct RequestContext {
        let apiKey: String
        let transport: any ProviderHTTPTransport
        let retryPolicy: ProviderHTTPRetryPolicy
    }

    private struct ReportEndpoint<Response: AdminAPIPage> {
        let name: String
        let baseURL: URL
        let groupBy: String
        let decode: (Data) throws -> Response
    }

    private struct SnapshotMetadata {
        let now: Date
        let calendar: Calendar
        let historyDays: Int?
        let organizationName: String?
    }

    public static func fetchUsage(
        apiKey: String,
        costURL: URL = Self.costReportURL,
        messagesURL: URL = Self.messagesUsageURL,
        organizationURL: URL? = nil,
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date(),
        historyDays: Int = 30,
        retryPolicy: ProviderHTTPRetryPolicy = .transientIdempotent) async throws -> ClaudeAdminAPIUsageSnapshot
    {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ClaudeAdminAPIUsageError.missingCredentials
        }

        let calendar = Self.utcCalendar
        let clampedHistoryDays = max(1, min(Self.maxHistoryDays, historyDays))
        let ranges = Self.dailyRanges(now: now, calendar: calendar, historyDays: clampedHistoryDays)
        let context = RequestContext(apiKey: trimmed, transport: transport, retryPolicy: retryPolicy)

        // Sequential on purpose: both reports are required; the organization lookup is best-effort.
        var costBuckets: [CostBucket] = []
        let costEndpoint = ReportEndpoint(
            name: "cost_report", baseURL: costURL, groupBy: "description", decode: Self.decodeCosts)
        for range in ranges {
            try await costBuckets.append(contentsOf: Self.fetchAllPages(costEndpoint, range: range, context: context))
        }
        var messageBuckets: [MessagesBucket] = []
        let messagesEndpoint = ReportEndpoint(
            name: "messages", baseURL: messagesURL, groupBy: "model", decode: Self.decodeMessages)
        for range in ranges {
            try await messageBuckets.append(
                contentsOf: Self.fetchAllPages(messagesEndpoint, range: range, context: context))
        }

        var organizationName: String?
        if let organizationURL {
            organizationName = await Self.fetchOrganizationName(url: organizationURL, context: context)
        }

        return Self.makeSnapshot(
            costs: costBuckets,
            messages: messageBuckets,
            metadata: SnapshotMetadata(
                now: now,
                calendar: calendar,
                historyDays: clampedHistoryDays,
                organizationName: organizationName))
    }

    static func _parseSnapshotForTesting(
        costs: Data,
        messages: Data,
        now: Date,
        calendar: Calendar = Self.utcCalendar,
        historyDays: Int? = nil,
        organizationName: String? = nil) throws -> ClaudeAdminAPIUsageSnapshot
    {
        try self.makeSnapshot(
            costs: self.decodeCosts(costs).data,
            messages: self.decodeMessages(messages).data,
            metadata: SnapshotMetadata(
                now: now,
                calendar: calendar,
                historyDays: historyDays,
                organizationName: organizationName))
    }

    private static func fetchAllPages<Response: AdminAPIPage>(
        _ endpoint: ReportEndpoint<Response>,
        range: DateRange,
        context: RequestContext) async throws -> [Response.Bucket]
    {
        var buckets: [Response.Bucket] = []
        var page: String?
        for _ in 0..<Self.maxPagesPerRange {
            var items = [URLQueryItem(name: "group_by[]", value: endpoint.groupBy)]
            if let page { items.append(URLQueryItem(name: "page", value: page)) }
            let url = Self.url(baseURL: endpoint.baseURL, range: range, queryItems: items)
            let data = try await Self.fetchData(url: url, endpoint: endpoint.name, context: context)
            let response = try endpoint.decode(data)
            buckets.append(contentsOf: response.data)
            guard response.hasMore == true,
                  let next = response.nextPage?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !next.isEmpty,
                  next != page
            else { return buckets }
            page = next
        }
        throw ClaudeAdminAPIUsageError.paginationLimitExceeded(endpoint: endpoint.name)
    }

    private static func fetchOrganizationName(url: URL, context: RequestContext) async -> String? {
        guard let data = try? await fetchData(url: url, endpoint: "organization", context: context),
              let organization = try? JSONDecoder().decode(OrganizationResponse.self, from: data)
        else { return nil }
        return Self.nonEmpty(organization.name)
    }

    private static func fetchData(url: URL, endpoint: String, context: RequestContext) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeoutSeconds
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(context.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBar/1.0", forHTTPHeaderField: "User-Agent")

        let response: ProviderHTTPResponse
        do {
            response = try await context.transport.response(for: request, retryPolicy: context.retryPolicy)
        } catch {
            throw ClaudeAdminAPIUsageError.networkError(error.localizedDescription)
        }

        guard response.statusCode == 200 else {
            throw ClaudeAdminAPIUsageError.apiError(
                endpoint: endpoint,
                statusCode: response.statusCode,
                message: Self.errorMessage(from: response.data))
        }
        return response.data
    }

    /// Anthropic errors look like `{"type":"error","error":{"type":"…","message":"…"}}`.
    private static func errorMessage(from data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
              let message = nonEmpty(envelope.error?.message)
        else { return nil }
        return String(message.prefix(Self.maxErrorMessageLength))
    }

    private static func decodeCosts(_ data: Data) throws -> CostReportResponse {
        do {
            return try JSONDecoder().decode(CostReportResponse.self, from: data)
        } catch {
            throw ClaudeAdminAPIUsageError.parseFailed(endpoint: "cost_report", message: error.localizedDescription)
        }
    }

    private static func decodeMessages(_ data: Data) throws -> MessagesUsageResponse {
        do {
            return try JSONDecoder().decode(MessagesUsageResponse.self, from: data)
        } catch {
            throw ClaudeAdminAPIUsageError.parseFailed(endpoint: "messages", message: error.localizedDescription)
        }
    }

    private static func makeSnapshot(
        costs: [CostBucket],
        messages: [MessagesBucket],
        metadata: SnapshotMetadata) -> ClaudeAdminAPIUsageSnapshot
    {
        let calendar = metadata.calendar
        // Key by parsed UTC day rather than the raw timestamp so equivalent RFC 3339 spellings merge.
        var accumulators: [String: DailyAccumulator] = [:]

        for bucket in costs {
            guard let window = BucketWindow(bucket.startingAt, bucket.endingAt, calendar: calendar) else { continue }
            var accumulator = accumulators[window.day] ?? DailyAccumulator(window: window)
            for result in bucket.results {
                // Anthropic Usage & Cost API docs define `amount` as a decimal string in lowest USD units.
                let value = Self.usdFromAnthropicLowestUnitAmount(result.amount)
                accumulator.costUSD += value
                let item = Self.nonEmpty(result.description ?? result.costType) ?? "Claude API"
                accumulator.costItems[item, default: 0] += value
            }
            accumulators[window.day] = accumulator
        }

        for bucket in messages {
            guard let window = BucketWindow(bucket.startingAt, bucket.endingAt, calendar: calendar) else { continue }
            var accumulator = accumulators[window.day] ?? DailyAccumulator(window: window)
            for result in bucket.results {
                let input = result.uncachedInputTokens ?? 0
                let cacheCreation = result.cacheCreation?.totalInputTokens ?? 0
                let cacheRead = result.cacheReadInputTokens ?? 0
                let output = result.outputTokens ?? 0
                let total = input + cacheCreation + cacheRead + output
                accumulator.inputTokens += input
                accumulator.cacheCreationInputTokens += cacheCreation
                accumulator.cacheReadInputTokens += cacheRead
                accumulator.outputTokens += output
                accumulator.totalTokens += total
                let modelName = Self.nonEmpty(result.model) ?? "Claude API"
                accumulator.models[modelName, default: ModelAccumulator()].add(
                    inputTokens: input,
                    cacheCreationInputTokens: cacheCreation,
                    cacheReadInputTokens: cacheRead,
                    outputTokens: output,
                    totalTokens: total)
            }
            accumulators[window.day] = accumulator
        }

        let daily = accumulators.values
            .map { $0.makeBucket() }
            .filter { $0.startTime <= metadata.now }
            .sorted { $0.startTime < $1.startTime }
        return ClaudeAdminAPIUsageSnapshot(
            daily: daily,
            updatedAt: metadata.now,
            historyDays: metadata.historyDays,
            organizationName: metadata.organizationName)
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func usdFromAnthropicLowestUnitAmount(_ raw: String) -> Double {
        let cents = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return cents.isFinite ? cents / 100 : 0
    }

    private static func url(baseURL: URL, range: DateRange, queryItems extraItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "starting_at", value: Self.rfc3339String(from: range.start)),
            URLQueryItem(name: "ending_at", value: Self.rfc3339String(from: range.end)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: String(range.limit)),
        ] + extraItems
        return components.url!
    }

    /// UTC day ranges covering `historyDays` through today, chunked to the 31-bucket page limit.
    private static func dailyRanges(now: Date, calendar: Calendar, historyDays: Int) -> [DateRange] {
        let today = calendar.startOfDay(for: now)
        var cursor = calendar.date(byAdding: .day, value: -(historyDays - 1), to: today) ?? today
        var remainingDays = historyDays
        var ranges: [DateRange] = []
        while remainingDays > 0 {
            let chunkDays = min(Self.maxDailyBuckets, remainingDays)
            let end = calendar.date(byAdding: .day, value: chunkDays, to: cursor) ?? cursor
            ranges.append(DateRange(start: cursor, end: end, limit: chunkDays))
            cursor = end
            remainingDays -= chunkDays
        }
        return ranges
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func rfc3339String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    fileprivate static func dayKey(from date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    fileprivate static func parseDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }
}

private struct DateRange {
    let start: Date
    let end: Date
    let limit: Int
}

private struct BucketWindow {
    let day: String
    let start: Date
    let end: Date

    init?(_ startingAt: String, _ endingAt: String, calendar: Calendar) {
        guard let start = ClaudeAdminAPIUsageFetcher.parseDate(startingAt),
              let end = ClaudeAdminAPIUsageFetcher.parseDate(endingAt)
        else { return nil }
        self.day = ClaudeAdminAPIUsageFetcher.dayKey(from: start, calendar: calendar)
        self.start = start
        self.end = end
    }
}

private struct DailyAccumulator {
    let window: BucketWindow
    var costUSD: Double = 0
    var inputTokens: Int = 0
    var cacheCreationInputTokens: Int = 0
    var cacheReadInputTokens: Int = 0
    var outputTokens: Int = 0
    var totalTokens: Int = 0
    var costItems: [String: Double] = [:]
    var models: [String: ModelAccumulator] = [:]

    func makeBucket() -> ClaudeAdminAPIUsageSnapshot.DailyBucket {
        ClaudeAdminAPIUsageSnapshot.DailyBucket(
            day: self.window.day,
            startTime: self.window.start,
            endTime: self.window.end,
            costUSD: self.costUSD,
            inputTokens: self.inputTokens,
            cacheCreationInputTokens: self.cacheCreationInputTokens,
            cacheReadInputTokens: self.cacheReadInputTokens,
            outputTokens: self.outputTokens,
            totalTokens: self.totalTokens,
            costItems: self.costItems
                .map { ClaudeAdminAPIUsageSnapshot.CostBreakdown(name: $0.key, costUSD: $0.value) }
                .sorted {
                    if $0.costUSD == $1.costUSD { return $0.name < $1.name }
                    return $0.costUSD > $1.costUSD
                },
            models: self.models
                .map { name, total in total.makeModel(name: name) }
                .sorted {
                    if $0.totalTokens == $1.totalTokens { return $0.name < $1.name }
                    return $0.totalTokens > $1.totalTokens
                })
    }
}

private struct ModelAccumulator {
    var inputTokens = 0
    var cacheCreationInputTokens = 0
    var cacheReadInputTokens = 0
    var outputTokens = 0
    var totalTokens = 0

    mutating func add(
        inputTokens: Int,
        cacheCreationInputTokens: Int,
        cacheReadInputTokens: Int,
        outputTokens: Int,
        totalTokens: Int)
    {
        self.inputTokens += inputTokens
        self.cacheCreationInputTokens += cacheCreationInputTokens
        self.cacheReadInputTokens += cacheReadInputTokens
        self.outputTokens += outputTokens
        self.totalTokens += totalTokens
    }

    func makeModel(name: String) -> ClaudeAdminAPIUsageSnapshot.ModelBreakdown {
        ClaudeAdminAPIUsageSnapshot.ModelBreakdown(
            name: name,
            inputTokens: self.inputTokens,
            cacheCreationInputTokens: self.cacheCreationInputTokens,
            cacheReadInputTokens: self.cacheReadInputTokens,
            outputTokens: self.outputTokens,
            totalTokens: self.totalTokens)
    }
}

private protocol AdminAPIPage: Decodable {
    associatedtype Bucket: Decodable
    var data: [Bucket] { get }
    var hasMore: Bool? { get }
    var nextPage: String? { get }
}

private struct CostReportResponse: AdminAPIPage {
    let data: [CostBucket]
    let hasMore: Bool?
    let nextPage: String?

    private enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

private struct CostBucket: Decodable {
    let startingAt: String
    let endingAt: String
    let results: [CostResult]

    private enum CodingKeys: String, CodingKey {
        case startingAt = "starting_at"
        case endingAt = "ending_at"
        case results
    }
}

private struct CostResult: Decodable {
    let currency: String?
    let amount: String
    let description: String?
    let costType: String?

    private enum CodingKeys: String, CodingKey {
        case currency
        case amount
        case description
        case costType = "cost_type"
    }
}

private struct MessagesUsageResponse: AdminAPIPage {
    let data: [MessagesBucket]
    let hasMore: Bool?
    let nextPage: String?

    private enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

private struct MessagesBucket: Decodable {
    let startingAt: String
    let endingAt: String
    let results: [MessagesResult]

    private enum CodingKeys: String, CodingKey {
        case startingAt = "starting_at"
        case endingAt = "ending_at"
        case results
    }
}

private struct MessagesResult: Decodable {
    let uncachedInputTokens: Int?
    let cacheCreation: CacheCreation?
    let cacheReadInputTokens: Int?
    let outputTokens: Int?
    let model: String?

    private enum CodingKeys: String, CodingKey {
        case uncachedInputTokens = "uncached_input_tokens"
        case cacheCreation = "cache_creation"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case outputTokens = "output_tokens"
        case model
    }
}

private struct CacheCreation: Decodable {
    let ephemeral1HInputTokens: Int?
    let ephemeral5MInputTokens: Int?

    var totalInputTokens: Int {
        (self.ephemeral1HInputTokens ?? 0) + (self.ephemeral5MInputTokens ?? 0)
    }

    private enum CodingKeys: String, CodingKey {
        case ephemeral1HInputTokens = "ephemeral_1h_input_tokens"
        case ephemeral5MInputTokens = "ephemeral_5m_input_tokens"
    }
}

private struct OrganizationResponse: Decodable {
    let name: String?
}

private struct ErrorEnvelope: Decodable {
    struct Detail: Decodable {
        let message: String?
    }

    let error: Detail?
}
