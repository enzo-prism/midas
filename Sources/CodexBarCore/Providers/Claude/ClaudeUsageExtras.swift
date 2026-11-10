import Foundation

/// Extra facts Claude's usage response carries beside the limit windows: saved limit resets,
/// usage-credit state, this week's usage by product, and how model-scoped limits sit inside the week.
///
/// The usage endpoints are undocumented, so every field is optional and parsing never throws.
public struct ClaudeUsageExtras: Codable, Sendable, Equatable {
    /// Saved limit resets. Live readings only: a cached or synced copy must never bring back a
    /// reset that was already used on claude.ai, so this is left out of `CodingKeys`.
    public var limitResets: ClaudeLimitResets?
    public var credits: ClaudeUsageCreditsState?
    public var productBreakdown: [ClaudeProductShare]
    public var scopedShares: [ClaudeScopedWeeklyShare]

    private enum CodingKeys: String, CodingKey {
        case credits
        case productBreakdown
        case scopedShares
    }

    public init(
        limitResets: ClaudeLimitResets? = nil,
        credits: ClaudeUsageCreditsState? = nil,
        productBreakdown: [ClaudeProductShare] = [],
        scopedShares: [ClaudeScopedWeeklyShare] = [])
    {
        self.limitResets = limitResets
        self.credits = credits
        self.productBreakdown = productBreakdown
        self.scopedShares = scopedShares
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.limitResets = nil
        self.credits = try container.decodeIfPresent(ClaudeUsageCreditsState.self, forKey: .credits)
        self.productBreakdown = try container.decodeIfPresent([ClaudeProductShare].self, forKey: .productBreakdown)
            ?? []
        self.scopedShares = try container.decodeIfPresent([ClaudeScopedWeeklyShare].self, forKey: .scopedShares)
            ?? []
    }

    public var isEmpty: Bool {
        self.limitResets == nil && self.credits == nil && self.productBreakdown.isEmpty && self.scopedShares.isEmpty
    }
}

/// Which limit a saved reset refills.
public enum ClaudeLimitResetKind: String, Sendable, Equatable, CaseIterable {
    case fiveHour
    case weekly
    /// Restores the usage a model-scoped allowance (currently Fable) took from the week.
    case scopedModel
    case other

    public var displayName: String {
        switch self {
        case .fiveHour: "5-hour"
        case .weekly: "Weekly"
        case .scopedModel: "Fable"
        case .other: "Limit"
        }
    }
}

/// One reset grant. Identifiers and labels from the response are deliberately not kept.
public struct ClaudeLimitResetGrant: Sendable, Equatable {
    public let kind: ClaudeLimitResetKind
    public let resetsLeft: Int
    public let startsAt: Date?
    public let endsAt: Date?
    public let paused: Bool
    /// Claude's own "can be used right now" flag; nil when the response omits it.
    public let usableNow: Bool?

    public init(
        kind: ClaudeLimitResetKind,
        resetsLeft: Int,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        paused: Bool = false,
        usableNow: Bool? = nil)
    {
        self.kind = kind
        self.resetsLeft = resetsLeft
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.paused = paused
        self.usableNow = usableNow
    }

    /// Held and inside its validity window at `now`.
    public func isAvailable(at now: Date) -> Bool {
        guard self.resetsLeft > 0, !self.paused else { return false }
        if let startsAt, startsAt > now { return false }
        if let endsAt, endsAt <= now { return false }
        return true
    }
}

public struct ClaudeLimitResets: Sendable, Equatable {
    public let eligible: Bool
    public let grants: [ClaudeLimitResetGrant]

    public init(eligible: Bool, grants: [ClaudeLimitResetGrant]) {
        self.eligible = eligible
        self.grants = grants
    }

    public func availableGrants(at now: Date = Date()) -> [ClaudeLimitResetGrant] {
        self.grants.filter { $0.isAvailable(at: now) }
    }

    public func availableCount(at now: Date = Date()) -> Int {
        self.availableGrants(at: now).reduce(0) { $0 + $1.resetsLeft }
    }

