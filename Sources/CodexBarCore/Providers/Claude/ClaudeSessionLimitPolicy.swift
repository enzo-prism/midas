import Foundation

/// Decides whether a Claude usage payload describes a real 5-hour session limit.
///
/// Since 2026-10-30 verified Ultra accounts (the renamed Max 20x plan) have no 5-hour limit, only weekly
/// limits; claude.ai's Settings > Usage drops its "Current session" bar for them. The usage APIs signal this
/// by leaving the session out of the `limits` list, by returning `five_hour: null`, or by returning a stub
/// that stays at 0% with no reset time however much the account is used. Showing that stub as a "5-hour
/// limit: 0%" bar would be wrong, so the snapshot gets no session window instead.
public enum ClaudeSessionLimitPolicy {
    /// What one usage payload says about the session window.
    public struct Evidence: Sendable {
        /// `five_hour.utilization`, or the session entry's percent from `limits`.
        public let usedPercent: Double?
        public let resetsAt: Date?
        /// True when the payload carried a full `limits` list (one that names the all-models weekly limit),
        /// as opposed to a partial list of scoped extras.
        public let hasLimitsList: Bool
        /// True when that list holds a `session` entry.
        public let limitsListHasSession: Bool
        public let plan: ClaudePlan?

        public init(
            usedPercent: Double?,
            resetsAt: Date?,
            hasLimitsList: Bool = false,
            limitsListHasSession: Bool = false,
            plan: ClaudePlan?)
        {
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
            self.hasLimitsList = hasLimitsList
            self.limitsListHasSession = limitsListHasSession
            self.plan = plan
        }
    }

    public static func hasSessionLimit(_ evidence: Evidence) -> Bool {
        // The `limits` list is the newest and most explicit shape: no session entry means no session limit.
        if evidence.hasLimitsList, !evidence.limitsListHasSession {
            return false
        }
        guard let usedPercent = evidence.usedPercent else { return false }
        // An idle Pro or Max session also reads 0% with no reset, so this stub only means "no limit" on Ultra.
        // An unverified Ultra account with a temporary limit gets its bar back as soon as a window starts.
        if evidence.plan == .ultra, usedPercent <= 0, evidence.resetsAt == nil {
            return false
        }
        return true
    }

    /// `limits` entries that describe the 5-hour session window.
    public static func isSessionLimitEntry(kind: String?, group: String?) -> Bool {
        let kind = kind?.lowercased()
        let group = group?.lowercased()
        return group == "session" || kind == "session" || kind == "five_hour"
    }

    /// A `limits` list that names the all-models weekly limit lists every account limit, so a missing
    /// session entry there is meaningful.
    public static func isCompleteLimitsList(kinds: [String?]) -> Bool {
        kinds.contains { $0?.lowercased() == "weekly_all" }
    }
}
