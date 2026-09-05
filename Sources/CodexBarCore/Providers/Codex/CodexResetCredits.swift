import Foundation

/// One on-demand Codex rate-limit reset credit.
///
/// The `wham/usage` body only carries a count (`rate_limit_reset_credits.available_count`);
/// per-credit expiries come from the dedicated
/// `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` endpoint, whose
/// `credits[]` entries decode here. Decoding is fully tolerant: a malformed entry degrades
/// to placeholder values instead of discarding its valid siblings (see `CodexResetCreditsResponse`).
public struct CodexResetCredit: Codable, Sendable, Equatable {
    public let id: String
    public let resetType: String?
    public let status: String?
    public let grantedAt: Date?
    public let expiresAt: Date?
    public let title: String?
    public let description: String?
    public let isSupportedByPlan: Bool?

    public init(
        id: String,
        resetType: String? = nil,
        status: String? = nil,
        grantedAt: Date? = nil,
        expiresAt: Date? = nil,
        title: String? = nil,
        description: String? = nil,
        isSupportedByPlan: Bool? = nil)
    {
        self.id = id
        self.resetType = resetType
        self.status = status
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.title = title
        self.description = description
        self.isSupportedByPlan = isSupportedByPlan
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case resetType = "reset_type"
        case status
        case grantedAt = "granted_at"
        case expiresAt = "expires_at"
        case title
        case description
        case isSupportedByPlan = "is_supported_by_plan"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The id anchors claim/refresh matching; entries without one are still kept with a
        // placeholder so a single malformed entry can never drop the whole list.
        self.id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        self.resetType = try? container.decodeIfPresent(String.self, forKey: .resetType)
        self.status = try? container.decodeIfPresent(String.self, forKey: .status)
        self.grantedAt = Self.decodeDate(container: container, key: .grantedAt)
        self.expiresAt = Self.decodeDate(container: container, key: .expiresAt)
        self.title = try? container.decodeIfPresent(String.self, forKey: .title)
        self.description = try? container.decodeIfPresent(String.self, forKey: .description)
        self.isSupportedByPlan = try? container.decodeIfPresent(Bool.self, forKey: .isSupportedByPlan)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encodeIfPresent(self.resetType, forKey: .resetType)
        try container.encodeIfPresent(self.status, forKey: .status)
        try container.encodeIfPresent(Self.encodeDate(self.grantedAt), forKey: .grantedAt)
        try container.encodeIfPresent(Self.encodeDate(self.expiresAt), forKey: .expiresAt)
        try container.encodeIfPresent(self.title, forKey: .title)
        try container.encodeIfPresent(self.description, forKey: .description)
        try container.encodeIfPresent(self.isSupportedByPlan, forKey: .isSupportedByPlan)
    }

    /// Redeemable credits, soonest expiry first. Credits without an expiry sort last.
    public var isAvailable: Bool {
        self.status?.lowercased() == "available"
    }

    private static func decodeDate(container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Date? {
        guard let raw = try? container.decodeIfPresent(String.self, forKey: key), !raw.isEmpty else {
            return nil
        }
        return Self.iso8601Date(from: raw)
    }

    static func encodeDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        return Self.iso8601String(from: date)
    }

    static func iso8601Date(from raw: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// Decoded body of `GET /wham/rate-limit-reset-credits`.
///
/// `availableCount` is authoritative for the count; `credits` carries the per-credit
/// expiries. Either may be absent, so callers fall back to the count embedded in the
/// `wham/usage` body (which carries no expiries) when this call fails.
public struct CodexResetCreditsResponse: Decodable, Sendable {
    public let credits: [CodexResetCredit]
    public let availableCount: Int?
    public let totalEarnedCount: Int?

    private enum CodingKeys: String, CodingKey {
        case credits
        case availableCount = "available_count"
        case totalEarnedCount = "total_earned_count"
    }

    public init(credits: [CodexResetCredit], availableCount: Int?, totalEarnedCount: Int? = nil) {
        self.credits = credits
        self.availableCount = availableCount
        self.totalEarnedCount = totalEarnedCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Decode per element so one malformed credit cannot discard its valid siblings.
        let decodedCredits = try? container.decodeIfPresent([LossyCodexResetCredit].self, forKey: .credits)
        self.credits = decodedCredits?.compactMap(\.value) ?? []
        self.availableCount = try? container.decodeIfPresent(Int.self, forKey: .availableCount)
        self.totalEarnedCount = try? container.decodeIfPresent(Int.self, forKey: .totalEarnedCount)
        guard self.availableCount != nil || decodedCredits != nil else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Reset credits response has neither a count nor a credits list"))
        }
    }

    private struct LossyCodexResetCredit: Decodable {
        let value: CodexResetCredit?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.value = try? container.decode(CodexResetCredit.self)
        }
    }
}

/// What the app persists and renders for Codex rate-limit reset credits.
public struct CodexResetCreditsSnapshot: Codable, Sendable, Equatable {
    /// All known credits (including spent ones); use `availableCredits` for the redeemable set.
    public let credits: [CodexResetCredit]
    /// Authoritative count (`available_count`); may exceed `availableCredits.count` when the
    /// dedicated per-credit call failed and only the usage-body count is known.
    public let availableCount: Int
    /// False when built from the usage-body count fallback, which carries no per-credit expiries.
    public let hasPerCreditExpiries: Bool
    public let updatedAt: Date