    /// Resets Claude says can be used right now; nil when no available grant reports the flag.
    public func usableNowCount(at now: Date = Date()) -> Int? {
        let available = self.availableGrants(at: now)
        guard available.contains(where: { $0.usableNow != nil }) else { return nil }
        return available.filter { $0.usableNow == true }.reduce(0) { $0 + $1.resetsLeft }
    }

    public func soonestExpiry(at now: Date = Date()) -> Date? {
        self.availableGrants(at: now).compactMap(\.endsAt).min()
    }

    /// Available resets per kind with the soonest expiry of that kind, in a stable order.
    public func summaryByKind(at now: Date = Date()) -> [KindSummary] {
        let available = self.availableGrants(at: now)
        return ClaudeLimitResetKind.allCases.compactMap { kind in
            let matching = available.filter { $0.kind == kind }
            let count = matching.reduce(0) { $0 + $1.resetsLeft }
            guard count > 0 else { return nil }
            return KindSummary(kind: kind, count: count, soonestExpiry: matching.compactMap(\.endsAt).min())
        }
    }

    public struct KindSummary: Sendable, Equatable {
        public let kind: ClaudeLimitResetKind
        public let count: Int
        public let soonestExpiry: Date?
    }
}

/// Usage credits ("extra usage"): what happens when a plan limit is reached.
public struct ClaudeUsageCreditsState: Codable, Sendable, Equatable {
    public let enabled: Bool?
    public let disabledReason: String?
    /// Prepaid balance in major currency units, when reported.
    public let balance: Double?
    public let autoReload: Bool?
    public let currencyCode: String?

    public init(
        enabled: Bool?,
        disabledReason: String? = nil,
        balance: Double? = nil,
        autoReload: Bool? = nil,
        currencyCode: String? = nil)
    {
        self.enabled = enabled
        self.disabledReason = disabledReason
        self.balance = balance
        self.autoReload = autoReload
        self.currencyCode = currencyCode
    }
}

public struct ClaudeProductShare: Codable, Sendable, Equatable {
    public let key: String
    public let displayName: String
    /// Share of this week's usage, 0...100.
    public let percent: Double

    public init(key: String, displayName: String, percent: Double) {
        self.key = key
        self.displayName = displayName
        self.percent = percent
    }
}

/// How a model-scoped weekly limit (Fable) relates to the all-models week.
public struct ClaudeScopedWeeklyShare: Codable, Sendable, Equatable {
    public let title: String
    public let usedPercentOfWeekly: Double?
    public let allowancePercentOfWeekly: Double?

    public init(title: String, usedPercentOfWeekly: Double?, allowancePercentOfWeekly: Double?) {
        self.title = title
        self.usedPercentOfWeekly = usedPercentOfWeekly
        self.allowancePercentOfWeekly = allowancePercentOfWeekly
    }
}

// MARK: - Parsing

public enum ClaudeUsageExtrasParser {
    /// Query item that asks the usage endpoint to include saved limit resets.
    public static let limitResetsQueryItem = URLQueryItem(name: "cedar_ember", value: "1")

