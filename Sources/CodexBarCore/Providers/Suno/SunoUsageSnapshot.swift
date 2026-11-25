import Foundation

/// `data` of `suno credits --json` (envelope version 1).
struct SunoCreditsResponse: Decodable {
    struct Plan: Decodable {
        let name: String?
        let planKey: String?

        private enum CodingKeys: String, CodingKey {
            case name
            case planKey = "plan_key"
        }
    }

    struct DownloadUsage: Decodable {
        let used: Int?
        let limit: Int?
        let additionalRemaining: Int?

        private enum CodingKeys: String, CodingKey {
            case used = "current_period_downloads_used"
            case limit = "current_period_downloads_limit"
            case additionalRemaining = "additional_download_remaining"
        }
    }

    let credits: Int?
    let totalCreditsLeft: Int?
    let monthlyUsage: Int?
    let monthlyLimit: Int?
    let isActive: Bool?
    let plan: Plan?
    let period: String?
    let renewsOn: String?
    let downloadUsage: DownloadUsage?

    private enum CodingKeys: String, CodingKey {
        case credits
        case totalCreditsLeft = "total_credits_left"
        case monthlyUsage = "monthly_usage"
        case monthlyLimit = "monthly_limit"
        case isActive = "is_active"
        case plan
        case period
        case renewsOn = "renews_on"
        case downloadUsage = "download_usage"
    }
}

public struct SunoUsageSnapshot: Codable, Sendable, Equatable {
    public let planName: String?
    public let isActive: Bool
    /// Billing period reported by Suno (`month` on paid plans).
    public let period: String?
    public let creditsUsed: Int
    public let creditLimit: Int
    /// Plan credits left plus purchased top-up credits, as Suno reports it.
    public let totalCreditsLeft: Int?
    /// Purchased top-up credits outside the plan allowance.
    public let topUpCredits: Int?
    public let downloadsUsed: Int?
    public let downloadLimit: Int?
    public let additionalDownloadsRemaining: Int?
    public let renewsAt: Date?
    public let updatedAt: Date

    public init(
        planName: String?,
        isActive: Bool,
        period: String?,
        creditsUsed: Int,
        creditLimit: Int,
        totalCreditsLeft: Int?,
        topUpCredits: Int?,
        downloadsUsed: Int?,
        downloadLimit: Int?,
        additionalDownloadsRemaining: Int?,
        renewsAt: Date?,
        updatedAt: Date)
    {
        self.planName = planName
        self.isActive = isActive
        self.period = period
        self.creditsUsed = creditsUsed
        self.creditLimit = creditLimit
        self.totalCreditsLeft = totalCreditsLeft
        self.topUpCredits = topUpCredits
        self.downloadsUsed = downloadsUsed
        self.downloadLimit = downloadLimit
        self.additionalDownloadsRemaining = additionalDownloadsRemaining
        self.renewsAt = renewsAt
        self.updatedAt = updatedAt
    }

    public var creditsUsedPercent: Double {
        guard self.creditLimit > 0 else { return 0 }
        return max(0, Double(self.creditsUsed) / Double(self.creditLimit) * 100)
    }

    public var planCreditsLeft: Int {
        max(0, self.creditLimit - self.creditsUsed)
    }

