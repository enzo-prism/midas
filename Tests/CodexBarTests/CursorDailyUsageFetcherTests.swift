import Foundation
import Testing
@testable import CodexBarCore

struct CursorDailyUsageFetcherTests {
    /// 2026-11-12T12:00:00Z; the week began 2026-11-10T06:00:00Z.
    private static let now = ISO8601DateFormatter().date(from: "2026-11-12T12:00:00Z")!
    private static let since = ISO8601DateFormatter().date(from: "2026-11-09T00:00:00Z")!

    private static let status = """
    {"availability":"available",
     "monthlyUsage":{"usedCents":321},
     "weeklyIncludedUsage":{"usedCents":1200,"budgetCents":55395,
       "periodStart":"2026-11-10T06:00:00.000Z","resetsAt":"2026-11-17T06:00:00.000Z"}}
    """

    /// Included tokens: Nov 9 = 9M (before the week), Nov 10 = 4M (week began at 06:00, so 3M count),
    /// Nov 11 = 2M, Nov 12 = 1M. Week total 6M for $12.00, so $2 per million.
    private static let daily = """
    {"availability":"available","series":[
      {"dimensions":{"product":"cursor"},"points":[
        {"dayStartTime":"2026-11-09T00:00:00.000Z","contractedCost":"1.5000000000",
         "tokens":10000000,"includedTokens":9000000},
        {"dayStartTime":"2026-11-10T00:00:00.000Z","contractedCost":"0.0000000000",
         "tokens":4000000,"includedTokens":4000000},
        {"dayStartTime":"2026-11-11T00:00:00.000Z","contractedCost":"0.0000000000",
         "tokens":0,"includedTokens":0}]},
      {"dimensions":{"product":"grok-bot"},"points":[
        {"dayStartTime":"2026-11-11T00:00:00.000Z","contractedCost":"0.2500000000",
         "tokens":2500000,"includedTokens":2000000},
        {"dayStartTime":"2026-11-12T00:00:00.000Z","contractedCost":0,
         "tokens":1000000,"includedTokens":1000000}]}],
     "other":{"points":[
        {"dayStartTime":"2026-11-12T00:00:00.000Z","contractedCost":"0","tokens":0,"includedTokens":0}]}}
    """

