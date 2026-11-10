import Foundation

/// Cursor's unified plans (2026-10-12) stopped writing to `get-filtered-usage-events`; the dashboard
/// reads these v2 endpoints instead:
///
/// - `GET /api/dashboard/v2/usage-status?scope=user`: the current week's included usage in cents and
///   this month's billed additional usage.
/// - `POST /api/dashboard/v2/query-daily-usage`: per UTC day and product, total tokens, plan-included
///   tokens, and the billed (`contractedCost`) amount.
///
/// Included usage has a dollar value only for the current week. Past days are therefore valued with
/// the current week's value per included token; see `includedRateUSDPerToken`.
struct CursorUsageStatusV2: Decodable, Sendable, Equatable {
    struct WeeklyIncludedUsage: Decodable, Sendable, Equatable {
        let usedCents: Double?
        let budgetCents: Double?
        let periodStart: Date?
        let resetsAt: Date?

        private enum CodingKeys: String, CodingKey {
            case usedCents
            case budgetCents
            case periodStart
            case resetsAt
        }

        init(usedCents: Double?, budgetCents: Double? = nil, periodStart: Date?, resetsAt: Date? = nil) {
            self.usedCents = usedCents
            self.budgetCents = budgetCents
            self.periodStart = periodStart
            self.resetsAt = resetsAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.usedCents = CursorV2Number.double(container, .usedCents)
            self.budgetCents = CursorV2Number.double(container, .budgetCents)
            self.periodStart = CursorV2Number.date(container, .periodStart)
            self.resetsAt = CursorV2Number.date(container, .resetsAt)
        }
    }

    let availability: String?
    let weeklyIncludedUsage: WeeklyIncludedUsage?
}

struct CursorDailyUsageResponse: Decodable, Sendable {
    struct Series: Decodable, Sendable {
        struct Dimensions: Decodable, Sendable {
            let product: String?
        }

        let dimensions: Dimensions?
        let points: [Point]?

        init(product: String?, points: [Point]) {
            self.dimensions = Dimensions(product: product)
            self.points = points
        }
    }

    struct Point: Decodable, Sendable {
        let dayStartTime: Date?
        let contractedCost: Double?
        let tokens: Int?
        let includedTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case dayStartTime
            case contractedCost
            case tokens
            case includedTokens
        }

        init(dayStartTime: Date?, contractedCost: Double?, tokens: Int?, includedTokens: Int?) {
            self.dayStartTime = dayStartTime
            self.contractedCost = contractedCost
            self.tokens = tokens
            self.includedTokens = includedTokens
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.dayStartTime = CursorV2Number.date(container, .dayStartTime)
            self.contractedCost = CursorV2Number.double(container, .contractedCost)
            self.tokens = CursorV2Number.double(container, .tokens).flatMap(Int.init(exactly:))
            self.includedTokens = CursorV2Number.double(container, .includedTokens).flatMap(Int.init(exactly:))
        }
    }

    let availability: String?
    let series: [Series]?
    /// Products beyond `topN`, already summed by Cursor.
    let other: Series?

    var hasUsage: Bool {
        ((self.series ?? []) + [self.other].compactMap(\.self))
            .contains { ($0.points ?? []).contains { ($0.tokens ?? 0) > 0 || ($0.contractedCost ?? 0) > 0 } }
    }

    /// One response covering several windows; Cursor serves at most 31 days per request.
    static func merging(_ responses: [CursorDailyUsageResponse]) -> CursorDailyUsageResponse {
        var byProduct: [String: [Point]] = [:]
        var order: [String] = []
        var other: [Point] = []
        for response in responses {
            for series in response.series ?? [] {
                let name = series.dimensions?.product ?? "cursor"
                if byProduct[name] == nil { order.append(name) }
                byProduct[name, default: []].append(contentsOf: series.points ?? [])
            }
            other.append(contentsOf: response.other?.points ?? [])
        }
        return CursorDailyUsageResponse(
            availability: "available",
            series: order.map { Series(product: $0, points: byProduct[$0] ?? []) },
            other: other.isEmpty ? nil : Series(product: nil, points: other))
    }
}

