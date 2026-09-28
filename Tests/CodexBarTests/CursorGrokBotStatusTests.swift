import Foundation
import Testing
@testable import CodexBarCore

/// Grok Bot readings survive the ways cursor.com answers: odd field types, an exhausted allowance, a failed or
/// slow dashboard call, and plans without the feature.
struct CursorGrokBotStatusTests {
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

    private static let summaryJSON = """
    {"individualUsage": {"plan": {"used": 40000, "limit": 40000}},
     "billingCycleEnd": "2026-09-11T00:00:00.000Z"}
    """

    private static let periodJSON = """
    {"planUsage": {"autoPercentUsed": 5.0, "apiPercentUsed": 100.0, "totalPercentUsed": 49.0}}
    """

    private static let sandJSON = """
    {"nextResetTimestampUtc": "2099-09-08T23:22:26.061Z", "usagePercent": 30,
     "hasAvailableUsage": true, "includedLimitZero": false}
    """

    private static func response(_ status: Int, _ body: String = "{}") -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: URL(string: "https://cursor.com")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil)!
        return (Data(body.utf8), response)
    }

    /// A Cursor session whose Grok Bot endpoint answers with `sand` on each successive call.
    private static func probe(
        sandCalls: Counter,
        sand: @escaping @Sendable (Int) -> (Data, URLResponse)) -> CursorStatusProbe
    {
        let stub = ProviderHTTPTransportStub { request in
            switch request.url?.path {
            case "/api/usage-summary": Self.response(200, Self.summaryJSON)
            case "/api/dashboard/get-current-period-usage": Self.response(200, Self.periodJSON)
            case "/api/dashboard/get-sand-usage-status": sand(sandCalls.next())
            default: Self.response(500)
            }
        }
        return CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0), urlSession: stub)
    }

    private static func grokWindow(_ snapshot: CursorStatusSnapshot) -> NamedRateWindow? {
        snapshot.toUsageSnapshot().extraRateWindows?.first { $0.id == "cursor-grok-bot" }
    }

    @Test
    func `lenient decoding accepts string percents epoch dates and numeric flags`() throws {
        let json = """
        {"usagePercent": "42.5", "nextResetTimestampUtc": 1789200000000,
         "hasAvailableUsage": 1, "includedLimitZero": "false", "grokPlanLabel": 7}
        """
        let status = try JSONDecoder().decode(CursorSandUsageStatus.self, from: Data(json.utf8))
        #expect(status.usagePercent == 42.5)
        #expect(status.hasAvailableUsage == true)
        #expect(status.includedLimitZero == false)
        #expect(status.grokPlanLabel == nil)
        let allowance = try #require(status.allowance(now: Date(timeIntervalSince1970: 1_789_000_000)))
        #expect(allowance.usedPercent == 42.5)
        #expect(allowance.resetsAt == Date(timeIntervalSince1970: 1_789_200_000))
    }

    @Test
    func `no available usage reads as exhausted even when the percent lags`() {
        let lagging = CursorSandUsageStatus(usagePercent: 97, hasAvailableUsage: false, includedLimitZero: false)
        #expect(lagging.allowance()?.usedPercent == 100)
        let missing = CursorSandUsageStatus(hasAvailableUsage: false, includedLimitZero: false)
        #expect(missing.allowance()?.usedPercent == 100)
        let notIncluded = CursorSandUsageStatus(usagePercent: 0, hasAvailableUsage: false, includedLimitZero: true)
        #expect(notIncluded.allowance() == nil)
    }

    @Test
    func `a failed grok bot call is retried once and then reported unavailable`() async throws {
        let calls = Counter()
        let snapshot = try await Self.probe(sandCalls: calls) { _ in Self.response(500) }
            .fetch(cookieHeaderOverride: "WorkosCursorSessionToken=abc")

        #expect(snapshot.grokBotWeeklyUsedPercent == nil)
        #expect(snapshot.grokBotUnavailableReason == "HTTP 500")
        let grok = try #require(Self.grokWindow(snapshot))
        #expect(!grok.usageKnown)
        // The monthly pools are unaffected.
        #expect(snapshot.cursorModelsUsedPercent == 5)
        #expect(snapshot.otherModelsUsedPercent == 100)
        #expect(snapshot.rawJSON?.contains("--- get-sand-usage-status ---\nfailed: HTTP 500") == true)
        #expect(calls.next() == 3, "expected exactly two sand requests")
    }

    @Test
    func `a transient grok bot failure recovers on the retry`() async throws {
        let calls = Counter()
        let snapshot = try await Self.probe(sandCalls: calls) { call in
            call == 1 ? Self.response(503) : Self.response(200, Self.sandJSON)
        }.fetch(cookieHeaderOverride: "WorkosCursorSessionToken=abc")

        #expect(snapshot.grokBotWeeklyUsedPercent == 30)
        #expect(snapshot.grokBotUnavailableReason == nil)
        #expect(Self.grokWindow(snapshot)?.usageKnown == true)
        #expect(snapshot.rawJSON?.contains("\"usagePercent\": 30") == true)
    }

    @Test
    func `plans without grok bot stay hidden and are not retried`() async throws {
        let calls = Counter()
        let notOffered = try await Self.probe(sandCalls: calls) { _ in Self.response(404) }
            .fetch(cookieHeaderOverride: "WorkosCursorSessionToken=abc")
        #expect(Self.grokWindow(notOffered) == nil)
        #expect(notOffered.grokBotUnavailableReason == nil)
        #expect(calls.next() == 2, "a 4xx is an answer, not a transient failure")

        let zeroAllowance = try await Self.probe(sandCalls: Counter()) { _ in
            Self.response(200, #"{"usagePercent": 0, "includedLimitZero": true}"#)
        }.fetch(cookieHeaderOverride: "WorkosCursorSessionToken=abc")
        #expect(Self.grokWindow(zeroAllowance) == nil)
        #expect(zeroAllowance.grokBotUnavailableReason == nil)
    }

    @Test
    func `an undecodable grok bot answer is unavailable rather than hidden`() async throws {
        let snapshot = try await Self.probe(sandCalls: Counter()) { _ in Self.response(200, "<html>oops</html>") }
            .fetch(cookieHeaderOverride: "WorkosCursorSessionToken=abc")
        #expect(snapshot.grokBotUnavailableReason?.hasPrefix("Decode failed") == true)
        #expect(Self.grokWindow(snapshot)?.usageKnown == false)
    }
}