    /// Plan name without Suno's "Plan" suffix ("Pro Plan" → "Pro"), with an inactive marker.
    public var displayPlan: String? {
        let trimmed = self.planName?
            .replacingOccurrences(of: #"\s*plan$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.flatMap { $0.isEmpty ? nil : $0 }
        if self.isActive { return name }
        return "\(name ?? "Subscription") · Inactive"
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let windowMinutes = Self.periodMinutes(period: self.period, endingAt: self.renewsAt)
        var creditSummary = "\(Self.format(self.creditsUsed)) / \(Self.format(self.creditLimit)) credits"
        if let topUp = self.topUpCredits, topUp > 0 {
            creditSummary += " · +\(Self.format(topUp)) top-up"
        }
        let primary = RateWindow(
            usedPercent: self.creditsUsedPercent,
            windowMinutes: windowMinutes,
            resetsAt: self.renewsAt,
            resetDescription: creditSummary)

        var secondary: RateWindow?
        if let used = self.downloadsUsed, let limit = self.downloadLimit, limit > 0, used >= 0 {
            var summary = "\(Self.format(used)) / \(Self.format(limit)) downloads"
            if let extra = self.additionalDownloadsRemaining, extra > 0 {
                summary += " · +\(Self.format(extra)) extra"
            }
            secondary = RateWindow(
                usedPercent: Double(used) / Double(limit) * 100,
                windowMinutes: windowMinutes,
                resetsAt: self.renewsAt,
                resetDescription: summary)
        }

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            subscriptionRenewsAt: self.renewsAt,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .suno,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: self.displayPlan))
    }

    /// Length of the billing period that ends at `renewsAt`, so pace tracks the real calendar
    /// month (28–31 days) instead of a fixed 30.
    static func periodMinutes(period: String?, endingAt end: Date?) -> Int? {
        let component: Calendar.Component? = switch period?.lowercased() {
        case "month", "monthly": .month
        case "year", "yearly", "annual": .year
        case "week", "weekly": .weekOfYear
        case "day", "daily": .day
        default: nil
        }
        guard let component else { return nil }
        guard let end else {
            return component == .day ? 24 * 60 : component == .weekOfYear ? 7 * 24 * 60 : nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        guard let start = calendar.date(byAdding: component, value: -1, to: end) else { return nil }
        let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
        return minutes > 0 ? minutes : nil
    }

    static func format(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

public enum SunoUsageError: LocalizedError, Sendable, Equatable {
    case cliNotInstalled
    case signedOut(String?)
    case rateLimited
    case cliFailed(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cliNotInstalled:
            "Suno CLI not found. Install the `suno` CLI, then run `suno auth --login` in Terminal."
        case let .signedOut(detail):
            if let detail, !detail.isEmpty {
                "The Suno CLI is signed out (\(detail)). Run `suno auth --login` in Terminal."
            } else {
                "The Suno CLI is signed out. Run `suno auth --login` in Terminal."
            }
        case .rateLimited:
            "Suno is rate limiting requests. Midas will try again on the next refresh."
        case let .cliFailed(message):
            "Suno CLI error: \(message)"
        case let .parseFailed(message):
            "Failed to parse Suno credits: \(message)"
        }
    }
}

enum SunoCreditsParser {
    /// Exit codes from `suno agent-info`: 1 transient, 2 config/auth, 3 bad input, 4 rate limited.
    static func parse(stdout: String, stderr: String, exitCode: Int32, updatedAt: Date) throws -> SunoUsageSnapshot {
        // Success goes to stdout; since suno 0.10.1 failures use a single stderr envelope.
        for output in [stdout, stderr] {
            guard let envelope = self.envelope(in: output) else { continue }
            let status = (envelope["status"] as? String)?.lowercased()
            if status == "error" || envelope["error"] != nil {
                throw self.failure(envelope["error"], exitCode: exitCode)
            }
            if status == "success", let data = envelope["data"] {
                return try self.snapshot(from: data, updatedAt: updatedAt)
            }
        }

        if exitCode == 2 { throw SunoUsageError.signedOut(nil) }
        if exitCode == 4 { throw SunoUsageError.rateLimited }
        let message = self.firstLine(of: stderr) ?? self.firstLine(of: stdout)
        if exitCode == 0 {
            throw SunoUsageError.parseFailed(message ?? "The Suno CLI returned no credit data.")
        }
        throw SunoUsageError.cliFailed(message ?? "exit code \(exitCode)")
    }

    private static func snapshot(from data: Any, updatedAt: Date) throws -> SunoUsageSnapshot {
        let decoded: SunoCreditsResponse
        do {
            let json = try JSONSerialization.data(withJSONObject: data)
            decoded = try JSONDecoder().decode(SunoCreditsResponse.self, from: json)
        } catch {
            throw SunoUsageError.parseFailed(error.localizedDescription)
        }
        guard let used = decoded.monthlyUsage, let limit = decoded.monthlyLimit, used >= 0, limit > 0 else {
            throw SunoUsageError.parseFailed("Suno did not report a credit allowance.")
        }
        let downloads = decoded.downloadUsage
        return SunoUsageSnapshot(
            planName: decoded.plan?.name ?? decoded.plan?.planKey,
            isActive: decoded.isActive ?? true,
            period: decoded.period,
            creditsUsed: used,
            creditLimit: limit,
            totalCreditsLeft: decoded.totalCreditsLeft,
            topUpCredits: decoded.credits,
            downloadsUsed: downloads?.used,
            downloadLimit: downloads?.limit,
            additionalDownloadsRemaining: downloads?.additionalRemaining,
            renewsAt: decoded.renewsOn.flatMap(self.date(from:)),
            updatedAt: updatedAt)
    }

    /// `{ version, status, error: { code, message, suggestion, details? } }`
    private static func failure(_ error: Any?, exitCode: Int32) -> SunoUsageError {
        let details = error as? [String: Any]
        let code = (details?["code"] as? String)?.lowercased() ?? ""
        let message = (details?["message"] as? String) ?? (error as? String) ?? ""
        let lowered = message.lowercased()
        if exitCode == 2 || code.contains("auth") || code.contains("token") || lowered.contains("auth") {
            return .signedOut(code.isEmpty ? nil : code)
        }
        if exitCode == 4 || code.contains("rate") {
            return .rateLimited
        }
        return .cliFailed(message.isEmpty ? (code.isEmpty ? "exit code \(exitCode)" : code) : message)
    }

    private static func envelope(in output: String) -> [String: Any]? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8)),
              let envelope = object as? [String: Any],
              envelope["status"] != nil || envelope["error"] != nil
        else { return nil }
        return envelope
    }

    private static func date(from raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private static func firstLine(of output: String) -> String? {
        let line = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line else { return nil }
        return line.count > 240 ? String(line.prefix(240)) + "…" : line
    }
}
