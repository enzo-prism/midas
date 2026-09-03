import Foundation

/// Centralized rate-window durations for Codex / OpenAI.
///
/// Historically the literal minute counts `300` (5h session) and `10080` (7-day weekly) were
/// duplicated across the rate-window normalizer, the consumer projection, the dashboard parser,
/// and a handful of menu helpers. If OpenAI ever shifts the session window (e.g. to 4h or 6h),
/// each site had to move in lockstep. Concentrate them here so callers reference a single source
/// of truth and adding tolerance is a one-line change.
public enum CodexRateWindowDurations {
    /// Standard Codex 5-hour session window, expressed in minutes.
    public static let sessionMinutes: Int = 5 * 60

    /// Standard Codex 7-day weekly window, expressed in minutes.
    public static let weeklyMinutes: Int = 7 * 24 * 60

    /// Tolerance (in minutes) applied when classifying an observed window as session/weekly.
    /// OpenAI has occasionally returned slightly-off minute counts (e.g. 299 or 10081) due to
    /// clock skew between the client and rate-limit service; a small ±60s tolerance absorbs that
    /// without misclassifying the lane.
    public static let toleranceMinutes: Int = 1

    /// Returns true when the given window length should be treated as the session lane.
    public static func isSession(windowMinutes: Int?) -> Bool {
        guard let windowMinutes else { return false }
        return abs(windowMinutes - self.sessionMinutes) <= self.toleranceMinutes
    }

    /// Returns true when the given window length should be treated as the weekly lane.
    public static func isWeekly(windowMinutes: Int?) -> Bool {
        guard let windowMinutes else { return false }
        return abs(windowMinutes - self.weeklyMinutes) <= self.toleranceMinutes
    }
}
