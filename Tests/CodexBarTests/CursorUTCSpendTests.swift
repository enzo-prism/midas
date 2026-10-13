import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct CursorUTCSpendTests {
    private actor FetchCapture {
        struct Call: Sendable {
            let since: Date?
            let until: Date?
            let calendar: Calendar
            let cookie: String?
        }

        private(set) var calls: [Call] = []

        func record(since: Date?, until: Date?, calendar: Calendar, cookie: String?) {
            self.calls.append(Call(since: since, until: until, calendar: calendar, cookie: cookie))
        }
    }

    @Test func cursorSourceReceivesUTCAndKeepsMonthBoundaryEventsOnSeparateDays() async throws {
        let now = try self.date("2026-10-01T00:30:00Z")
        let before = try self.date("2026-09-30T23:50:00Z")
        let after = try self.date("2026-10-01T00:10:00Z")
        let events = try [self.event(at: before), self.event(at: after)]
        let capture = FetchCapture()
        let settings = ProviderSettingsSnapshot.CursorProviderSettings(
            cookieSource: .manual,
            manualCookieHeader: "WorkosCursorSessionToken=synthetic-value")
        let snapshot = try await CostUsageFetcher.loadCursorTokenSnapshot(
            cursorSettings: settings,
            now: now,
            historyDays: 30,
            fetchReport: { since, until, calendar, cookie in
                await capture.record(since: since, until: until, calendar: calendar, cookie: cookie)
                let daily = CursorUsageEventsFetcher.makeDailyReport(
                    from: events,
                    calendar: calendar,
                    modelsDevCatalog: ModelsDevCatalog(providers: [:]))
                return CursorCostReport(daily: daily, meteredCostUSD: 0.20, accountEmail: "example@example.test")
            })
        let calls = await capture.calls
        let call = try #require(calls.first)
        #expect(calls.count == 1)
        #expect(call.calendar.identifier == .gregorian)
        #expect(call.calendar.timeZone.secondsFromGMT(for: now) == 0)
        #expect(try call.since == (self.date("2026-09-02T00:00:00Z")))
        #expect(call.until == now)
        #expect(call.cookie == "WorkosCursorSessionToken=synthetic-value")
        #expect(snapshot.daily.map(\.date) == ["2026-09-30", "2026-10-01"])
        #expect(snapshot.daily.map(\.totalTokens) == [120, 120])
        #expect(snapshot.last30DaysTokens == 240)
        #expect(snapshot.last30DaysCostUSD == 0.20)
        #expect(snapshot.accountEmail == "example@example.test")
    }

    @Test func singleDayCursorWindowStartsAtUTCMidnight() async throws {
        let now = try self.date("2026-10-01T01:00:00Z")
        let capture = FetchCapture()
        _ = try await CostUsageFetcher.loadCursorTokenSnapshot(
            cursorSettings: nil,
            now: now,
            historyDays: 1,
            fetchReport: { since, until, calendar, cookie in
                await capture.record(since: since, until: until, calendar: calendar, cookie: cookie)
                return CursorCostReport(daily: .init(data: [], summary: nil), meteredCostUSD: nil)
            })
        let calls = await capture.calls
        let call = try #require(calls.first)
        #expect(try call.since == (self.date("2026-10-01T00:00:00Z")))
        #expect(call.calendar.timeZone.secondsFromGMT(for: now) == 0)
        #expect(call.cookie == nil)
    }

    @Test func disabledCursorSourceDoesNotInvokeTheInjectedFetcher() async throws {
        let capture = FetchCapture()
        let settings = ProviderSettingsSnapshot.CursorProviderSettings(cookieSource: .off, manualCookieHeader: nil)
        await #expect(throws: CostUsageError.self) {
            try await CostUsageFetcher.loadCursorTokenSnapshot(
                cursorSettings: settings,
                now: self.date("2026-10-01T01:00:00Z"),
                historyDays: 30,
                fetchReport: { since, until, calendar, cookie in
                    await capture.record(since: since, until: until, calendar: calendar, cookie: cookie)
                    return CursorCostReport(daily: .init(data: [], summary: nil), meteredCostUSD: nil)
                })
        }
        #expect(await capture.calls.isEmpty)
    }

    @Test func oldLocalDayCacheRemainsUntouchedAndCannotBeLoadedAsUTC() throws {
        let root = try self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = self.snapshot()
        #expect(CursorSpendSnapshotCache.save(snapshot, accountEmail: "example@example.test", cacheRoot: root))
        let current = CursorSpendSnapshotCache.fileURL(cacheRoot: root)
        var payload = try self.json(at: current)
        payload["version"] = 1
        payload.removeValue(forKey: "reportingTimeZone")
        let legacy = current.deletingLastPathComponent().appendingPathComponent("cursor-spend-v1.json")
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try bytes.write(to: legacy)
        try FileManager.default.removeItem(at: current)
        #expect(CursorSpendSnapshotCache.load(
            accountEmail: "example@example.test",
            historyDays: 30,
            cacheRoot: root) == nil)
        #expect(CursorSpendSnapshotCache.cachedAccountKey(cacheRoot: root) == nil)
        #expect(try Data(contentsOf: legacy) == bytes)
        #expect(!FileManager.default.fileExists(atPath: current.path))
        #expect(CursorSpendSnapshotCache.save(snapshot, accountEmail: "example@example.test", cacheRoot: root))
        #expect(CursorSpendSnapshotCache.load(
            accountEmail: "example@example.test",
            historyDays: 30,
            cacheRoot: root) == snapshot)
        #expect(try Data(contentsOf: legacy) == bytes)
    }

    @Test func currentCursorCacheExplicitlyEstablishesUTCAndRejectsForeignSchemaOrZone() throws {
        let root = try self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = self.snapshot()
        #expect(CursorSpendSnapshotCache.save(snapshot, accountEmail: "example@example.test", cacheRoot: root))
        let current = CursorSpendSnapshotCache.fileURL(cacheRoot: root)
        let original = try self.json(at: current)
        #expect(original["version"] as? Int == 2)
        #expect(original["reportingTimeZone"] as? String == "UTC")
        #expect(CursorSpendSnapshotCache.cachedAccountKey(cacheRoot: root) == "example@example.test")
        for (key, value) in [("version", 1 as Any), ("reportingTimeZone", "America/Los_Angeles" as Any)] {
            var payload = original
            payload[key] = value
            try JSONSerialization.data(withJSONObject: payload).write(to: current)
            #expect(CursorSpendSnapshotCache.load(
                accountEmail: "example@example.test",
                historyDays: 30,
                cacheRoot: root) == nil)
            #expect(CursorSpendSnapshotCache.cachedAccountKey(cacheRoot: root) == nil)
        }
    }

    @Test func cursorMonthCalendarRemainsUTCForEveryPriceProvenanceAndMacZone() throws {
        let now = try self.date("2026-10-01T01:00:00Z")
        for name in ["America/Los_Angeles", "Asia/Tokyo"] {
            let local = try #require(TimeZone(identifier: name))
            for provenance in [CostProvenance.unknown, .listPriceEstimate, .vendorMetered, .mixed] {
                let zone = MidasMonthlySpend.reportingTimeZone(
                    provider: .cursor,
                    codexCloudEnabled: false,
                    provenance: provenance,
                    localTimeZone: local)
                #expect(zone.secondsFromGMT(for: now) == 0)
                let model = MidasMonthlySpend(snapshot: self.snapshot(), now: now, reportingTimeZone: zone)
                #expect(model.months.last?.id == "2026-10")
                #expect(model.months.last?.tokens == 120)
            }
        }
    }

    private func snapshot() -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 120,
            sessionCostUSD: 0.10,
            last30DaysTokens: 120,
            last30DaysCostUSD: 0.10,
            historyDays: 30,
            costProvenance: .listPriceEstimate,
            daily: [.init(
                date: "2026-10-01",
                inputTokens: 100,
                outputTokens: 20,
                totalTokens: 120,
                costUSD: 0.10,
                modelsUsed: ["gpt-5"],
                modelBreakdowns: nil)],
            updatedAt: Date(timeIntervalSince1970: 1_791_000_000))
    }

    private func event(at date: Date) throws -> CursorUsageEvent {
        let milliseconds = Int64(date.timeIntervalSince1970 * 1000)
        let json = """
        {"timestamp":"\(milliseconds)","model":"gpt-5","tokenUsage":{"inputTokens":100,"outputTokens":20,
        "cacheWriteTokens":0,"cacheReadTokens":0,"totalCents":10},"chargedCents":10}
        """
        return try JSONDecoder().decode(CursorUsageEvent.self, from: Data(json.utf8))
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CursorUTCSpend-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func json(at url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }
}
