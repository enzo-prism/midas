import Foundation

/// Grok Bot weekly window from `POST /api/dashboard/get-sand-usage-status` (body `{}`).
/// Absent for plans without the Grok feature.
public struct CursorSandUsageStatus: Codable, Sendable {
    public let currentPeriodStart: String?
    /// ISO-8601 weekly reset (e.g. the dashboard's "Resets Sep 8").
    public let nextResetTimestampUtc: String?
    /// Weekly usage percent (e.g. 91.27 means 91.27% used).
    public let usagePercent: Double?
    public let hasAvailableUsage: Bool?
    public let hasNonZeroIncludedLimit: Bool?
    public let grokPlanLabel: String?
    /// Current responses report the allowance as `includedLimitZero` (true = no included allowance);
    /// older ones used `hasNonZeroIncludedLimit`.
    public let includedLimitZero: Bool?
    /// ISO-8601 end of a Grok Bot trial allowance. A trial end is not a recurring weekly reset.
    public let sandTrialExpiresAt: String?
    /// True on the plans introduced 2026-10-12, where one weekly pool covers Cursor, Grok Bot and Bugbot.
    public let isUnified: Bool?
    /// Display tier of a unified plan, e.g. "Ultra".
    public let cursorPlanName: String?

    public init(
        currentPeriodStart: String? = nil,
        nextResetTimestampUtc: String? = nil,
        usagePercent: Double? = nil,
        hasAvailableUsage: Bool? = nil,
        hasNonZeroIncludedLimit: Bool? = nil,
        grokPlanLabel: String? = nil,
        includedLimitZero: Bool? = nil,
        sandTrialExpiresAt: String? = nil,
        isUnified: Bool? = nil,
        cursorPlanName: String? = nil)
    {
        self.isUnified = isUnified
        self.cursorPlanName = cursorPlanName
        self.currentPeriodStart = currentPeriodStart
        self.nextResetTimestampUtc = nextResetTimestampUtc
        self.usagePercent = usagePercent
        self.hasAvailableUsage = hasAvailableUsage
        self.hasNonZeroIncludedLimit = hasNonZeroIncludedLimit
        self.grokPlanLabel = grokPlanLabel
        self.includedLimitZero = includedLimitZero
        self.sandTrialExpiresAt = sandTrialExpiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case currentPeriodStart
        case nextResetTimestampUtc
        case usagePercent
        case hasAvailableUsage
        case hasNonZeroIncludedLimit
        case grokPlanLabel
        case includedLimitZero
        case sandTrialExpiresAt
        case isUnified
        case cursorPlanName
    }

    /// Tolerates the shapes the dashboard has used: percents as numbers or numeric strings, dates as ISO-8601
    /// strings or epoch numbers, and flags as booleans or 0/1. One odd field must not hide the whole row.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.currentPeriodStart = Self.lenientDate(container, .currentPeriodStart)
        self.nextResetTimestampUtc = Self.lenientDate(container, .nextResetTimestampUtc)
        self.usagePercent = Self.lenientNumber(container, .usagePercent)
        self.hasAvailableUsage = Self.lenientBool(container, .hasAvailableUsage)
        self.hasNonZeroIncludedLimit = Self.lenientBool(container, .hasNonZeroIncludedLimit)
        self.grokPlanLabel = try? container.decodeIfPresent(String.self, forKey: .grokPlanLabel)
        self.includedLimitZero = Self.lenientBool(container, .includedLimitZero)
        self.sandTrialExpiresAt = Self.lenientDate(container, .sandTrialExpiresAt)
        self.isUnified = Self.lenientBool(container, .isUnified)
        self.cursorPlanName = try? container.decodeIfPresent(String.self, forKey: .cursorPlanName)
    }

    private static func lenientNumber(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return value }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func lenientBool(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            switch text.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    /// Normalizes epoch seconds or milliseconds to the ISO-8601 text the rest of the model expects.
    private static func lenientDate(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            guard let epoch = Double(text) else { return text }
            return Self.isoString(epoch: epoch)
        }
        if let epoch = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Self.isoString(epoch: epoch)
        }
        return nil
    }

    private static func isoString(epoch: Double) -> String? {
        guard epoch.isFinite, epoch > 0 else { return nil }
        let seconds = epoch > 100_000_000_000 ? epoch / 1000 : epoch
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    public struct Allowance: Equatable, Sendable {
        public let usedPercent: Double
        /// Weekly reset for an included allowance; nil for a trial.
        public let resetsAt: Date?
        /// End of a trial allowance; nil for an included allowance.
        public let trialEndsAt: Date?
    }

    /// The Grok Bot allowance to show, or nil when the account has none.
    ///
    /// Included allowances keep their weekly reset. An unexpired trial shows its end date instead of a reset.
    /// A zero included allowance with no live trial is hidden rather than drawn as an empty bar.
    /// Payloads that report neither allowance field keep the previous behavior and show any usage percent.
    /// When Cursor says no usage is left (`hasAvailableUsage: false`), the allowance is exhausted even if the
    /// reported percent lags behind or is missing.
    public func allowance(now: Date = Date()) -> Allowance? {
        let exhausted = self.hasAvailableUsage == false
        guard let reported = self.usagePercent ?? (exhausted ? 100 : nil), reported.isFinite else { return nil }
        let used = exhausted ? 100 : max(0, min(100, reported))
        let hasIncluded = self.includedLimitZero.map { !$0 } ?? self.hasNonZeroIncludedLimit
        let trialEnd = Self.parseDate(self.sandTrialExpiresAt)
        if hasIncluded == true || (hasIncluded == nil && trialEnd == nil) {
            return Allowance(usedPercent: used, resetsAt: Self.parseDate(self.nextResetTimestampUtc), trialEndsAt: nil)
        }
        guard let trialEnd, trialEnd > now else { return nil }
        return Allowance(usedPercent: used, resetsAt: nil, trialEndsAt: trialEnd)
    }

    private static func parseDate(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
