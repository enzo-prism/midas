import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CursorUsageEventsFetcherTests {
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func event(
        timestampMS: Int64? = 1_719_792_000_000,
        model: String? = "gpt-4o",
        input: Int = 100,
        output: Int = 50,
        cacheWrite: Int = 10,
        cacheRead: Int = 20,
        totalCents: Double? = 12.5,
        invalidCents: Bool = false,
        chargedCents: Double? = 25.0) -> CursorUsageEvent
    {
        CursorUsageEvent(
            timestampMS: timestampMS,
            model: model,
            tokenUsage: CursorEventTokenUsage(
                inputTokens: input,
                outputTokens: output,
                cacheWriteTokens: cacheWrite,
                cacheReadTokens: cacheRead,
                totalCents: totalCents,
                isTotalCentsInvalid: invalidCents),
            chargedCents: chargedCents)
    }

    // MARK: - Metered total

    @Test
    func `meteredCostUSD sums charged cents across events`() {
        let events = [
            Self.event(chargedCents: 25.0),
            Self.event(timestampMS: 1_719_795_600_000, chargedCents: 27.0),
        ]
        #expect(CursorUsageEventsFetcher.meteredCostUSD(from: events) == 0.52)
    }

    @Test
    func `meteredCostUSD rejects a partial sum when an event omits chargedCents`() {
        let events = [
            Self.event(chargedCents: 25.0),
            Self.event(timestampMS: 1_719_795_600_000, chargedCents: nil),
        ]
        #expect(CursorUsageEventsFetcher.meteredCostUSD(from: events) == nil)
    }

    @Test
    func `meteredCostUSD returns nil without valid events`() {
        #expect(CursorUsageEventsFetcher.meteredCostUSD(from: []) == nil)
        #expect(CursorUsageEventsFetcher.meteredCostUSD(from: [Self.event(timestampMS: nil)]) == nil)
        #expect(CursorUsageEventsFetcher.meteredCostUSD(from: [Self.event(timestampMS: -1)]) == nil)
    }

    @Test
    func `meteredCostUSD returns nil for negative chargedCents`() {
        #expect(CursorUsageEventsFetcher.meteredCostUSD(from: [Self.event(chargedCents: -5.0)]) == nil)
    }

    // MARK: - Daily per-model report

    @Test
    func `makeDailyReport groups per-day per-model list-price costs`() throws {
        let events = [
            Self.event(model: "gpt-4o"),
            Self.event(
                timestampMS: 1_719_795_600_000,
                model: "claude-4-sonnet",
                input: 200,
                output: 100,
                cacheWrite: 0,
                cacheRead: 0,
                totalCents: 30.0,
                chargedCents: 40.0),
        ]
        let report = CursorUsageEventsFetcher.makeDailyReport(from: events, calendar: Self.utcCalendar)

        #expect(report.data.count == 1)
        let entry = try #require(report.data.first)
        #expect(entry.date == "2024-07-01")
        #expect(entry.costUSD == 0.425)
        #expect(entry.totalTokens == 480)
        #expect(entry.requestCount == 2)
        #expect(entry.modelsUsed == ["claude-4-sonnet", "gpt-4o"])
        #expect(entry.pricedRequestCount == 2)
        #expect(entry.unpricedRequestCount == nil)
        #expect(entry.estimatedRequestCount == nil)

        let breakdowns = try #require(entry.modelBreakdowns)
        #expect(breakdowns.count == 2)
        // Sorted by cost descending.
        #expect(breakdowns[0].modelName == "claude-4-sonnet")
        #expect(breakdowns[0].costUSD == 0.30)
        #expect(breakdowns[0].totalTokens == 300)
        #expect(breakdowns[1].modelName == "gpt-4o")
        #expect(breakdowns[1].costUSD == 0.125)
        #expect(breakdowns[1].totalTokens == 180)
        // Token classes are preserved per model; cacheWrite maps to cache creation.
        #expect(breakdowns[1].inputTokens == 100)
        #expect(breakdowns[1].outputTokens == 50)
        #expect(breakdowns[1].cacheReadTokens == 20)
        #expect(breakdowns[1].cacheCreationTokens == 10)
    }

    @Test
    func `makeDailyReport skips events without tokens`() {
        let events = [
            Self.event(input: 0, output: 0, cacheWrite: 0, cacheRead: 0, totalCents: 5.0),
            Self.event(timestampMS: nil, totalCents: 5.0),
        ]
        let report = CursorUsageEventsFetcher.makeDailyReport(from: events, calendar: Self.utcCalendar)
        #expect(report.data.isEmpty)
        // Metered spend still counts timestamped events even when the token row is skipped.
        #expect(CursorUsageEventsFetcher.meteredCostUSD(from: events) == 0.25)
    }

    @Test
    func `makeDailyReport marks omitted-cost unknown models unpriced`() throws {
        let events = [Self.event(model: "some-future-model-xyz", totalCents: nil, chargedCents: nil)]
        let report = CursorUsageEventsFetcher.makeDailyReport(
            from: events,
            calendar: Self.utcCalendar,
            modelsDevCatalog: ModelsDevCatalog(providers: [:]))
        let entry = try #require(report.data.first)
        #expect(entry.costUSD == nil)
        #expect(entry.unpricedRequestCount == 1)
        #expect(entry.pricedRequestCount == nil)
        #expect(entry.estimatedRequestCount == nil)
        #expect(CursorUsageEventsFetcher.meteredCostUSD(from: events) == nil)
    }

    @Test
    func `makeDailyReport fails closed on invalid cost but keeps priced count`() throws {
        let events = [
            Self.event(totalCents: 12.5),
            Self.event(timestampMS: 1_719_795_600_000, totalCents: nil, invalidCents: true),
        ]
        let report = CursorUsageEventsFetcher.makeDailyReport(from: events, calendar: Self.utcCalendar)
        let entry = try #require(report.data.first)
        #expect(entry.costUSD == nil)
        #expect(entry.pricedRequestCount == 1)
        #expect(entry.unpricedRequestCount == 1)
        #expect(entry.coverageCounts == CostUsageCoverageCounts(priced: 1, unpriced: 1))
    }

    @Test
    func `makeDailyReport buckets unknown model names`() {
        let events = [Self.event(model: nil)]
        let report = CursorUsageEventsFetcher.makeDailyReport(from: events, calendar: Self.utcCalendar)
        #expect(report.data.first?.modelsUsed == ["unknown"])
    }

    // MARK: - Pagination

    private static func pageData(total: Int?, eventsJSON: String) -> Data {
        let totalValue = total.map(String.init) ?? "null"
        return Data("{\"totalUsageEventsCount\":\(totalValue),\"usageEventsDisplay\":[\(eventsJSON)]}".utf8)
    }

    private static func eventJSON(
        timestampMS: String = "\"1719792000000\"",
        model: String = "gpt-4o",
        totalCents: Double = 12.5,
        chargedCents: Double = 25.0) -> String
    {
        """
        {"timestamp":\(timestampMS),"model":"\(model)",\
        "tokenUsage":{"inputTokens":100,"outputTokens":50,"cacheWriteTokens":10,"cacheReadTokens":20,\
        "totalCents":\(totalCents)},"chargedCents":\(chargedCents)}
        """
    }

    private static func ok(_ data: Data) -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: URL(string: "https://cursor.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil)!
        return (data, response)
    }

    @Test
    func `fetchUsage collects pages until a short page`() async throws {
        let page1 = Self.pageData(
            total: 2,
            eventsJSON: "\(Self.eventJSON()),\(Self.eventJSON(timestampMS: "\"1719795600000\""))")
        let page2 = Self.pageData(total: 2, eventsJSON: "")
        let stub = ProviderHTTPTransportStub { request in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            return Self.ok(body.contains("\"page\":1") ? page1 : page2)
        }
        let fetcher = CursorUsageEventsFetcher(transport: stub, pageSize: 2)
        let result = try await fetcher.fetchUsage(
            cookieHeader: "a=b",
            since: nil,
            until: nil,
            calendar: Self.utcCalendar)

        #expect(result.daily.data.count == 1)
        #expect(result.daily.data.first?.costUSD == 0.25)
        #expect(result.meteredCostUSD == 0.50)
    }

    @Test
    func `fetchUsage throws incomplete at the pagination cap`() async {
        let page = Self.pageData(total: 5, eventsJSON: Self.eventJSON())
        let stub = ProviderHTTPTransportStub { _ in Self.ok(page) }
        let fetcher = CursorUsageEventsFetcher(transport: stub, pageSize: 1, maxPages: 1)
        do {
            _ = try await fetcher.fetchUsage(cookieHeader: "a=b", since: nil, until: nil)
            Issue.record("Expected cursorPaginationIncomplete")
        } catch let error as CostUsageError {
            guard case let .cursorPaginationIncomplete(expected, received) = error else {
                Issue.record("Unexpected CostUsageError: \(error)")
                return
            }
            #expect(expected == 5)
            #expect(received == 1)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `fetchUsage throws inconsistent when the total changes mid-fetch`() async {
        let stub = ProviderHTTPTransportStub { request in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            if body.contains("\"page\":1") {
                return Self.ok(Self.pageData(total: 2, eventsJSON: Self.eventJSON()))
            }
            return Self.ok(Self.pageData(total: 3, eventsJSON: Self.eventJSON()))
        }
        let fetcher = CursorUsageEventsFetcher(transport: stub, pageSize: 1, maxPages: 3)
        do {
            _ = try await fetcher.fetchUsage(cookieHeader: "a=b", since: nil, until: nil)
            Issue.record("Expected cursorPaginationInconsistent")
        } catch let error as CostUsageError {
            guard case .cursorPaginationInconsistent = error else {
                Issue.record("Unexpected CostUsageError: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - Rollup helpers

    @Test
    func `cursorCostProvenance reflects metered and list-price presence`() {
        let priced = CostUsageDailyReport.Entry(
            date: "2024-07-01",
            inputTokens: 1,
            outputTokens: 1,
            totalTokens: 2,
            costUSD: 0.01,
            modelsUsed: nil,
            modelBreakdowns: nil)
        let unpriced = CostUsageDailyReport.Entry(
            date: "2024-07-01",
            inputTokens: 1,
            outputTokens: 1,
            totalTokens: 2,
            costUSD: nil,
            modelsUsed: nil,
            modelBreakdowns: nil)
        #expect(CostUsageFetcher.cursorCostProvenance(meteredCostUSD: 0.5, daily: [priced]) == .mixed)
        #expect(CostUsageFetcher.cursorCostProvenance(meteredCostUSD: 0.5, daily: [unpriced]) == .vendorMetered)
        #expect(CostUsageFetcher.cursorCostProvenance(meteredCostUSD: nil, daily: [priced]) == .listPriceEstimate)
        #expect(CostUsageFetcher.cursorCostProvenance(meteredCostUSD: nil, daily: [unpriced]) == .unknown)
        #expect(CostUsageFetcher.cursorCostProvenance(meteredCostUSD: nil, daily: []) == .unknown)
    }

    @Test
    func `cursorWindowStart snaps to the day boundary`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let instant = Date(timeIntervalSince1970: 1_719_795_600) // 2024-07-01 01:00 UTC
        let dayStart = Date(timeIntervalSince1970: 1_719_792_000)
        #expect(CostUsageFetcher.cursorWindowStart(instant, calendar: calendar) == dayStart)
        #expect(CostUsageFetcher.cursorWindowStart(nil) == nil)
    }

    @Test
    func `tokenSnapshot carries metered cost and provenance`() {
        let report = CursorUsageEventsFetcher.makeDailyReport(
            from: [Self.event()],
            calendar: Self.utcCalendar)
        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: report,
            now: Date(timeIntervalSince1970: 1_719_792_000),
            historyDays: 30,
            meteredCostUSD: 0.25,
            costProvenance: .mixed)
        #expect(snapshot.meteredCostUSD == 0.25)
        #expect(snapshot.costProvenance == .mixed)
        #expect(snapshot.last30DaysCostUSD == 0.125)
    }

    @Test
    func `renders cursor metered line in cost text`() {
        let report = CursorUsageEventsFetcher.makeDailyReport(
            from: [Self.event()],
            calendar: Self.utcCalendar)
        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: report,
            now: Date(timeIntervalSince1970: 1_719_792_000),
            historyDays: 30,
            meteredCostUSD: 0.25,
            costProvenance: .mixed)
        let output = CodexBarCLI.renderCostText(provider: .cursor, snapshot: snapshot, useColor: false)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "$ ", with: "$")
        #expect(output.contains("Today:"))
        #expect(output.contains("Cursor-metered: $0.25 (last 30 days)"))
    }

    @Test
    func `makeCostPayload carries metered cost and provenance`() {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: 0.1,
            last30DaysTokens: 100,
            last30DaysCostUSD: 1.0,
            meteredCostUSD: 0.5,
            costProvenance: .mixed,
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let payload = CodexBarCLI.makeCostPayload(provider: .cursor, snapshot: snapshot, error: nil)
        #expect(payload.meteredCostUSD == 0.5)
        #expect(payload.provenance == "mixed")
    }

    // MARK: - Model decoding and merge preservation

    @Test
    func `entry decodes coverage and reasoning fields`() throws {
        let json = """
        {"date":"2024-07-01","inputTokens":10,"outputTokens":5,"reasoningTokens":3,\
        "totalTokens":15,"requestCount":2,"costUSD":0.01,\
        "pricedRequestCount":1,"unpricedRequestCount":1,"estimatedRequestCount":0}
        """
        let data = Data(json.utf8)
        let entry = try JSONDecoder().decode(CostUsageDailyReport.Entry.self, from: data)
        #expect(entry.reasoningTokens == 3)
        #expect(entry.pricedRequestCount == 1)
        #expect(entry.unpricedRequestCount == 1)
        #expect(entry.coverageCounts == CostUsageCoverageCounts(priced: 1, unpriced: 1))
    }

    @Test
    func `merge preserves explicit coverage and stays nil without it`() {
        let covered = CostUsageDailyReport(data: [
            CostUsageDailyReport.Entry(
                date: "2024-07-01",
                inputTokens: 1,
                outputTokens: 1,
                totalTokens: 2,
                costUSD: 0.01,
                modelsUsed: nil,
                modelBreakdowns: nil,
                unpricedRequestCount: 1,
                pricedRequestCount: 2),
        ], summary: nil)
        let mergedCovered = CostUsageDailyReport.merged([covered, covered])
        #expect(mergedCovered.data.first?.pricedRequestCount == 4)
        #expect(mergedCovered.data.first?.unpricedRequestCount == 2)

        let plain = CostUsageDailyReport(data: [
            CostUsageDailyReport.Entry(
                date: "2024-07-01",
                inputTokens: 1,
                outputTokens: 1,
                totalTokens: 2,
                costUSD: 0.01,
                modelsUsed: nil,
                modelBreakdowns: nil),
        ], summary: nil)
        let mergedPlain = CostUsageDailyReport.merged([plain, plain])
        #expect(mergedPlain.data.first?.pricedRequestCount == nil)
        #expect(mergedPlain.data.first?.unpricedRequestCount == nil)
        #expect(mergedPlain.data.first?.reasoningTokens == nil)
    }
}
