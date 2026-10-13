import Foundation

/// Token totals aggregated from local Muse session logs.
public struct MetaTokenUsage: Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int
    public let cachedTokens: Int
    public let requests: Int

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningTokens: Int = 0,
        cachedTokens: Int = 0,
        requests: Int = 0)
    {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cachedTokens = cachedTokens
        self.requests = requests
    }

    public var totalTokens: Int {
        CostUsageScanner.boundedAdd(
            CostUsageScanner.boundedAdd(self.inputTokens, self.outputTokens), self.reasoningTokens)
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            inputTokens: CostUsageScanner.boundedAdd(lhs.inputTokens, rhs.inputTokens),
            outputTokens: CostUsageScanner.boundedAdd(lhs.outputTokens, rhs.outputTokens),
            reasoningTokens: CostUsageScanner.boundedAdd(lhs.reasoningTokens, rhs.reasoningTokens),
            cachedTokens: CostUsageScanner.boundedAdd(lhs.cachedTokens, rhs.cachedTokens),
            requests: CostUsageScanner.boundedAdd(lhs.requests, rhs.requests))
    }

    public static func += (lhs: inout Self, rhs: Self) {
        lhs = lhs + rhs
    }
}

/// One completed model response parsed from a Muse `session.jsonl` log.
public struct MetaCompletedResponse: Sendable, Equatable {
    /// `recorded_at` converted to `Date` (logs store microseconds since epoch).
    public let at: Date
    public let model: String?
    public let usage: MetaTokenUsage
    /// Stable record identity, retained locally and salted before publication.
    public let sourceIDComponents: [String]?
    public let hasRecordedTimestamp: Bool

    public init(
        at: Date,
        model: String?,
        usage: MetaTokenUsage,
        sourceIDComponents: [String]? = nil,
        hasRecordedTimestamp: Bool = true)
    {
        self.at = at
        self.model = model
        self.usage = usage
        self.sourceIDComponents = sourceIDComponents
        self.hasRecordedTimestamp = hasRecordedTimestamp
    }
}

/// Aggregated usage summary backing the Meta provider snapshot + cost history.
public struct MetaUsageSummary: Sendable, Equatable {
    public let today: MetaTokenUsage
    public let last7Days: MetaTokenUsage
    public let last30Days: MetaTokenUsage
    public let sessionsWithData: Int
    public let modelsUsed: [String]
    public let daily: [MetaDailyUsage]
    public let updatedAt: Date

    public init(
        today: MetaTokenUsage = MetaTokenUsage(),
        last7Days: MetaTokenUsage = MetaTokenUsage(),
        last30Days: MetaTokenUsage = MetaTokenUsage(),
        sessionsWithData: Int = 0,
        modelsUsed: [String] = [],
        daily: [MetaDailyUsage] = [],
        updatedAt: Date = Date())
    {
        self.today = today
        self.last7Days = last7Days
        self.last30Days = last30Days
        self.sessionsWithData = sessionsWithData
        self.modelsUsed = modelsUsed
        self.daily = daily
        self.updatedAt = updatedAt
    }
}

public struct MetaDailyUsage: Sendable, Equatable {
    /// Local-calendar day key (`yyyy-MM-dd`).
    public let dayKey: String
    public let usage: MetaTokenUsage
    public let modelsUsed: [String]

    public init(dayKey: String, usage: MetaTokenUsage, modelsUsed: [String] = []) {
        self.dayKey = dayKey
        self.usage = usage
        self.modelsUsed = modelsUsed
    }
}

/// One Claude-style activity bar for Meta: recorded Muse tokens in a window,
/// scaled against the busiest comparable recorded window. Meta reports no quota,
/// limit, or reset, so `sharePercent` is a share of recorded activity — never a
/// remaining-quota reading — and no window carries a reset date.
public struct MetaActivityWindow: Sendable, Equatable {
    public let id: String
    public let title: String
    public let tokens: Int
    public let requests: Int
    /// Tokens in the busiest comparable recorded window (busiest day for Today,
    /// busiest rolling 7 days for Last 7 days); 0 when nothing was recorded.
    public let comparisonTokens: Int
    public let comparisonLabel: String

    public init(
        id: String,
        title: String,
        tokens: Int,
        requests: Int,
        comparisonTokens: Int,
        comparisonLabel: String)
    {
        self.id = id
        self.title = title
        self.tokens = tokens
        self.requests = requests
        self.comparisonTokens = comparisonTokens
        self.comparisonLabel = comparisonLabel
    }

    /// Bar fill, 0...100. Zero activity and missing history both stay at zero.
    public var sharePercent: Double {
        guard self.comparisonTokens > 0, self.tokens > 0 else { return 0 }
        return min(100, max(0, Double(self.tokens) / Double(self.comparisonTokens) * 100))
    }
}

/// Recorded Muse activity backing Meta's Claude-style bars. Persisted on
/// `UsageSnapshot` so cold-launch hydration shows the same bars before refresh.
public struct MetaActivitySnapshot: Codable, Sendable, Equatable {
    public let todayTokens: Int
    public let todayRequests: Int
    public let last7DaysTokens: Int
    public let last7DaysRequests: Int
    public let last30DaysTokens: Int
    public let busiestDayTokens: Int
    public let busiestWeekTokens: Int

    public init(
        todayTokens: Int,
        todayRequests: Int,
        last7DaysTokens: Int,
        last7DaysRequests: Int,
        last30DaysTokens: Int,
        busiestDayTokens: Int,
        busiestWeekTokens: Int)
    {
        self.todayTokens = todayTokens
        self.todayRequests = todayRequests
        self.last7DaysTokens = last7DaysTokens
        self.last7DaysRequests = last7DaysRequests
        self.last30DaysTokens = last30DaysTokens
        self.busiestDayTokens = busiestDayTokens
        self.busiestWeekTokens = busiestWeekTokens
    }

