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
        let rawGeminiQuotas = snapshot.modelQuotas.filter(Self.isGeminiModel)
        let filteredQuotas: [AntigravityModelQuota] = switch snapshot.source {
        case .local:
            rawGeminiQuotas
        case .remote:
            {
                let preferred = rawGeminiQuotas.filter { quota in
                    !Self.isRemoteCatalogNoise(quota) || (quota.remainingFraction ?? 1.0) < 0.999
                }
                return preferred.isEmpty ? rawGeminiQuotas : preferred
            }()
        }

        let geminiQuotas = Self.sortedQuotas(filteredQuotas)
        let summary = snapshot.geminiQuotaSummary
        guard summary?.hasReading == true || !geminiQuotas.isEmpty else {
            throw GeminiStatusProbeError.parseFailed("Gemini quota values are currently unavailable.")
        }

        let extraWindows = Self.deduplicatedExtraWindows(from: geminiQuotas)
        let identity = ProviderIdentitySnapshot(
            providerID: .gemini,
            accountEmail: snapshot.accountEmail,
            accountOrganization: nil,
            loginMethod: snapshot.accountPlan)

        return UsageSnapshot(
            primary: summary?.fiveHour,
            secondary: summary?.weekly,
            tertiary: nil,
            extraRateWindows: extraWindows.isEmpty ? nil : extraWindows,
            updatedAt: now,
            identity: identity)
    }

    private static func rateWindow(for quota: AntigravityModelQuota) -> RateWindow {
        RateWindow(
            usedPercent: 100 - quota.remainingPercent,
            windowMinutes: nil,
            resetsAt: quota.resetTime,
            resetDescription: quota.resetDescription)
    }

    /// Collapses effort-tier variants (`(High)`, `(Medium)`, `(Low)`, `(XHigh)`) of the same
    /// Gemini model when they share the same remaining quota and reset window.
    private static func deduplicatedExtraWindows(
        from quotas: [AntigravityModelQuota]) -> [NamedRateWindow]
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
                windows.append(NamedRateWindow(
                    id: "gemini-model-\(Self.slug(baseLabel))",
                    title: baseLabel,
                    window: Self.rateWindow(for: rep),
                    usageKnown: rep.remainingFraction != nil))
            } else {
                for item in items {
                    windows.append(NamedRateWindow(
                        id: "gemini-model-\(Self.slug(item.modelId))",
                        title: item.label,
                        window: Self.rateWindow(for: item),
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

    private static func isRemoteCatalogNoise(_ quota: AntigravityModelQuota) -> Bool {
        let modelID = quota.modelId.lowercased()
        let label = quota.label.lowercased()
        let combined = "\(modelID) \(label)"
        return combined.contains("image")
            || combined.contains("autocomplete")
            || modelID.hasPrefix("tab_")
            || combined.contains("tts")
            || combined.contains("live-translate")
            || combined.contains("embedding")
    }

    private static func sortedQuotas(_ quotas: [AntigravityModelQuota]) -> [AntigravityModelQuota] {
        quotas.sorted { lhs, rhs in
            let lhsRank = Self.modelSortRank(lhs)
            let rhsRank = Self.modelSortRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }

            let lhsVersion = Self.parseVersion(from: lhs.label) ?? Self.parseVersion(from: lhs.modelId)
            let rhsVersion = Self.parseVersion(from: rhs.label) ?? Self.parseVersion(from: rhs.modelId)
            if lhsVersion != rhsVersion {
                switch (lhsVersion, rhsVersion) {
                case let (.some(lv), .some(rv)):
                    return lv > rv
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    break
                }
            }

            let baseCompare = Self.baseModelLabel(lhs.label)
                .localizedCaseInsensitiveCompare(Self.baseModelLabel(rhs.label))
            if baseCompare != .orderedSame {
                return baseCompare == .orderedAscending
            }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    private static func modelSortRank(_ quota: AntigravityModelQuota) -> Int {
        let combined = "\(quota.modelId) \(quota.label)".lowercased()
        if combined.contains("orchestrator") { return 2 }
        if combined.contains("flash-lite") || combined.contains("flash lite") { return 3 }
        if combined.contains("flash") { return 1 }
        return 0
    }

    private struct ModelVersion: Comparable {
        let major: Int
        let minor: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            return lhs.minor < rhs.minor
        }
    }

    private static func parseVersion(from text: String) -> ModelVersion? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+)(?:[.\-](\d+))?"#) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let majorRange = Range(match.range(at: 1), in: text),
              let major = Int(text[majorRange])
        else {
            return nil
        }
        let minor: Int = if match.range(at: 2).location != NSNotFound,
                            let minorRange = Range(match.range(at: 2), in: text),
                            let parsed = Int(text[minorRange])
        {
            parsed
        } else {
            0
        }
        return ModelVersion(major: major, minor: minor)
    }

    static func baseModelLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(
            pattern: #"\s*\((?:x?high|medium|low|minimal|thinking|max)\)\s*$"#,
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