    public static func parse(data: Data) -> ClaudeUsageExtras? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return self.parse(json: json)
    }

    public static func parse(json: [String: Any]) -> ClaudeUsageExtras? {
        let extras = ClaudeUsageExtras(
            limitResets: self.limitResets(from: json["cedar_ember"]),
            credits: self.credits(spend: json["spend"], extraUsage: json["extra_usage"]),
            productBreakdown: self.productBreakdown(from: json["seven_day_breakdown"]),
            scopedShares: self.scopedShares(from: json["weekly_scoped_shares"], limits: json["limits"]))
        return extras.isEmpty ? nil : extras
    }

    static func limitResets(from value: Any?) -> ClaudeLimitResets? {
        guard let block = value as? [String: Any] else { return nil }
        let rawGrants = block["grants"] as? [[String: Any]] ?? []
        let grants = rawGrants.compactMap { raw -> ClaudeLimitResetGrant? in
            guard let left = self.intValue(raw["resets_left"]) else { return nil }
            return ClaudeLimitResetGrant(
                kind: self.kind(clears: raw["clears"] as? [String], type: raw["type"] as? String),
                resetsLeft: max(0, left),
                startsAt: self.date(raw["starts_at"]),
                endsAt: self.date(raw["ends_at"]),
                paused: raw["paused"] as? Bool ?? false,
                usableNow: raw["usable_now"] as? Bool)
        }
        return ClaudeLimitResets(eligible: block["eligible"] as? Bool ?? !grants.isEmpty, grants: grants)
    }

    /// `clears` names the windows a reset refills; `type` is only a fallback because launch
    /// grants report `full` for a model-scoped reset.
    static func kind(clears: [String]?, type: String?) -> ClaudeLimitResetKind {
        if let clears, !clears.isEmpty {
            if clears.contains("seven_day") { return .weekly }
            if clears.contains(where: { $0.hasPrefix("seven_day_") }) { return .scopedModel }
            if clears.contains("five_hour") { return .fiveHour }
            return .other
        }
        switch type?.lowercased() {
        case "weekly": return .weekly
        case "five_hour", "session": return .fiveHour
        default: return .other
        }
    }

    static func credits(spend: Any?, extraUsage: Any?) -> ClaudeUsageCreditsState? {
        let spend = spend as? [String: Any]
        let extra = extraUsage as? [String: Any]
        guard spend != nil || extra != nil else { return nil }
        let enabled = spend?["enabled"] as? Bool ?? extra?["is_enabled"] as? Bool
        let reason = (spend?["disabled_reason"] as? String) ?? (extra?["disabled_reason"] as? String)
        let balanceMoney = spend?["balance"] as? [String: Any]
        let autoReload: Bool? = if let flag = spend?["auto_reload"] as? Bool {
            flag
        } else if let block = spend?["auto_reload"] as? [String: Any] {
            block["enabled"] as? Bool
        } else {
            nil
        }
        let currency = (balanceMoney?["currency"] as? String)
            ?? ((spend?["limit"] as? [String: Any])?["currency"] as? String)
            ?? (extra?["currency"] as? String)
        guard enabled != nil || reason != nil || balanceMoney != nil || autoReload != nil else { return nil }
        return ClaudeUsageCreditsState(
            enabled: enabled,
            disabledReason: reason,
            balance: self.money(balanceMoney),
            autoReload: autoReload,
            currencyCode: currency)
    }

    static func productBreakdown(from value: Any?) -> [ClaudeProductShare] {
        guard let block = value as? [String: Any], let rows = block["rows"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let key = row["key"] as? String, let percent = self.doubleValue(row["percent"]) else { return nil }
            let name = (row["display_name"] as? String) ?? key
            return ClaudeProductShare(key: key, displayName: name, percent: min(100, max(0, percent)))
        }
    }

    static func scopedShares(from value: Any?, limits: Any?) -> [ClaudeScopedWeeklyShare] {
        guard let shares = value as? [[String: Any]] else { return [] }
        let limits = limits as? [[String: Any]] ?? []
        return shares.compactMap { share in
            guard let index = self.intValue(share["limit_index"]), limits.indices.contains(index) else { return nil }
            let scope = limits[index]["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            guard let title = model?["display_name"] as? String, !title.isEmpty else { return nil }
            let used = self.doubleValue(share["used_percent_of_weekly"])
            let allowance = self.doubleValue(share["allowance_percent_of_weekly"])
            guard used != nil || allowance != nil else { return nil }
            return ClaudeScopedWeeklyShare(
                title: title,
                usedPercentOfWeekly: used,
                allowancePercentOfWeekly: allowance)
        }
    }

    private static func money(_ value: [String: Any]?) -> Double? {
        guard let value, let minor = self.doubleValue(value["amount_minor"]) else { return nil }
        let exponent = self.intValue(value["exponent"]) ?? 2
        return minor / pow(10, Double(max(0, exponent)))
    }

    /// JSONSerialization bridges 0 and 1 to `Bool` on request, so a real boolean is told apart by its type.
    private static func isJSONBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func intValue(_ value: Any?) -> Int? {
        if self.isJSONBool(value) { return nil }
        if let int = value as? Int { return int }
        if let double = value as? Double, double.isFinite { return Int(double) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if self.isJSONBool(value) { return nil }
        if let double = value as? Double, double.isFinite { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

// MARK: - Formatting

public enum ClaudeUsageExtrasFormatting {
    /// Headline for saved resets, e.g. "3 available" or "3 available · 1 usable now".
    public static func limitResetsCountText(_ resets: ClaudeLimitResets, now: Date = Date()) -> String {
        let available = resets.availableCount(at: now)
        let headline = "\(available) available"
        guard available > 0, let usable = resets.usableNowCount(at: now), usable < available else { return headline }
        return "\(headline) · \(usable) usable now"
    }

    /// Per-kind inventory with expiries, e.g. "1 Weekly reset, expires Dec 15, 8:59 PM · 2 Fable resets, …".
    public static func limitResetsHelpText(_ resets: ClaudeLimitResets, now: Date = Date()) -> String {
        let summary = resets.summaryByKind(at: now)
        guard !summary.isEmpty else { return "No saved limit resets." }
        let parts = summary.map { entry -> String in
            let noun = entry.count == 1 ? "reset" : "resets"
            let expiry = entry.soonestExpiry.map { ", expires \(Self.expiryText($0, now: now))" } ?? ""
            return "\(entry.count) \(entry.kind.displayName) \(noun)\(expiry)"
        }
        return parts.joined(separator: " · ") + ". Redeem in Claude under Settings › Usage."
    }

    /// Resets can expire months out, so an expiry in another year names the year.
    static func expiryText(_ date: Date, now: Date) -> String {
        let text = UsageFormatter.absoluteDateTimeText(date)
        let calendar = Calendar.current
        let year = calendar.component(.year, from: date)
        return year == calendar.component(.year, from: now) ? text : "\(text), \(year)"
    }

    /// One line on what happens at the limit, e.g. "Usage credits: off (out of credits) · auto-reload off".
    public static func creditsText(_ credits: ClaudeUsageCreditsState) -> String? {
        var parts: [String] = []
        if let enabled = credits.enabled {
            if enabled {
                parts.append("on")
            } else if let reason = self.disabledReasonText(credits.disabledReason) {
                parts.append("off (\(reason))")
            } else {
                parts.append("off")
            }
        }
        if let balance = credits.balance {
            let amount = UsageFormatter.currencyString(balance, currencyCode: credits.currencyCode ?? "USD")
            parts.append("\(amount) balance")
        }
        if let autoReload = credits.autoReload {
            parts.append(autoReload ? "auto-reload on" : "auto-reload off")
        }
        guard !parts.isEmpty else { return nil }
        return "Usage credits: " + parts.joined(separator: " · ")
    }

    static func disabledReasonText(_ reason: String?) -> String? {
        guard let reason, !reason.isEmpty else { return nil }
        switch reason {
        case "out_of_credits": return "out of credits"
        case "user_disabled": return "turned off"
        case "spend_limit_reached": return "spend limit reached"
        default: return reason.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// e.g. "This week by product: Claude Code 93% · Claude Duet 7%". Zero rows are dropped.
    public static func productBreakdownText(_ rows: [ClaudeProductShare]) -> String? {
        let used = rows.filter { $0.percent >= 0.5 }.sorted { $0.percent > $1.percent }
        guard !used.isEmpty else { return nil }
        let parts = used.map { "\($0.displayName) \(Int($0.percent.rounded()))%" }
        return "This week by product: " + parts.joined(separator: " · ")
    }

    /// e.g. "Fable can use up to 50% of the weekly limit (1% used so far)".
    public static func scopedShareText(_ share: ClaudeScopedWeeklyShare) -> String? {
        guard let allowance = share.allowancePercentOfWeekly else { return nil }
        var text = "\(share.title) can use up to \(Int(allowance.rounded()))% of the weekly limit"
        if let used = share.usedPercentOfWeekly {
            text += " (\(Int(used.rounded()))% used so far)"
        }
        return text
    }

    /// Detail-view lines for credits, product breakdown and scoped shares.
    public static func noteLines(_ extras: ClaudeUsageExtras) -> [String] {
        var lines: [String] = []
        if let credits = extras.credits, let text = self.creditsText(credits) { lines.append(text) }
        lines.append(contentsOf: extras.scopedShares.compactMap(self.scopedShareText))
        if let text = self.productBreakdownText(extras.productBreakdown) { lines.append(text) }
        return lines
    }
}