    public init(summary: MetaUsageSummary) {
        self.init(
            todayTokens: summary.today.totalTokens,
            todayRequests: summary.today.requests,
            last7DaysTokens: summary.last7Days.totalTokens,
            last7DaysRequests: summary.last7Days.requests,
            last30DaysTokens: summary.last30Days.totalTokens,
            busiestDayTokens: summary.daily.map(\.usage.totalTokens).max() ?? 0,
            busiestWeekTokens: Self.busiestRollingWeek(daily: summary.daily))
    }

    /// Builds activity from generic daily token history (for example the selected
    /// cross-device scope), where each entry is a local-calendar day total.
    public init(
        dailyTotals: [(dayKey: String, tokens: Int, requests: Int)],
        today: MetaTokenUsage,
        last7Days: MetaTokenUsage,
        last30DaysTokens: Int)
    {
        let daily = dailyTotals.map {
            MetaDailyUsage(
                dayKey: $0.dayKey,
                usage: MetaTokenUsage(inputTokens: $0.tokens, requests: $0.requests))
        }
        self.init(
            todayTokens: today.totalTokens,
            todayRequests: today.requests,
            last7DaysTokens: last7Days.totalTokens,
            last7DaysRequests: last7Days.requests,
            last30DaysTokens: last30DaysTokens,
            busiestDayTokens: dailyTotals.map(\.tokens).max() ?? 0,
            busiestWeekTokens: Self.busiestRollingWeek(daily: daily))
    }

    /// Derives activity from generic token history (the spend-estimate snapshot,
    /// which follows the selected local/combined usage scope). Nil when it records
    /// no tokens in any window.
    public init?(tokenSnapshot: CostUsageTokenSnapshot) {
        let dailyTotals: [(dayKey: String, tokens: Int, requests: Int)] = tokenSnapshot.daily.map { entry in
            (
                dayKey: entry.date,
                tokens: entry.totalTokens
                    ?? (entry.inputTokens ?? 0) + (entry.outputTokens ?? 0) + (entry.reasoningTokens ?? 0),
                requests: entry.requestCount ?? 0)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let todayKey = formatter.string(from: tokenSnapshot.updatedAt)
        let weekCutoff = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -6, to: tokenSnapshot.updatedAt)
            .map { formatter.string(from: $0) } ?? todayKey
        let todayEntry = dailyTotals.first { $0.dayKey == todayKey }
        let weekEntries = dailyTotals.filter { $0.dayKey >= weekCutoff && $0.dayKey <= todayKey }
        let today = MetaTokenUsage(
            inputTokens: tokenSnapshot.sessionTokens ?? todayEntry?.tokens ?? 0,
            requests: tokenSnapshot.sessionRequests ?? todayEntry?.requests ?? 0)
        // The 7-day window always includes today, even when only aggregate
        // counters (no daily rows) were recorded.
        let last7 = MetaTokenUsage(
            inputTokens: max(weekEntries.map(\.tokens).reduce(0, +), today.totalTokens),
            requests: max(weekEntries.map(\.requests).reduce(0, +), today.requests))
        let last30 = tokenSnapshot.last30DaysTokens ?? dailyTotals.map(\.tokens).reduce(0, +)
        guard today.totalTokens > 0 || last7.totalTokens > 0 || last30 > 0 else { return nil }
        self.init(
            dailyTotals: dailyTotals,
            today: today,
            last7Days: last7,
            last30DaysTokens: last30)
    }

    public var hasActivity: Bool {
        self.last30DaysTokens > 0 || self.todayTokens > 0 || self.last7DaysTokens > 0
    }

    /// Today first (like a session window), then Last 7 days (like a weekly window).
    /// Each window is itself recorded, so the busiest comparable window is never
    /// smaller than the window being shown.
    public var windows: [MetaActivityWindow] {
        [
            MetaActivityWindow(
                id: "meta-activity-today",
                title: "Today",
                tokens: self.todayTokens,
                requests: self.todayRequests,
                comparisonTokens: max(self.busiestDayTokens, self.todayTokens),
                comparisonLabel: "busiest day"),
            MetaActivityWindow(
                id: "meta-activity-week",
                title: "Last 7 days",
                tokens: self.last7DaysTokens,
                requests: self.last7DaysRequests,
                comparisonTokens: max(self.busiestWeekTokens, self.last7DaysTokens),
                comparisonLabel: "busiest week"),
        ]
    }

    /// Largest rolling 7-calendar-day token total in `daily`; missing days count as zero.
    static func busiestRollingWeek(daily: [MetaDailyUsage]) -> Int {
        let totals = Dictionary(
            daily.map { ($0.dayKey, $0.usage.totalTokens) },
            uniquingKeysWith: { first, _ in first })
        let days = totals.keys.sorted()
        guard let first = days.first, let last = days.last else { return 0 }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let start = formatter.date(from: first), let end = formatter.date(from: last) else {
            return totals.values.max() ?? 0
        }
        var best = 0
        var cursor = start
        while cursor <= end {
            var sum = 0
            for offset in 0..<7 {
                if let day = Calendar(identifier: .gregorian).date(byAdding: .day, value: -offset, to: cursor) {
                    sum += totals[formatter.string(from: day)] ?? 0
                }
            }
            best = max(best, sum)
            guard let next = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return best
    }
}
