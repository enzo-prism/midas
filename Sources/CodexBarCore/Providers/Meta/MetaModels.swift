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
        self.inputTokens + self.outputTokens + self.reasoningTokens
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            reasoningTokens: lhs.reasoningTokens + rhs.reasoningTokens,
            cachedTokens: lhs.cachedTokens + rhs.cachedTokens,
            requests: lhs.requests + rhs.requests)
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

    public init(at: Date, model: String?, usage: MetaTokenUsage) {
        self.at = at
        self.model = model
        self.usage = usage
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
