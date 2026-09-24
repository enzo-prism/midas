import Foundation
import Testing
@testable import CodexBarCore

/// Cursor spend and Grok Bot readings survive the ways cursor.com answers in practice: events that land
/// while a window is being paged, model ids with mode suffixes, and the newer Grok Bot allowance fields.
struct CursorSpendReliabilityTests {
    // MARK: - Pagination races

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.value += 1
            return self.value
        }
    }

    private static func ok(_ json: String) -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: URL(string: "https://cursor.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil)!
        return (Data(json.utf8), response)
    }

    private static func page(total: Int, events: [String]) -> String {
        "{\"totalUsageEventsCount\":\(total),\"usageEventsDisplay\":[\(events.joined(separator: ","))]}"
    }

    private static func event(_ timestampMS: Int64, cents: Double = 10) -> String {
        """
        {"timestamp":"\(timestampMS)","model":"gpt-5","tokenUsage":{"inputTokens":100,"outputTokens":10,\
        "cacheWriteTokens":0,"cacheReadTokens":0,"totalCents":\(cents)},"chargedCents":\(cents)}
        """
    }

    @Test
    func `a total that moves mid read is retried instead of failing the estimate`() async throws {
        let requests = Counter()
        let stub = ProviderHTTPTransportStub { request in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            let call = requests.next()
            // First pass: page 1 says 2 events, page 2 says 3 (a new event landed). Second pass is stable.
            if call == 1 { return Self.ok(Self.page(total: 2, events: [Self.event(1_758_700_000_000)])) }
            if call == 2 { return Self.ok(Self.page(total: 3, events: [Self.event(1_758_700_100_000)])) }
            if body.contains("\"page\":1") {
                return Self.ok(Self.page(total: 2, events: [Self.event(1_758_700_000_000)]))
            }
            if body.contains("\"page\":2") {
                return Self.ok(Self.page(total: 2, events: [Self.event(1_758_700_100_000)]))
            }
            return Self.ok(Self.page(total: 2, events: []))
        }
        let fetcher = CursorUsageEventsFetcher(transport: stub, pageSize: 1, maxPages: 5)

        let result = try await fetcher.fetchUsage(cookieHeader: "a=b", since: nil, until: nil)

        #expect(result.daily.data.compactMap(\.costUSD).reduce(0, +) == 0.20)
        #expect(result.meteredCostUSD == 0.20)
    }

    @Test
    func `hitting the page cap is not retried`() async {
        let requests = Counter()
        let stub = ProviderHTTPTransportStub { _ in
            _ = requests.next()
            return Self.ok(Self.page(total: 5, events: [Self.event(1_758_700_000_000)]))
        }
        let fetcher = CursorUsageEventsFetcher(transport: stub, pageSize: 1, maxPages: 1)
        await #expect(throws: CostUsageError.self) {
            _ = try await fetcher.fetchUsage(cookieHeader: "a=b", since: nil, until: nil)
        }
        #expect(await stub.requests().count == 1)
    }

    // MARK: - Model aliases for omitted costs

    @Test
    func `cursor model ids with mode suffixes find a list price`() {
        #expect(CursorUsageEventsFetcher.cursorPricingCandidates("claude-4.5-sonnet-thinking")
            == ["claude-4.5-sonnet-thinking", "claude-4.5-sonnet"])
        #expect(CursorUsageEventsFetcher.cursorPricingCandidates("gpt-5-high") == ["gpt-5-high", "gpt-5"])
        #expect(CursorUsageEventsFetcher.cursorPricingCandidates("gpt-5-fast") == ["gpt-5-fast"])
        #expect(CursorUsageEventsFetcher.cursorClaudeCatalogModel("claude-4.5-sonnet") == "claude-sonnet-4-5")
        #expect(CursorUsageEventsFetcher.cursorClaudeCatalogModel("claude-5.5-opus") == "claude-opus-5-5")
        #expect(CursorUsageEventsFetcher.cursorClaudeCatalogModel("claude-opus-4.8") == "claude-opus-4-8")

        let events = [CursorUsageEvent(
            timestampMS: 1_758_700_000_000,
            model: "claude-4.5-sonnet-thinking",
            tokenUsage: CursorEventTokenUsage(inputTokens: 100_000, outputTokens: 0, totalCents: nil))]
        let report = CursorUsageEventsFetcher.makeDailyReport(
            from: events,
            modelsDevCatalog: ModelsDevCatalog(providers: [:]))
        let entry = report.data.first
        // 100K input tokens at Claude Sonnet 4.5's $3/MTok list price.
        #expect(abs((entry?.costUSD ?? 0) - 0.30) < 1e-9)
        #expect(entry?.estimatedRequestCount == 1)
        #expect(entry?.unpricedRequestCount == nil)
    }

    // MARK: - Grok Bot allowance

    private static func sand(_ json: String) throws -> CursorSandUsageStatus {
        try JSONDecoder().decode(CursorSandUsageStatus.self, from: Data(json.utf8))
    }

    @Test
    func `included grok bot allowance keeps its weekly reset`() throws {
        let status = try Self.sand("""
        {"currentPeriodStart":"2026-09-21T09:12:32.776Z","nextResetTimestampUtc":"2026-09-28T09:12:32.776Z",
         "usagePercent":91.27,"hasAvailableUsage":true,"includedLimitZero":false}
        """)
        let allowance = try #require(status.allowance(now: Date(timeIntervalSince1970: 1_790_000_000)))
        #expect(allowance.usedPercent == 91.27)
        #expect(allowance.resetsAt != nil)
        #expect(allowance.trialEndsAt == nil)
    }

    @Test
    func `trial grok bot allowance ends instead of resetting`() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let status = try Self.sand("""
        {"nextResetTimestampUtc":"2026-09-28T09:12:32.776Z","usagePercent":40,
         "includedLimitZero":true,"sandTrialExpiresAt":"2026-10-01T09:12:32.776Z"}
        """)
        let allowance = try #require(status.allowance(now: now))
        #expect(allowance.resetsAt == nil)
        #expect(allowance.trialEndsAt != nil)

        let expired = try Self.sand("""
        {"usagePercent":40,"includedLimitZero":true,"sandTrialExpiresAt":"2026-09-01T09:12:32.776Z"}
        """)
        #expect(expired.allowance(now: now) == nil)
    }

    @Test
    func `zero grok bot allowance is hidden and legacy payloads still show`() throws {
        let zero = try Self.sand(#"{"usagePercent":0,"includedLimitZero":true}"#)
        #expect(zero.allowance() == nil)
        let legacy = try Self.sand(#"{"usagePercent":12,"nextResetTimestampUtc":"2026-09-28T09:12:32Z"}"#)
        #expect(legacy.allowance()?.usedPercent == 12)
        let older = try Self.sand(#"{"usagePercent":12,"hasNonZeroIncludedLimit":true}"#)
        #expect(older.allowance()?.usedPercent == 12)
    }

    @Test
    func `trial grok bot window reads as a trial without a weekly reset`() {
        let snapshot = CursorStatusSnapshot(
            planPercentUsed: 10,
            planUsedUSD: 2,
            planLimitUSD: 20,
            onDemandUsedUSD: 0,
            onDemandLimitUSD: nil,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleEnd: nil,
            membershipType: "pro",
            accountEmail: nil,
            accountName: nil,
            rawJSON: nil,
            grokBotWeeklyUsedPercent: 40,
            grokBotTrialEndsAt: Date(timeIntervalSince1970: 1_790_500_000)).toUsageSnapshot()
        let grok = snapshot.extraRateWindows?.first { $0.id == "cursor-grok-bot" }
        #expect(grok?.title == "Grok Bot (trial)")
        #expect(grok?.window.resetsAt == nil)
        #expect(grok?.window.windowMinutes == nil)
        let line = grok.flatMap { UsageFormatter.resetLine(for: $0.window, style: .countdown) }
        #expect(line?.hasPrefix("Trial ends ") == true)
    }

    // MARK: - Last-known spend cache

    private static func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("midas-cursor-spend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func spendSnapshot() -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 1200,
            sessionCostUSD: 1.5,
            last30DaysTokens: 5000,
            last30DaysCostUSD: 12.75,
            historyDays: 30,
            meteredCostUSD: 4.2,
            costProvenance: .mixed,
            daily: [CostUsageDailyReport.Entry(
                date: "2026-09-23",
                inputTokens: 4000,
                outputTokens: 1000,
                totalTokens: 5000,
                requestCount: 7,
                costUSD: 12.75,
                modelsUsed: ["gpt-5"],
                modelBreakdowns: [.init(modelName: "gpt-5", costUSD: 12.75, totalTokens: 5000, requestCount: 7)],
                unpricedRequestCount: 1,
                pricedRequestCount: 6)],
            updatedAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test
    func `spend cache round trips and rejects another account or window`() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Self.spendSnapshot()
        #expect(CursorSpendSnapshotCache.save(original, accountEmail: "Me@Example.com", cacheRoot: root))

        let loaded = CursorSpendSnapshotCache.load(accountEmail: "me@example.com", historyDays: 30, cacheRoot: root)
        #expect(loaded == original)
        #expect(CursorSpendSnapshotCache.load(accountEmail: nil, historyDays: 30, cacheRoot: root) == original)
        #expect(CursorSpendSnapshotCache.load(accountEmail: "other@example.com", historyDays: 30, cacheRoot: root)
            == nil)
        #expect(CursorSpendSnapshotCache.load(accountEmail: "me@example.com", historyDays: 7, cacheRoot: root) == nil)
        #expect(CursorSpendSnapshotCache.cachedAccountKey(cacheRoot: root) == "me@example.com")
    }

    @Test
    func `cache maintenance keeps the cursor spend file`() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        CursorSpendSnapshotCache.save(Self.spendSnapshot(), accountEmail: nil, cacheRoot: root)
        _ = CostUsageCacheMaintenance.pruneStaleArtifacts(cacheRoot: root)
        #expect(FileManager.default.fileExists(atPath: CursorSpendSnapshotCache.fileURL(cacheRoot: root).path))
    }
}