    private static func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("midas-cursor-rate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func transport(
        status: (code: Int, body: String),
        daily: (code: Int, body: String) = (200, Self.daily)) -> ProviderHTTPTransportHandler
    {
        ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let reply = url.path.hasSuffix("/v2/usage-status") ? status : daily
            if url.path.hasSuffix("/v2/query-daily-usage") {
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Origin") == "https://cursor.com")
            }
            #expect(request.value(forHTTPHeaderField: "Cookie") == "session=test")
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: reply.code, httpVersion: nil, headerFields: nil))
            return (Data(reply.body.utf8), response)
        }
    }

    @Test
    func `included rate counts only the part of the first day after the week began`() throws {
        let status = try Self.decode(CursorUsageStatusV2.self, Self.status)
        let daily = try Self.decode(CursorDailyUsageResponse.self, Self.daily)

        let rate = try #require(CursorDailyUsageFetcher.includedRateUSDPerToken(
            status: status, daily: daily, now: Self.now))
        #expect(abs(rate - 2e-6) < 1e-12)
    }

    @Test
    func `days are valued at billed cost plus included tokens at the weekly rate`() throws {
        let daily = try Self.decode(CursorDailyUsageResponse.self, Self.daily)
        let result = CursorDailyUsageFetcher.makeResult(daily: daily, includedRateUSDPerToken: 2e-6)

        #expect(result.daily.data.map(\.date) == ["2026-11-09", "2026-11-10", "2026-11-11", "2026-11-12"])
        #expect(result.daily.data.map(\.totalTokens) == [10_000_000, 4_000_000, 2_500_000, 1_000_000])
        let costs = result.daily.data.compactMap(\.costUSD)
        // Nov 9: $1.50 billed + 9M included; Nov 11: $0.25 billed + 2M included.
        #expect(zip(costs, [19.5, 8, 4.25, 2]).allSatisfy { abs($0 - $1) < 1e-9 })
        #expect(result.daily.data[2].modelBreakdowns?.map(\.modelName) == ["grok-bot"])
        #expect(abs((result.daily.summary?.totalCostUSD ?? 0) - 33.75) < 1e-9)
        // The vendor-metered figure is only what Cursor billed.
        #expect(abs((result.meteredCostUSD ?? 0) - 1.75) < 1e-9)
    }

    @Test
    func `without a rate, included usage has no dollar value instead of an understated one`() throws {
        let daily = try Self.decode(CursorDailyUsageResponse.self, Self.daily)
        let result = CursorDailyUsageFetcher.makeResult(daily: daily, includedRateUSDPerToken: nil)

        #expect(result.daily.data.allSatisfy { $0.costUSD == nil })
        #expect(result.daily.summary?.totalCostUSD == nil)
        #expect(result.daily.summary?.totalTokens == 17_500_000)
    }

    @Test
    func `a quiet new week falls back to the last observed rate`() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fetcher = CursorDailyUsageFetcher(
            transport: Self.transport(status: (200, Self.status)),
            rateCacheRoot: root)
        let first = try #require(try await fetcher.fetchUsage(
            cookieHeader: "session=test", since: Self.since, until: Self.now, now: Self.now))
        #expect(abs((first.daily.summary?.totalCostUSD ?? 0) - 33.75) < 1e-9)

        // Just after a reset the week has almost no usage, so no rate can be derived from it.
        let quiet = Self.status.replacingOccurrences(of: #""usedCents":1200"#, with: #""usedCents":3"#)
        let later = CursorDailyUsageFetcher(transport: Self.transport(status: (200, quiet)), rateCacheRoot: root)
        let second = try #require(try await later.fetchUsage(
            cookieHeader: "session=test", since: Self.since, until: Self.now, now: Self.now))
        #expect(abs((second.daily.summary?.totalCostUSD ?? 0) - 33.75) < 1e-9)

        #expect(CursorIncludedRateCache.load(now: Self.now.addingTimeInterval(30 * 86400), cacheRoot: root) == nil)
    }

    @Test
    func `accounts the v2 feed does not serve fall back to usage events`() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = #"{"availability":"available","monthlyUsage":{"usedCents":0}}"#
        for status in [(200, legacy), (404, "{}"), (500, "oops"), (200, "not json")] {
            let fetcher = CursorDailyUsageFetcher(transport: Self.transport(status: status), rateCacheRoot: root)
            let result = try await fetcher.fetchUsage(
                cookieHeader: "session=test", since: Self.since, until: Self.now, now: Self.now)
            #expect(result == nil)
        }
    }

    @Test
    func `a failed daily window is retried, and an unreadable one is an error not a fallback`() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let attempts = Counter()
        let flaky = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let isDaily = url.path.hasSuffix("/v2/query-daily-usage")
            let failing = isDaily ? await attempts.next() < 3 : false
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: failing ? 500 : 200, httpVersion: nil, headerFields: nil))
            let body = failing ? #"{"code":"internal"}"# : (isDaily ? Self.daily : Self.status)
            return (Data(body.utf8), response)
        }
        var fetcher = CursorDailyUsageFetcher(transport: flaky, rateCacheRoot: root)
        fetcher.retryDelay = 0
        let result = try #require(try await fetcher.fetchUsage(
            cookieHeader: "session=test", since: Self.since, until: Self.now, now: Self.now))
        #expect(await attempts.value == 3)
        #expect(abs((result.daily.summary?.totalCostUSD ?? 0) - 33.75) < 1e-9)

        // A unified account never falls back to the usage-events list, which is no longer written to.
        var broken = CursorDailyUsageFetcher(
            transport: Self.transport(status: (200, Self.status), daily: (500, "{}")),
            rateCacheRoot: root)
        broken.retryDelay = 0
        await #expect(throws: CursorStatusProbeError.self) {
            try await broken.fetchUsage(
                cookieHeader: "session=test", since: Self.since, until: Self.now, now: Self.now)
        }
    }

    @Test
    func `long history is read in windows Cursor accepts and stops at empty ones`() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let windows = WindowLog()
        let empty = #"{"availability":"available","series":[]}"#
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            var body = Self.status
            if url.path.hasSuffix("/v2/query-daily-usage") {
                let sent = try #require(request.httpBody)
                let json = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
                let start = try #require(json["startTime"] as? String)
                let end = try #require(json["endTime"] as? String)
                await windows.append(start: start, end: end)
                #expect(json["scope"] as? String == "user")
                #expect(json["groupBy"] as? [String] == ["product"])
                // Only the newest window has usage.
                body = end.hasPrefix("2026-11-13") ? Self.daily : empty
            }
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(body.utf8), response)
        }
        let fetcher = CursorDailyUsageFetcher(transport: transport, rateCacheRoot: root)
        let result = try #require(try await fetcher.fetchUsage(
            cookieHeader: "session=test", since: nil, until: Self.now, now: Self.now))

        let spans = await windows.spans
        // Newest first, 30 days each, and no further back once two windows are empty.
        #expect(spans.map(\.end).first?.hasPrefix("2026-11-13") == true)
        #expect(spans.count == 3)
        #expect(spans.allSatisfy { $0.days <= 31 })
        #expect(result.daily.summary?.totalTokens == 17_500_000)
    }

    @Test
    func `a rejected sign-in is reported, not treated as a legacy plan`() async throws {
        let fetcher = CursorDailyUsageFetcher(transport: Self.transport(status: (401, "{}")))
        await #expect(throws: CursorStatusProbeError.self) {
            try await fetcher.fetchUsage(
                cookieHeader: "session=test",
                since: Self.since,
                until: Self.now,
                now: Self.now)
        }
    }
}

private actor Counter {
    private(set) var value = 0

    func next() -> Int {
        self.value += 1
        return self.value
    }
}

private actor WindowLog {
    struct Span {
        let start: String
        let end: String

        var days: Int {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let from = formatter.date(from: self.start),
                  let to = formatter.date(from: self.end) else { return 999 }
            return Int((to.timeIntervalSince(from) / 86400).rounded())
        }
    }

    private(set) var spans: [Span] = []

    func append(start: String, end: String) {
        self.spans.append(Span(start: start, end: end))
    }
}

extension CursorCostFetchResult: Equatable {
    public static func == (lhs: CursorCostFetchResult, rhs: CursorCostFetchResult) -> Bool {
        lhs.daily.data == rhs.daily.data && lhs.meteredCostUSD == rhs.meteredCostUSD
    }
}
