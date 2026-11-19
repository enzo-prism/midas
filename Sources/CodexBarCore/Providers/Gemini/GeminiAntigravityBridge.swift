import Foundation

public enum GeminiOAuthCredentialsStore {
    public static func defaultDirectoryURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appendingPathComponent(".codexbar", isDirectory: true)
            .appendingPathComponent("gemini", isDirectory: true)
    }

    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        self.defaultDirectoryURL(home: home)
            .appendingPathComponent("oauth_creds.json")
    }

    public static func store(home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> AntigravityOAuthCredentialsStore
    {
        AntigravityOAuthCredentialsStore(fileURL: self.defaultURL(home: home))
    }
}

/// Projects Gemini-only quotas from an Antigravity / Cloud Code PA snapshot into a
/// siloed Gemini `UsageSnapshot`. Non-Gemini models (such as Claude or GPT) are excluded.
public enum GeminiAntigravityQuotaMapper {
    private static let weeklyThresholdSeconds: TimeInterval = 36 * 60 * 60
    private static let sessionThresholdSeconds: TimeInterval = 8 * 60 * 60
    private static let fiveHourWindowMinutes = 5 * 60
    private static let dailyWindowMinutes = 24 * 60
    private static let weeklyWindowMinutes = 7 * 24 * 60

    public static func isGeminiModel(_ quota: AntigravityModelQuota) -> Bool {
        let modelID = quota.modelId.lowercased()
        let label = quota.label.lowercased()
        if modelID.contains("claude") || label.contains("claude")
            || modelID.contains("openai") || label.contains("gpt")
        {
            return false
        }
        return modelID.contains("gemini") || label.contains("gemini")
    }