/// Lenient decoding: Cursor serializes money as decimal strings and may switch number forms.
private enum CursorV2Number {
    static func double<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value.isFinite ? value : nil
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key),
           let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite
        {
            return value
        }
        return nil
    }

    static func date<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Date? {
        guard let text = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// Last usable value-per-included-token, so the estimate survives the hours after a weekly reset when
/// the new week has too little usage to derive a rate from.
enum CursorIncludedRateCache {
    static let fileName = "cursor-included-rate-v1.json"
    static let maxAge: TimeInterval = 21 * 24 * 60 * 60

    private struct Stored: Codable {
        let usdPerToken: Double
        let observedAt: Date
    }

    static func fileURL(cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(MidasIdentity.supportDirectoryName, isDirectory: true)
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent(self.fileName, isDirectory: false)
    }

    static func load(now: Date = Date(), cacheRoot: URL? = nil) -> Double? {
        guard let data = try? Data(contentsOf: self.fileURL(cacheRoot: cacheRoot)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              now.timeIntervalSince(stored.observedAt) <= self.maxAge,
              CursorDailyUsageFetcher.isPlausibleRate(stored.usdPerToken)
        else { return nil }
        return stored.usdPerToken
    }

    static func save(_ usdPerToken: Double, now: Date = Date(), cacheRoot: URL? = nil) {
        let url = self.fileURL(cacheRoot: cacheRoot)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Stored(usdPerToken: usdPerToken, observedAt: now)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

struct CursorDailyUsageFetcher: Sendable {
    let baseURL: URL
    let transport: any ProviderHTTPTransport
    var timeout: TimeInterval
    /// Where the fallback rate is kept; nil uses the Midas cache folder.
    var rateCacheRoot: URL?
    /// Cursor's daily query fails intermittently with a 500 while it computes an uncached window.
    var attemptsPerWindow = 3
    var retryDelay: TimeInterval = 2

    /// Cursor rejects windows longer than 31 days.
    static let windowDays = 30
    /// Stop reading older history after this many windows with no usage.
    static let emptyWindowsBeforeStopping = 2

    /// A week needs this much included usage before its value per token is trusted.
    static let minimumRateTokens = 1_000_000
    static let minimumRateCents = 25.0

    init(
        baseURL: URL = URL(string: "https://cursor.com")!,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        timeout: TimeInterval = 30,
        rateCacheRoot: URL? = nil)
    {
        self.baseURL = baseURL
        self.transport = transport
        self.timeout = timeout
        self.rateCacheRoot = rateCacheRoot
    }

    /// The v2 report, or nil when this account is not served by the v2 feed (legacy plans), so the
    /// caller keeps using usage events. Sign-in failures are thrown.
    func fetchUsage(
        cookieHeader: String,
        since: Date?,
        until: Date?,
        now: Date = Date(),
        logger: ((String) -> Void)? = nil) async throws -> CursorCostFetchResult?
    {
        guard let status = try await self.fetchStatus(cookieHeader: cookieHeader),
              status.availability == "available",
              status.weeklyIncludedUsage != nil
        else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: until ?? now)) ?? now
        let fallbackStart = calendar.date(byAdding: .day, value: -364, to: end) ?? end
        let start = calendar.startOfDay(for: since ?? fallbackStart)
        // This account is served by the v2 feed, so its usage-events list is no longer written to.
        // A failed read must surface as an error (keeping the last good figure) and never fall back
        // to that list, which would report almost nothing.
        let daily = try await self.fetchDailyWindows(
            cookieHeader: cookieHeader,
            start: start,
            end: end,
            calendar: calendar)

        let observedRate = Self.includedRateUSDPerToken(status: status, daily: daily, now: now)
        if let observedRate {
            CursorIncludedRateCache.save(observedRate, now: now, cacheRoot: self.rateCacheRoot)
        }
        let rate = observedRate ?? CursorIncludedRateCache.load(now: now, cacheRoot: self.rateCacheRoot)
        logger?("[cursor-cost] v2 daily usage; included rate \(rate == nil ? "unavailable" : "available")")
        return Self.makeResult(daily: daily, includedRateUSDPerToken: rate)
    }

    // MARK: Requests

    private func fetchStatus(cookieHeader: String) async throws -> CursorUsageStatusV2? {
        var components = URLComponents(
            url: self.baseURL.appendingPathComponent("/api/dashboard/v2/usage-status"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "scope", value: "user")]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        return try await self.decode(CursorUsageStatusV2.self, request: request)
    }

    private struct DailyUsageRequest: Encodable {
        let scope = "user"
        let startTime: String
        let endTime: String
        let groupBy = ["product"]
        let filters: [String: String] = [:]
        let topN = 20
    }

    /// Reads `start..<end` newest first in windows Cursor accepts, retrying each window, and stops
    /// once older windows are empty.
    private func fetchDailyWindows(
        cookieHeader: String,
        start: Date,
        end: Date,
        calendar: Calendar) async throws -> CursorDailyUsageResponse
    {
        var responses: [CursorDailyUsageResponse] = []
        var windowEnd = end
        var emptyWindows = 0
        while windowEnd > start, emptyWindows < Self.emptyWindowsBeforeStopping {
            let proposed = calendar.date(byAdding: .day, value: -Self.windowDays, to: windowEnd) ?? start
            let windowStart = max(start, proposed)
            var response: CursorDailyUsageResponse?
            for attempt in 0..<max(1, self.attemptsPerWindow) {
                if attempt > 0, self.retryDelay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(self.retryDelay * Double(attempt) * 1_000_000_000))
                }
                response = try await self.fetchDaily(cookieHeader: cookieHeader, start: windowStart, end: windowEnd)
                if response?.availability == "available" { break }
                response = nil
            }
            guard let response else {
                throw CursorStatusProbeError.networkError("Cursor daily usage is temporarily unavailable")
            }
            emptyWindows = response.hasUsage ? 0 : emptyWindows + 1
            responses.append(response)
            windowEnd = windowStart
        }
        return CursorDailyUsageResponse.merging(responses)
    }

    private func fetchDaily(cookieHeader: String, start: Date, end: Date) async throws -> CursorDailyUsageResponse? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var request = URLRequest(url: self.baseURL.appendingPathComponent("/api/dashboard/v2/query-daily-usage"))
        request.httpMethod = "POST"
        request.timeoutInterval = self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        // Cursor enforces CSRF on dashboard POST endpoints: a matching Origin is required.
        if let scheme = self.baseURL.scheme, let host = self.baseURL.host {
            request.setValue("\(scheme)://\(host)", forHTTPHeaderField: "Origin")
        }
        request.httpBody = try JSONEncoder().encode(DailyUsageRequest(
            startTime: formatter.string(from: start),
            endTime: formatter.string(from: end)))
        return try await self.decode(CursorDailyUsageResponse.self, request: request)
    }

    /// Nil for any response that is not a decodable 200, except a rejected sign-in, which is thrown.
    private func decode<Value: Decodable>(_: Value.Type, request: URLRequest) async throws -> Value? {
        let (data, response) = try await self.transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 401 { throw CursorStatusProbeError.notLoggedIn }
        guard http.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    // MARK: Valuation

    static func isPlausibleRate(_ usdPerToken: Double) -> Bool {
        // Between $0.001 and $200 per million tokens.
        usdPerToken.isFinite && usdPerToken > 1e-9 && usdPerToken < 2e-4
    }

    /// Dollar value per plan-included token in the current week: Cursor's own weekly included value
    /// divided by the included tokens since the week began. The daily feed is per UTC day, so the day
    /// the week started counts only for the share of it after the start time.
    static func includedRateUSDPerToken(
        status: CursorUsageStatusV2,
        daily: CursorDailyUsageResponse,
        now: Date = Date()) -> Double?
    {
        guard let weekly = status.weeklyIncludedUsage,
              let usedCents = weekly.usedCents, usedCents >= self.minimumRateCents,
              let periodStart = weekly.periodStart, periodStart <= now
        else { return nil }
        let day: TimeInterval = 24 * 60 * 60
        var includedTokens = 0.0
        for point in self.allPoints(daily) {
            guard let dayStart = point.dayStartTime, let tokens = point.includedTokens, tokens > 0 else { continue }
            let dayEnd = dayStart.addingTimeInterval(day)
            guard dayEnd > periodStart, dayStart <= now else { continue }
            if dayStart >= periodStart {
                includedTokens += Double(tokens)
            } else {
                // Elapsed part of the day so far, when the week started today.
                let observedEnd = min(dayEnd, now)
                let span = observedEnd.timeIntervalSince(dayStart)
                guard span > 0 else { continue }
                let share = observedEnd.timeIntervalSince(periodStart) / span
                includedTokens += Double(tokens) * min(1, max(0, share))
            }
        }
        guard includedTokens >= Double(self.minimumRateTokens) else { return nil }
        let rate = (usedCents / 100) / includedTokens
        return self.isPlausibleRate(rate) ? rate : nil
    }

    private static func allPoints(_ daily: CursorDailyUsageResponse) -> [CursorDailyUsageResponse.Point] {
        ((daily.series ?? []) + [daily.other].compactMap(\.self)).flatMap { $0.points ?? [] }
    }

    /// Per-day entries with one breakdown row per product. Cost is the billed amount plus the
    /// estimated value of included tokens; without a rate, days with included usage have no cost so
    /// totals show as partial instead of understating.
    static func makeResult(
        daily: CursorDailyUsageResponse,
        includedRateUSDPerToken rate: Double?) -> CursorCostFetchResult
    {
        struct ProductDay {
            var tokens = 0
            var includedTokens = 0
            var billedUSD = 0.0
        }

        var days: [String: [String: ProductDay]] = [:]
        var billedTotal = 0.0
        let namedSeries = (daily.series ?? []).map { (name: $0.dimensions?.product ?? "cursor", series: $0) }
        let otherSeries = daily.other.map { [(name: "other", series: $0)] } ?? []
        for entry in namedSeries + otherSeries {
            for point in entry.series.points ?? [] {
                guard let dayStart = point.dayStartTime else { continue }
                let tokens = max(0, point.tokens ?? 0)
                let billed = max(0, point.contractedCost ?? 0)
                guard tokens > 0 || billed > 0 else { continue }
                let key = self.dayKey(dayStart)
                var product = days[key]?[entry.name] ?? ProductDay()
                product.tokens += tokens
                product.includedTokens += min(tokens, max(0, point.includedTokens ?? 0))
                product.billedUSD += billed
                days[key, default: [:]][entry.name] = product
                billedTotal += billed
            }
        }

        func cost(_ product: ProductDay) -> Double? {
            guard product.includedTokens > 0 else { return product.billedUSD }
            guard let rate else { return nil }
            return product.billedUSD + Double(product.includedTokens) * rate
        }

        let entries = days.keys.sorted().map { key -> CostUsageDailyReport.Entry in
            let products = days[key] ?? [:]
            let costs = products.mapValues(cost)
            let dayCost: Double? = costs.values.contains { $0 == nil }
                ? nil : costs.values.compactMap(\.self).reduce(0, +)
            let breakdowns = products.keys.sorted().map { name in
                CostUsageDailyReport.ModelBreakdown(
                    modelName: name,
                    costUSD: costs[name].flatMap(\.self),
                    totalTokens: products[name]?.tokens,
                    requestCount: nil,
                    inputTokens: nil,
                    outputTokens: nil,
                    cacheReadTokens: nil,
                    cacheCreationTokens: nil)
            }
            return CostUsageDailyReport.Entry(
                date: key,
                inputTokens: nil,
                outputTokens: nil,
                cacheReadTokens: nil,
                cacheCreationTokens: nil,
                totalTokens: products.values.reduce(0) { $0 + $1.tokens },
                requestCount: nil,
                costUSD: dayCost,
                modelsUsed: products.keys.sorted(),
                modelBreakdowns: breakdowns,
                unpricedRequestCount: nil,
                unmeteredRequestCount: nil,
                estimatedRequestCount: nil,
                pricedRequestCount: nil)
        }

        let totalCost: Double? = entries.contains { $0.costUSD == nil }
            ? nil : entries.compactMap(\.costUSD).reduce(0, +)
        let summary = CostUsageDailyReport.Summary(
            totalInputTokens: nil,
            totalOutputTokens: nil,
            cacheReadTokens: nil,
            cacheCreationTokens: nil,
            totalTokens: entries.reduce(0) { $0 + ($1.totalTokens ?? 0) },
            totalCostUSD: totalCost)
        return CursorCostFetchResult(
            daily: CostUsageDailyReport(data: entries, summary: summary),
            meteredCostUSD: billedTotal)
    }

    private static func dayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return CostUsageLocalDay.key(from: date, calendar: calendar)
    }
}