    public init(
        credits: [CodexResetCredit],
        availableCount: Int,
        hasPerCreditExpiries: Bool,
        updatedAt: Date)
    {
        self.credits = credits
        self.availableCount = availableCount
        self.hasPerCreditExpiries = hasPerCreditExpiries
        self.updatedAt = updatedAt
    }

    /// Count-only fallback from the `wham/usage` body (`rate_limit_reset_credits`).
    public static func countOnly(availableCount: Int, updatedAt: Date) -> CodexResetCreditsSnapshot {
        CodexResetCreditsSnapshot(
            credits: [],
            availableCount: availableCount,
            hasPerCreditExpiries: false,
            updatedAt: updatedAt)
    }

    public static func fromResponse(
        _ response: CodexResetCreditsResponse,
        fallbackAvailableCount: Int? = nil,
        updatedAt: Date) -> CodexResetCreditsSnapshot
    {
        let available = response.credits.filter(\.isAvailable)
        return CodexResetCreditsSnapshot(
            credits: response.credits,
            availableCount: response.availableCount ?? fallbackAvailableCount ?? available.count,
            hasPerCreditExpiries: true,
            updatedAt: updatedAt)
    }

    /// Redeemable credits, soonest expiry first.
    public var availableCredits: [CodexResetCredit] {
        self.credits.filter(\.isAvailable).sorted {
            switch ($0.expiresAt, $1.expiresAt) {
            case let (lhs?, rhs?):
                lhs < rhs
            case (.some, .none):
                true
            case (.none, .some):
                false
            case (.none, .none):
                $0.id < $1.id
            }
        }
    }

    public var soonestExpiry: Date? {
        self.availableCredits.compactMap(\.expiresAt).min()
    }

    /// Urgency of the soonest expiry: red within 48h, yellow within a week, blue beyond.
    public enum ExpiryUrgency: Sendable, Equatable {
        case none
        case distant
        case soon
        case imminent
    }

    public func expiryUrgency(now: Date = Date()) -> ExpiryUrgency {
        guard self.availableCount > 0 else { return .none }
        guard let soonest = self.soonestExpiry else { return .distant }
        let interval = soonest.timeIntervalSince(now)
        if interval <= 48 * 3600 { return .imminent }
        if interval <= 7 * 24 * 3600 { return .soon }
        return .distant
    }
}

/// Display text for Codex rate-limit reset credits. English literals follow the same
/// precedent as `UsageFormatter.resetCountdownDescription` (countdowns stay unlocalized
/// in core; the app localizes row titles via `L()`).
public enum CodexResetCreditFormatting {
    /// Headline count, e.g. "2 available".
    public static func countText(availableCount: Int) -> String {
        "\(availableCount) available"
    }

    /// Absolute expiry, e.g. "Oct 4, 2:38 AM". Always includes the date.
    public static func absoluteExpiryText(_ date: Date) -> String {
        UsageFormatter.absoluteDateTimeText(date)
    }

    /// One-line soonest-expiry detail for under the count, or nil when there is nothing
    /// useful to add (zero credits). Falls back to an explicit "unavailable" note when
    /// only the usage-body count is known.
    public static func soonestDetail(
        snapshot: CodexResetCreditsSnapshot,
        now: Date = Date()) -> String?
    {
        guard snapshot.availableCount > 0 else { return nil }
        guard let soonest = snapshot.soonestExpiry else {
            return "Expiry times unavailable"
        }
        let countdown = UsageFormatter.resetCountdownDescription(from: soonest, now: now)
        return "Soonest expires \(Self.absoluteExpiryText(soonest)) (\(countdown))"
    }

    /// Multi-line tooltip timeline, soonest first: "1. Expires Oct 4, 2:38 AM (in 29d 18h)".
    /// Falls back to the count with an explicit note when expiries are unknown, and to an
    /// empty-state line when there are no credits.
    public static func tooltipText(
        snapshot: CodexResetCreditsSnapshot,
        now: Date = Date()) -> String
    {
        guard snapshot.availableCount > 0 else {
            return "You have no rate limit resets"
        }
        let available = snapshot.availableCredits
        guard !available.isEmpty, snapshot.hasPerCreditExpiries else {
            return "\(Self.countText(availableCount: snapshot.availableCount)) — expiry times unavailable"
        }
        var lines = available.enumerated().map { index, credit in
            var line = "\(index + 1). "
            if let expiresAt = credit.expiresAt {
                let countdown = UsageFormatter.resetCountdownDescription(from: expiresAt, now: now)
                line += "Expires \(Self.absoluteExpiryText(expiresAt)) (\(countdown))"
            } else {
                line += "Expiry unknown"
            }
            if let title = credit.title?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty
            {
                line += " — \(title)"
            }
            return line
        }
        let missingCount = snapshot.availableCount - available.count
        if missingCount > 0 {
            lines.append("\(missingCount) additional reset\(missingCount == 1 ? "" : "s"): expiry times unavailable")
        }
        return lines.joined(separator: "\n")
    }
}