    public static func toUsageSnapshot(
        from snapshot: AntigravityStatusSnapshot,
        now: Date = Date()) throws -> UsageSnapshot
    {
        let geminiQuotas = snapshot.modelQuotas.filter(Self.isGeminiModel)
        guard !geminiQuotas.isEmpty else {
            throw GeminiStatusProbeError.parseFailed("No Gemini model quotas available.")
        }

        let knownQuotas = geminiQuotas.filter { $0.remainingFraction != nil }
        let weeklyQuotas = knownQuotas.filter { Self.isWeeklyQuota($0, now: now) }
        let shortQuotas = knownQuotas.filter { !Self.isWeeklyQuota($0, now: now) }

        let primary: RateWindow?
        let secondary: RateWindow?
        if !shortQuotas.isEmpty, !weeklyQuotas.isEmpty {
            let shortRep = Self.mostConstrained(in: shortQuotas)
            let weeklyRep = Self.mostConstrained(in: weeklyQuotas)
            primary = shortRep.map { Self.rateWindow(for: $0, now: now, forceWeekly: false) }
            secondary = weeklyRep.map { Self.rateWindow(for: $0, now: now, forceWeekly: true) }
        } else if !weeklyQuotas.isEmpty {
            primary = nil
            secondary = Self.mostConstrained(in: weeklyQuotas).map {
                Self.rateWindow(for: $0, now: now, forceWeekly: true)
            }
        } else if !shortQuotas.isEmpty {
            let proOrStandard = shortQuotas.filter { !Self.isFlashQuota($0) }
            let flash = shortQuotas.filter(Self.isFlashQuota)
            if !proOrStandard.isEmpty, !flash.isEmpty {
                primary = Self.mostConstrained(in: proOrStandard).map {
                    Self.rateWindow(for: $0, now: now, forceWeekly: false)
                }
                secondary = Self.mostConstrained(in: flash).map {
                    Self.rateWindow(for: $0, now: now, forceWeekly: false)
                }
            } else {
                primary = Self.mostConstrained(in: shortQuotas).map {
                    Self.rateWindow(for: $0, now: now, forceWeekly: false)
                }
                secondary = nil
            }
        } else {
            throw GeminiStatusProbeError.parseFailed("Gemini quota values are currently unavailable.")
        }

        let extraWindows = Self.deduplicatedExtraWindows(from: geminiQuotas, now: now)
        let identity = ProviderIdentitySnapshot(
            providerID: .gemini,
            accountEmail: snapshot.accountEmail,
            accountOrganization: nil,
            loginMethod: snapshot.accountPlan)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            extraRateWindows: extraWindows.isEmpty ? nil : extraWindows,
            updatedAt: now,
            identity: identity)
    }

    private static func isWeeklyQuota(_ quota: AntigravityModelQuota, now: Date) -> Bool {
        guard let resetTime = quota.resetTime else { return false }
        return resetTime.timeIntervalSince(now) > self.weeklyThresholdSeconds
    }

    private static func isFlashQuota(_ quota: AntigravityModelQuota) -> Bool {
        let combined = "\(quota.modelId) \(quota.label)".lowercased()
        return combined.contains("flash")
    }

    private static func windowMinutes(for quota: AntigravityModelQuota, now: Date, forceWeekly: Bool) -> Int? {
        if forceWeekly { return self.weeklyWindowMinutes }
        guard let resetTime = quota.resetTime else { return nil }
        let delta = resetTime.timeIntervalSince(now)
        if delta > self.weeklyThresholdSeconds {
            return self.weeklyWindowMinutes
        }
        if delta > self.sessionThresholdSeconds {
            return self.dailyWindowMinutes
        }
        if delta >= -60 {
            return self.fiveHourWindowMinutes
        }
        return nil
    }

    private static func rateWindow(
        for quota: AntigravityModelQuota,
        now: Date,
        forceWeekly: Bool) -> RateWindow
    {
        RateWindow(
            usedPercent: 100 - quota.remainingPercent,
            windowMinutes: self.windowMinutes(for: quota, now: now, forceWeekly: forceWeekly),
            resetsAt: quota.resetTime,
            resetDescription: quota.resetDescription)
    }

    private static func mostConstrained(in quotas: [AntigravityModelQuota]) -> AntigravityModelQuota? {
        quotas.min { lhs, rhs in
            if lhs.remainingPercent != rhs.remainingPercent {
                return lhs.remainingPercent < rhs.remainingPercent
            }
            switch (lhs.resetTime, rhs.resetTime) {
            case let (.some(left), .some(right)) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
        }
    }

    /// Collapses effort-tier variants (`(High)`, `(Medium)`, `(Low)`, `(XHigh)`) of the same
    /// Gemini model when they share the same remaining quota and reset window.
    private static func deduplicatedExtraWindows(
        from quotas: [AntigravityModelQuota],
        now: Date) -> [NamedRateWindow]
    {
        var grouped: [String: [AntigravityModelQuota]] = [:]
        var order: [String] = []
        for quota in quotas {
            let base = Self.baseModelLabel(quota.label)
            let key = base.lowercased()
            if grouped[key] == nil {
                order.append(key)
            }
            grouped[key, default: []].append(quota)
        }

        var windows: [NamedRateWindow] = []
        for key in order {
            guard let items = grouped[key], !items.isEmpty else { continue }
            let baseLabel = Self.baseModelLabel(items[0].label)
            if Self.allShareQuota(items), let rep = items.first {
                let isWeekly = Self.isWeeklyQuota(rep, now: now)
                windows.append(NamedRateWindow(
                    id: "gemini-model-\(Self.slug(baseLabel))",
                    title: baseLabel,
                    window: Self.rateWindow(for: rep, now: now, forceWeekly: isWeekly),
                    usageKnown: rep.remainingFraction != nil))
            } else {
                for item in items {
                    let isWeekly = Self.isWeeklyQuota(item, now: now)
                    windows.append(NamedRateWindow(
                        id: "gemini-model-\(Self.slug(item.modelId))",
                        title: item.label,
                        window: Self.rateWindow(for: item, now: now, forceWeekly: isWeekly),
                        usageKnown: item.remainingFraction != nil))
                }
            }
        }
        return windows
    }

    private static func allShareQuota(_ items: [AntigravityModelQuota]) -> Bool {
        guard let first = items.first else { return true }
        return items.dropFirst().allSatisfy { item in
            let sameKnown = (first.remainingFraction == nil) == (item.remainingFraction == nil)
            let samePercent = abs(first.remainingPercent - item.remainingPercent) < 0.05
            let sameReset: Bool = switch (first.resetTime, item.resetTime) {
            case let (.some(lhs), .some(rhs)):
                abs(lhs.timeIntervalSince(rhs)) < 60
            case (.none, .none):
                true
            default:
                false
            }
            return sameKnown && samePercent && sameReset
        }
    }

    static func baseModelLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(
            pattern: #"\s*\((?:x?high|medium|low|minimal|thinking)\)\s*$"#,
            options: [.caseInsensitive])
        else {
            return trimmed
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        let stripped = regex.stringByReplacingMatches(in: trimmed, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? trimmed : stripped
    }

    private static func slug(_ value: String) -> String {
        let lowered = value.lowercased()
        let allowed = lowered.map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
        }
        return String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }
}
