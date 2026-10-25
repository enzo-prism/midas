import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct MetaSubscriptionUsageTests {
    private let now = Date(timeIntervalSince1970: 1_791_874_582)

    /// The payload shape the Muse host publishes (`usage/changed` from a live probe).
    private var payload: Data {
        Data("""
        {"window":{"usedPercent":81,"windowDurationMins":300,"resetsAtMs":1791881505000},\
        "weekly":{"usedPercent":27,"resetsAtMs":1792368000000},\
        "tier":"27681631238169137","observedAtMs":1791874582116}
        """.utf8)
    }

    private func usage() throws -> MetaSubscriptionUsage {
        try #require(MetaSubscriptionUsage._parseForTesting(data: self.payload))
    }

    @Test
    func `parses provider usage into left percents and resets`() throws {
        let usage = try self.usage()
        #expect(usage.windowUsedPercent == 81)
        #expect(usage.windowRemainingPercent == 19)
        #expect(usage.windowDurationMins == 300)
        #expect(usage.windowResetsAt == Date(timeIntervalSince1970: 1_791_881_505))
        #expect(usage.weeklyUsedPercent == 27)
        #expect(usage.weeklyRemainingPercent == 73)
        #expect(usage.weeklyResetsAt == Date(timeIntervalSince1970: 1_792_368_000))
        #expect(usage.tier == "27681631238169137")
    }

    @Test
    func `over quota usage clamps left to zero`() {
        let usage = MetaSubscriptionUsage(
            windowUsedPercent: 104,
            windowDurationMins: 300,
            windowResetsAt: self.now,
            weeklyUsedPercent: 130,
            weeklyResetsAt: self.now,
            tier: nil,
            observedAt: self.now)
        #expect(usage.windowRemainingPercent == 0)
        #expect(usage.weeklyRemainingPercent == 0)
    }

    @Test
    func `malformed payloads are rejected`() {
        #expect(MetaSubscriptionUsage._parseForTesting(data: Data("{}".utf8)) == nil)
        #expect(MetaSubscriptionUsage._parseForTesting(data: Data(#"{"window":{}}"#.utf8)) == nil)
    }

    @Test
    func `snapshot carries real windows and survives codable round trip`() throws {
        let snapshot = try MetaUsageSnapshot(summary: MetaUsageSummary(updatedAt: self.now), usage: self.usage())
            .toUsageSnapshot()
        #expect(snapshot.primary?.usedPercent == 81)
        #expect(snapshot.primary?.windowMinutes == 300)
        #expect(snapshot.primary?.resetsAt == Date(timeIntervalSince1970: 1_791_881_505))
        #expect(snapshot.secondary?.usedPercent == 27)
        #expect(snapshot.secondary?.resetsAt == Date(timeIntervalSince1970: 1_792_368_000))
        #expect(try snapshot.metaUsage == (self.usage()))

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        #expect(decoded.metaUsage == snapshot.metaUsage)

        let legacy = #"{"primary":null,"secondary":null,"tertiary":null,"updatedAt":810211200}"#
        let old = try JSONDecoder().decode(UsageSnapshot.self, from: Data(legacy.utf8))
        #expect(old.metaUsage == nil)
    }

    @Test
    func `air presentation shows current and weekly left with resets`() throws {
        let result = try self.presentation()
        #expect(result.hero?.title == "Current usage")
        #expect(result.hero?.valueText == "19% left")
        #expect(result.hero?.resetsAt == Date(timeIntervalSince1970: 1_791_881_505))
        #expect(result.metrics.map(\.title) == ["Weekly limit"])
        #expect(result.metrics.first?.valueText == "73% left")
        #expect(result.metrics.first?.resetsAt == Date(timeIntervalSince1970: 1_792_368_000))
        #expect(result.activityMetrics.isEmpty)
        #expect(result.summary.contains("19% left"))
    }

    @Test
    func `legacy menu card shows real quota rows`() throws {
        let model = try self.cardModel(showUsed: false)
        #expect(model.metrics.map(\.id) == ["primary", "secondary"])
        #expect(model.metrics.map(\.title) == ["Current usage", "Weekly limit"])
        #expect(model.metrics[0].percent == 19)
        #expect(model.metrics[0].percentStyle == .left)
        #expect(model.metrics[0].resetText?.contains("Resets") == true)
        #expect(model.metrics[1].percent == 73)
        #expect(model.metrics[1].resetText?.contains("Resets") == true)
    }

    @Test
    func `legacy menu card honors show used for quota rows`() throws {
        let model = try self.cardModel(showUsed: true)
        #expect(model.metrics[0].percent == 81)
        #expect(model.metrics[0].percentStyle == .used)
        #expect(model.metrics[1].percent == 27)
    }

    @Test
    func `cache freshness follows the hourly probe budget`() throws {
        let usage = try self.usage()
        let payload = MetaSubscriptionUsageCache.Payload(usage: usage, probeSessionID: "session-1")
        #expect(MetaSubscriptionUsageCache.isFresh(payload, now: usage.observedAt.addingTimeInterval(30 * 60)))
        #expect(!MetaSubscriptionUsageCache.isFresh(payload, now: usage.observedAt.addingTimeInterval(70 * 60)))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(MetaSubscriptionUsageCache.save(payload, cacheRoot: root))
        #expect(MetaSubscriptionUsageCache.load(cacheRoot: root) == payload)
    }

    /// The failed-turn reason `muse serve` sends when Meta rejects a probe on an exhausted plan.
    private let exhaustedReason = "API error 429 [request_id=b2e82975-f1d9-4cea-af0e-97b077dccb7f]: "
        + "Subscription quota exhausted. Your usage window resets at 2026-10-26T00:00:00Z. (rate_limit_error)"

    @Test
    func `quota exhausted rejection yields its reset time`() {
        #expect(MetaSubscriptionUsage.quotaExhaustedResetDate(fromFailureReason: self.exhaustedReason)
            == Date(timeIntervalSince1970: 1_792_972_800))
        #expect(MetaSubscriptionUsage.quotaExhaustedResetDate(
            fromFailureReason: "Subscription quota exhausted. Your usage window resets at 2026-10-26T00:00:00.250Z.")
            == Date(timeIntervalSince1970: 1_792_972_800.25))
        #expect(MetaSubscriptionUsage.quotaExhaustedResetDate(
            fromFailureReason: "API error 429: Too many requests. Retry resets at 2026-10-26T00:00:00Z.") == nil)
        #expect(MetaSubscriptionUsage.quotaExhaustedResetDate(fromFailureReason: "Subscription quota exhausted.")
            == nil)
    }

    @Test
    func `weekly block reads fully used until the reset`() throws {
        let resetsAt = self.now.addingTimeInterval(30 * 3600)
        let usage = try MetaSubscriptionUsage.blocked(until: resetsAt, observedAt: self.now, previous: self.usage())
        #expect(usage.windowRemainingPercent == 0)
        #expect(usage.windowResetsAt == resetsAt)
        #expect(usage.windowDurationMins == 300)
        #expect(usage.weeklyRemainingPercent == 0)
        #expect(usage.weeklyResetsAt == resetsAt)
        #expect(usage.blockedUntil == resetsAt)
        #expect(usage.isCurrent(now: resetsAt.addingTimeInterval(-1)))
        #expect(!usage.isCurrent(now: resetsAt))

        let snapshot = MetaUsageSnapshot(summary: MetaUsageSummary(updatedAt: self.now), usage: usage)
            .toUsageSnapshot()
        let model = try self.cardModel(snapshot: snapshot, showUsed: false)
        #expect(model.metrics.map(\.percent) == [0, 0])
    }

    @Test
    func `window block keeps a still valid weekly reading`() throws {
        let previous = try self.usage()
        let resetsAt = self.now.addingTimeInterval(2 * 3600)
        let usage = MetaSubscriptionUsage.blocked(until: resetsAt, observedAt: self.now, previous: previous)
        #expect(usage.windowRemainingPercent == 0)
        #expect(usage.windowResetsAt == resetsAt)
        #expect(usage.weeklyUsedPercent == previous.weeklyUsedPercent)
        #expect(usage.weeklyResetsAt == previous.weeklyResetsAt)
    }

    @Test
    func `blocked cache stops being fresh at its reset`() {
        let resetsAt = self.now.addingTimeInterval(20 * 60)
        let usage = MetaSubscriptionUsage.blocked(until: resetsAt, observedAt: self.now, previous: nil)
        let payload = MetaSubscriptionUsageCache.Payload(usage: usage, probeSessionID: "session-1")
        #expect(MetaSubscriptionUsageCache.isFresh(payload, now: self.now.addingTimeInterval(10 * 60)))
        #expect(!MetaSubscriptionUsageCache.isFresh(payload, now: resetsAt))
    }

    @Test
    func `cache written before blocked readings still decodes`() throws {
        let legacy = Data("""
        {"version":1,"probeSessionID":"session-1","usage":{"windowUsedPercent":81,"windowDurationMins":300,\
        "windowResetsAt":810211200,"weeklyUsedPercent":27,"weeklyResetsAt":810211200,\
        "tier":"27681631238169137","observedAt":810211200}}
        """.utf8)
        let payload = try JSONDecoder().decode(MetaSubscriptionUsageCache.Payload.self, from: legacy)
        #expect(payload.usage?.weeklyUsedPercent == 27)
        #expect(payload.usage?.blockedUntil == nil)
        #expect(payload.lastFailureAt == nil)
        #expect(payload.probeSessionID == "session-1")
    }

    @Test
    func `exhausted probe is cached and reuses its session`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resetsAt = self.now.addingTimeInterval(30 * 3600)
        let probes = ProbeLog()

        let usage = try await MetaSubscriptionFetchStrategy.subscriptionUsage(now: self.now, cacheRoot: root) {
            probes.record($0)
            throw MetaUsageProbeFailure(error: .quotaExhausted(resetsAt: resetsAt), sessionID: "check-1")
        }
        #expect(usage.blockedUntil == resetsAt)
        #expect(usage.weeklyRemainingPercent == 0)
        #expect(MetaSubscriptionUsageCache.load(cacheRoot: root)?.probeSessionID == "check-1")

        let reused = try await MetaSubscriptionFetchStrategy.subscriptionUsage(
            now: self.now.addingTimeInterval(5 * 60), cacheRoot: root)
        {
            probes.record($0)
            throw MetaUsageProbeError.timedOut
        }
        #expect(reused == usage)
        #expect(probes.sessions == [nil])

        let reset = try await MetaSubscriptionFetchStrategy.subscriptionUsage(
            now: self.now.addingTimeInterval(60 * 60), cacheRoot: root)
        {
            probes.record($0)
            return try (self.usage(), $0)
        }
        #expect(try reset == self.usage())
        #expect(probes.sessions == [nil, "check-1"])
    }

    @Test
    func `failed probe backs off for the hour and resumes its session`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probes = ProbeLog()
        let failing: (String?) async throws -> (usage: MetaSubscriptionUsage, sessionID: String?) = {
            probes.record($0)
            throw MetaUsageProbeFailure(error: .noUsageObserved, sessionID: "check-1")
        }

        await #expect(throws: MetaUsageProbeFailure.self) {
            try await MetaSubscriptionFetchStrategy.subscriptionUsage(
                now: self.now, cacheRoot: root, probe: failing)
        }
        await #expect(throws: MetaUsageProbeError.self) {
            try await MetaSubscriptionFetchStrategy.subscriptionUsage(
                now: self.now.addingTimeInterval(5 * 60), cacheRoot: root, probe: failing)
        }
        #expect(probes.sessions == [nil])

        await #expect(throws: MetaUsageProbeFailure.self) {
            try await MetaSubscriptionFetchStrategy.subscriptionUsage(
                now: self.now.addingTimeInterval(60 * 60), cacheRoot: root, probe: failing)
        }
        #expect(probes.sessions == [nil, "check-1"])
    }

    @Test
    func `uuid7 has version and variant bits`() throws {
        let id = MetaUsageProbe.uuid7(now: self.now)
        #expect(id.count == 36)
        #expect(id.split(separator: "-")[2].hasPrefix("7"))
        #expect(try "89ab".contains(#require(id.split(separator: "-")[3].first)))
    }

    private func presentation() throws -> MidasProviderPresentation {
        let snapshot = try MetaUsageSnapshot(summary: MetaUsageSummary(updatedAt: self.now), usage: self.usage())
            .toUsageSnapshot()
        return try MidasProviderPresentation.make(
            provider: .meta,
            card: self.cardModel(showUsed: false),
            snapshot: snapshot,
            tokenSnapshot: nil,
            isRefreshing: false,
            isStale: false)
    }

    private func cardModel(showUsed: Bool) throws -> UsageMenuCardView.Model {
        let snapshot = try MetaUsageSnapshot(summary: MetaUsageSummary(updatedAt: self.now), usage: self.usage())
            .toUsageSnapshot()
        return try self.cardModel(snapshot: snapshot, showUsed: showUsed)
    }

    private func cardModel(snapshot: UsageSnapshot, showUsed: Bool) throws -> UsageMenuCardView.Model {
        try UsageMenuCardView.Model.make(.init(
            provider: .meta,
            metadata: #require(ProviderDefaults.metadata[.meta]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: showUsed,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: self.now))
    }
}

/// Records the session each probe was asked to resume.
private final class ProbeLog: @unchecked Sendable {
    private(set) var sessions: [String?] = []

    func record(_ sessionID: String?) {
        self.sessions.append(sessionID)
    }
}
