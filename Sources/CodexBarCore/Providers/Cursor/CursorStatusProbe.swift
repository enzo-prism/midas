import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SweetCookieKit

#if os(macOS)

private let cursorCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.cursor]?.browserCookieOrder ?? Browser.defaultImportOrder

// MARK: - Cursor Cookie Importer

/// Imports Cursor session cookies from browser cookies.
public enum CursorCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    private static let sessionCookieNames: Set<String> = [
        "WorkosCursorSessionToken",
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
        // WorkOS AuthKit (common default; configurable server-side)
        "wos-session",
        "__Secure-wos-session",
        // Auth.js v5
        "authjs.session-token",
        "__Secure-authjs.session-token",
    ]

    /// Hosts whose cookies may authenticate Cursor web/API requests.
    private static let cookieDomains = [
        "cursor.com",
        "www.cursor.com",
        "cursor.sh",
        "authenticator.cursor.sh",
    ]

    public struct SessionInfo: Sendable {
        public let cookies: [HTTPCookie]
        public let sourceLabel: String

        public init(cookies: [HTTPCookie], sourceLabel: String) {
            self.cookies = cookies
            self.sourceLabel = sourceLabel
        }

        public var cookieHeader: String {
            self.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
    }

    /// Reads Cursor session cookies from one browser if present (no fallback to other browsers).
    static func importSessionIfPresent(
        browser: Browser,
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) -> SessionInfo?
    {
        self.importSessionsIfPresent(
            browser: browser,
            browserDetection: browserDetection,
            logger: logger).first
    }

    /// Reads all Cursor session-cookie candidates from one browser source order.
    static func importSessionsIfPresent(
        browser: Browser,
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) -> [SessionInfo]
    {
        self.importCookiesFromBrowser(
            browser: browser,
            browserDetection: browserDetection,
            requireKnownSessionName: true,
            logger: logger)
    }

    /// Like ``importSessionIfPresent`` but accepts any non-empty cookie set for Cursor domains so the API can validate
    /// (used after the strict name pass fails — e.g. new cookie names or host-only cookies).
    static func importDomainCookiesIfPresent(
        browser: Browser,
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) -> SessionInfo?
    {
        self.importDomainCookieSessionsIfPresent(
            browser: browser,
            browserDetection: browserDetection,
            logger: logger).first
    }

    /// Reads fallback cookie candidates whose names are not already covered by the strict session-cookie pass.
    static func importDomainCookieSessionsIfPresent(
        browser: Browser,
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) -> [SessionInfo]
    {
        self.importCookiesFromBrowser(
            browser: browser,
            browserDetection: browserDetection,
            requireKnownSessionName: false,
            logger: logger)
    }

    private static func importCookiesFromBrowser(
        browser: Browser,
        browserDetection: BrowserDetection,
        requireKnownSessionName: Bool,
        logger: ((String) -> Void)?) -> [SessionInfo]
    {
        let log: (String) -> Void = { msg in logger?("[cursor-cookie] \(msg)") }
        guard browserDetection.isCookieSourceAvailable(browser) else { return [] }
        guard BrowserCookieAccessGate.shouldAttempt(browser) else { return [] }

        do {
            let query = BrowserCookieQuery(domains: Self.cookieDomains)
            let sources = try Self.cookieClient.codexBarRecords(
                matching: query,
                in: browser,
                logger: log)
            var sessions: [SessionInfo] = []
            for source in sources where !source.records.isEmpty {
                let httpCookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                let hasNamedSession = httpCookies.contains(where: { Self.sessionCookieNames.contains($0.name) })
                if hasNamedSession {
                    log("Found \(httpCookies.count) Cursor cookies in \(source.label)")
                    if requireKnownSessionName {
                        sessions.append(SessionInfo(cookies: httpCookies, sourceLabel: source.label))
                    }
                    continue
                }
                if !requireKnownSessionName, !httpCookies.isEmpty {
                    log(
                        "Found \(httpCookies.count) Cursor domain cookies in \(source.label) "
                            + "(no known session name); will validate via API")
                    sessions.append(SessionInfo(
                        cookies: httpCookies,
                        sourceLabel: "\(source.label) (domain cookies)"))
                    continue
                }
                log("\(source.label) cookies found, but no Cursor session cookie present")
            }
            return sessions
        } catch {
            BrowserCookieAccessGate.recordIfNeeded(error)
            log("\(browser.displayName) cookie import failed: \(error.localizedDescription)")
        }
        return []
    }

    /// Attempts to import Cursor cookies using the standard browser import order.
    public static func importSession(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let installedBrowsers = cursorCookieImportOrder.cookieImportCandidates(using: browserDetection)
        for browserSource in installedBrowsers {
            if let session = Self.importSessionsIfPresent(
                browser: browserSource,
                browserDetection: browserDetection,
                logger: logger).first
            {
                return session
            }
        }
        for browserSource in installedBrowsers {
            if let session = Self.importDomainCookieSessionsIfPresent(
                browser: browserSource,
                browserDetection: browserDetection,
                logger: logger).first
            {
                return session
            }
        }

        throw CursorStatusProbeError.noSessionCookie
    }

    /// Check if Cursor session cookies are available
    public static func hasSession(browserDetection: BrowserDetection, logger: ((String) -> Void)? = nil) -> Bool {
        do {
            let session = try self.importSession(browserDetection: browserDetection, logger: logger)
            return !session.cookies.isEmpty
        } catch {
            return false
        }
    }
}

// MARK: - Cursor API Models

public struct CursorUsageSummary: Codable, Sendable {
    public let billingCycleStart: String?
    public let billingCycleEnd: String?
    public let membershipType: String?
    public let limitType: String?
    public let isUnlimited: Bool?
    public let autoModelSelectedDisplayMessage: String?
    public let namedModelSelectedDisplayMessage: String?
    public let individualUsage: CursorIndividualUsage?
    public let teamUsage: CursorTeamUsage?
}

public struct CursorIndividualUsage: Codable, Sendable {
    public let plan: CursorPlanUsage?
    public let onDemand: CursorOnDemandUsage?
    /// Enterprise / team-member personal cap. Reported by Cursor when the account is part of a team or
    /// enterprise plan with an individual quota. Values follow the same cents-based units as `plan`.
    public let overall: CursorOverallUsage?
    /// Bot quota for agentic background runs. Same cents-based units as `plan`.
    public let botUsage: CursorBotUsage?
    /// Plan spend split between Cursor-served and third-party models (cents).
    public let modelSplit: CursorModelSplit?

    public init(
        plan: CursorPlanUsage? = nil,
        onDemand: CursorOnDemandUsage? = nil,
        overall: CursorOverallUsage? = nil,
        botUsage: CursorBotUsage? = nil,
        modelSplit: CursorModelSplit? = nil)
    {
        self.plan = plan
        self.onDemand = onDemand
        self.overall = overall
        self.botUsage = botUsage
        self.modelSplit = modelSplit
    }
}

/// Bot quota block (cents). Reported under `individualUsage.botUsage` for accounts with a bot
/// quota, or under `teamUsage.botUsage` for the shared team bot pool.
public struct CursorBotUsage: Codable, Sendable {
    public let enabled: Bool?
    /// Bot usage in cents (e.g., 7500 = $75.00)
    public let used: Int?
    /// Bot limit in cents. `nil` indicates an unlimited or unreported bot quota.
    public let limit: Int?
    /// Bot remaining in cents.
    public let remaining: Int?

    public init(enabled: Bool? = nil, used: Int? = nil, limit: Int? = nil, remaining: Int? = nil) {
        self.enabled = enabled
        self.used = used
        self.limit = limit
        self.remaining = remaining
    }
}

/// Plan spend split between Cursor-served models and third-party (non-Cursor) models.
/// Reported under `individualUsage.modelSplit`. Values are in cents.
public struct CursorModelSplit: Codable, Sendable {
    /// Spend in cents on Cursor-served models.
    public let cursorModelCents: Int?
    /// Spend in cents on non-Cursor (third-party) models.
    public let nonCursorModelCents: Int?

    public init(cursorModelCents: Int? = nil, nonCursorModelCents: Int? = nil) {
        self.cursorModelCents = cursorModelCents
        self.nonCursorModelCents = nonCursorModelCents
    }

    /// Total reported model spend in cents.
    public var totalCents: Int {
        (self.cursorModelCents ?? 0) + (self.nonCursorModelCents ?? 0)
    }

    /// Share (0-100) of reported model spend on Cursor-served models. `nil` when nothing reported.
    public var cursorSharePercent: Double? {
        let total = self.totalCents
        guard total > 0 else { return nil }
        return (Double(self.cursorModelCents ?? 0) / Double(total)) * 100
    }
}

/// Personal cap reported under `individualUsage.overall` for Enterprise/Team members.
/// Mirrors the shape of `CursorOnDemandUsage`; values are in cents.
public struct CursorOverallUsage: Codable, Sendable {
    public let enabled: Bool?
    /// Usage in cents (e.g., 7384 = $73.84)
    public let used: Int?
    /// Limit in cents (e.g., 10000 = $100.00). `nil` indicates the API omitted a numeric cap.
    public let limit: Int?
    /// Remaining in cents.
    public let remaining: Int?

    public init(enabled: Bool? = nil, used: Int? = nil, limit: Int? = nil, remaining: Int? = nil) {
        self.enabled = enabled
        self.used = used
        self.limit = limit
        self.remaining = remaining
    }
}

public struct CursorPlanUsage: Codable, Sendable {
    public let enabled: Bool?
    /// Usage in cents (e.g., 2000 = $20.00)
    public let used: Int?
    /// Limit in cents (e.g., 2000 = $20.00)
    public let limit: Int?
    /// Remaining in cents
    public let remaining: Int?
    public let breakdown: CursorPlanBreakdown?
    public let autoPercentUsed: Double?
    public let apiPercentUsed: Double?
    public let totalPercentUsed: Double?
}

public struct CursorPlanBreakdown: Codable, Sendable {
    public let included: Int?
    public let bonus: Int?
    public let total: Int?
}

public struct CursorOnDemandUsage: Codable, Sendable {
    public let enabled: Bool?
    /// Usage in cents
    public let used: Int?
    /// Limit in cents (nil if unlimited)
    public let limit: Int?
    /// Remaining in cents (nil if unlimited)
    public let remaining: Int?
}

public struct CursorTeamUsage: Codable, Sendable {
    public let onDemand: CursorOnDemandUsage?
    /// Shared team/enterprise pool counted across all members. Same cents-based units as the other usage blocks.
    public let pooled: CursorPooledUsage?
    /// Shared team bot pool for agentic background runs. Same cents-based units as `pooled`.
    public let botUsage: CursorBotUsage?

    public init(
        onDemand: CursorOnDemandUsage? = nil,
        pooled: CursorPooledUsage? = nil,
        botUsage: CursorBotUsage? = nil)
    {
        self.onDemand = onDemand
        self.pooled = pooled
        self.botUsage = botUsage
    }
}

/// Shared team/enterprise pool reported under `teamUsage.pooled`. Values are in cents.
public struct CursorPooledUsage: Codable, Sendable {
    public let enabled: Bool?
    /// Pool usage in cents.
    public let used: Int?
    /// Pool limit in cents. `nil` indicates an unlimited or unreported pool.
    public let limit: Int?
    /// Pool remaining in cents.
    public let remaining: Int?

    public init(enabled: Bool? = nil, used: Int? = nil, limit: Int? = nil, remaining: Int? = nil) {
        self.enabled = enabled
        self.used = used
        self.limit = limit
        self.remaining = remaining
    }
}

/// Dashboard usage pools from `POST /api/dashboard/get-current-period-usage` (body `{}`).
/// This is the same endpoint backing cursor.com/dashboard/usage: the Cursor Models pool
/// (auto bucket) and the Other Models pool (API usage), resetting at `billingCycleEnd`.
/// All members optional: team accounts may require a teamId body this probe does not send.
public struct CursorPeriodUsage: Codable, Sendable {
    public struct PoolUsage: Codable, Sendable {
        /// Cursor Models pool usage percent (e.g. 80 means 80% used).
        public let autoPercentUsed: Double?
        /// Other Models pool usage percent.
        public let apiPercentUsed: Double?
        public let totalPercentUsed: Double?

        public init(
            autoPercentUsed: Double? = nil,
            apiPercentUsed: Double? = nil,
            totalPercentUsed: Double? = nil)
        {
            self.autoPercentUsed = autoPercentUsed
            self.apiPercentUsed = apiPercentUsed
            self.totalPercentUsed = totalPercentUsed
        }
    }

    public let billingCycleStart: String?
    public let billingCycleEnd: String?
    public let planUsage: PoolUsage?
    /// Model ids in the Cursor Models pool (e.g. grok + composer builds). Anything else
    /// served outside this list counts toward Other Models; `sand-*` belongs to Grok Bot.
    public let autoBucketModels: [String]?

    public init(
        billingCycleStart: String? = nil,
        billingCycleEnd: String? = nil,
        planUsage: PoolUsage? = nil,
        autoBucketModels: [String]? = nil)
    {
        self.billingCycleStart = billingCycleStart
        self.billingCycleEnd = billingCycleEnd
        self.planUsage = planUsage
        self.autoBucketModels = autoBucketModels
    }
}

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

    public init(
        currentPeriodStart: String? = nil,
        nextResetTimestampUtc: String? = nil,
        usagePercent: Double? = nil,
        hasAvailableUsage: Bool? = nil,
        hasNonZeroIncludedLimit: Bool? = nil,
        grokPlanLabel: String? = nil)
    {
        self.currentPeriodStart = currentPeriodStart
        self.nextResetTimestampUtc = nextResetTimestampUtc
        self.usagePercent = usagePercent
        self.hasAvailableUsage = hasAvailableUsage
        self.hasNonZeroIncludedLimit = hasNonZeroIncludedLimit
        self.grokPlanLabel = grokPlanLabel
    }
}

// MARK: - Cursor Usage API Models (Legacy Request-Based Plans)

/// Response from `/api/usage?user=ID` endpoint for legacy request-based plans.
public struct CursorUsageResponse: Codable, Sendable {
    public let gpt4: CursorModelUsage?
    public let startOfMonth: String?

    enum CodingKeys: String, CodingKey {
        case gpt4 = "gpt-4"
        case startOfMonth
    }
}

public struct CursorModelUsage: Codable, Sendable {
    public let numRequests: Int?
    public let numRequestsTotal: Int?
    public let numTokens: Int?
    public let maxRequestUsage: Int?
    public let maxTokenUsage: Int?
}

public struct CursorUserInfo: Codable, Sendable {
    public let email: String?
    public let emailVerified: Bool?
    public let name: String?
    public let sub: String?
    public let createdAt: String?
    public let updatedAt: String?
    public let picture: String?

    enum CodingKeys: String, CodingKey {
        case email
        case emailVerified = "email_verified"
        case name
        case sub
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case picture
    }
}

// MARK: - Cursor Status Snapshot

public struct CursorStatusSnapshot: Sendable {
    /// Percentage of included plan usage (0-100) — the "Total" headline number from Cursor's UI
    public let planPercentUsed: Double
    /// Auto + Composer usage percent (0-100), nil when not available
    public let autoPercentUsed: Double?
    /// API (named model) usage percent (0-100), nil when not available
    public let apiPercentUsed: Double?
    /// Included plan usage in USD
    public let planUsedUSD: Double
    /// Included plan limit in USD
    public let planLimitUSD: Double
    /// On-demand usage in USD
    public let onDemandUsedUSD: Double
    /// On-demand limit in USD (nil if unlimited)
    public let onDemandLimitUSD: Double?
    /// Team on-demand usage in USD (for team plans)
    public let teamOnDemandUsedUSD: Double?
    /// Team on-demand limit in USD
    public let teamOnDemandLimitUSD: Double?
    /// Billing cycle start date
    public let billingCycleStart: Date?
    /// Billing cycle reset date
    public let billingCycleEnd: Date?
    /// Membership type (e.g., "enterprise", "pro", "hobby")
    public let membershipType: String?
    /// User email
    public let accountEmail: String?
    /// User name
    public let accountName: String?
    /// Raw API response for debugging
    public let rawJSON: String?

    // MARK: - Legacy Plan (Request-Based) Fields

    /// Requests used this billing cycle (legacy plans only)
    public let requestsUsed: Int?
    /// Request limit (non-nil indicates legacy request-based plan)
    public let requestsLimit: Int?
    /// Bot quota usage in USD.
    public let botUsedUSD: Double
    /// Bot quota limit in USD (nil when the API reports no bot quota).
    public let botLimitUSD: Double?
    /// Plan spend on Cursor-served models in USD (nil when unreported).
    public let cursorModelUsedUSD: Double?
    /// Plan spend on third-party (non-Cursor) models in USD (nil when unreported).
    public let nonCursorModelUsedUSD: Double?
    /// Dashboard Cursor Models pool usage percent (nil when the dashboard endpoint omits it).
    public let cursorModelsUsedPercent: Double?
    /// Dashboard Other Models pool usage percent (nil when the dashboard endpoint omits it).
    public let otherModelsUsedPercent: Double?
    /// Grok Bot weekly usage percent (nil when the plan has no Grok feature).
    public let grokBotWeeklyUsedPercent: Double?
    /// Grok Bot weekly reset (nil when unreported).
    public let grokBotWeeklyReset: Date?

    /// Whether this is a legacy request-based plan (vs token-based)
    public var isLegacyRequestPlan: Bool {
        self.requestsLimit != nil
    }

    /// Bot quota used percent (0-100), nil when the API reports no bot quota.
    public var botUsedPercent: Double? {
        guard let limit = self.botLimitUSD, limit > 0 else { return nil }
        return max(0, min(100, (self.botUsedUSD / limit) * 100))
    }

    /// Share (0-100) of reported model spend on Cursor-served models, nil when unreported.
    public var cursorModelSharePercent: Double? {
        let cursor = self.cursorModelUsedUSD ?? 0
        let other = self.nonCursorModelUsedUSD ?? 0
        let total = cursor + other
        guard total > 0 else { return nil }
        return (cursor / total) * 100
    }

    public init(
        planPercentUsed: Double,
        autoPercentUsed: Double? = nil,
        apiPercentUsed: Double? = nil,
        planUsedUSD: Double,
        planLimitUSD: Double,
        onDemandUsedUSD: Double,
        onDemandLimitUSD: Double?,
        teamOnDemandUsedUSD: Double?,
        teamOnDemandLimitUSD: Double?,
        billingCycleStart: Date? = nil,
        billingCycleEnd: Date?,
        membershipType: String?,
        accountEmail: String?,
        accountName: String?,
        rawJSON: String?,
        requestsUsed: Int? = nil,
        requestsLimit: Int? = nil,
        botUsedUSD: Double = 0,
        botLimitUSD: Double? = nil,
        cursorModelUsedUSD: Double? = nil,
        nonCursorModelUsedUSD: Double? = nil,
        cursorModelsUsedPercent: Double? = nil,
        otherModelsUsedPercent: Double? = nil,
        grokBotWeeklyUsedPercent: Double? = nil,
        grokBotWeeklyReset: Date? = nil)
    {
        self.planPercentUsed = planPercentUsed
        self.autoPercentUsed = autoPercentUsed
        self.apiPercentUsed = apiPercentUsed
        self.planUsedUSD = planUsedUSD
        self.planLimitUSD = planLimitUSD
        self.onDemandUsedUSD = onDemandUsedUSD
        self.onDemandLimitUSD = onDemandLimitUSD
        self.teamOnDemandUsedUSD = teamOnDemandUsedUSD
        self.teamOnDemandLimitUSD = teamOnDemandLimitUSD
        self.billingCycleStart = billingCycleStart
        self.billingCycleEnd = billingCycleEnd
        self.membershipType = membershipType
        self.accountEmail = accountEmail
        self.accountName = accountName
        self.rawJSON = rawJSON
        self.requestsUsed = requestsUsed
        self.requestsLimit = requestsLimit
        self.botUsedUSD = botUsedUSD
        self.botLimitUSD = botLimitUSD
        self.cursorModelUsedUSD = cursorModelUsedUSD
        self.nonCursorModelUsedUSD = nonCursorModelUsedUSD
        self.cursorModelsUsedPercent = cursorModelsUsedPercent
        self.otherModelsUsedPercent = otherModelsUsedPercent
        self.grokBotWeeklyUsedPercent = grokBotWeeklyUsedPercent
        self.grokBotWeeklyReset = grokBotWeeklyReset
    }

    /// Convert to UsageSnapshot for the common provider interface
    public func toUsageSnapshot() -> UsageSnapshot {
        let cursorRequests: CursorRequestUsage? = if let used = self.requestsUsed,
                                                     let limit = self.requestsLimit,
                                                     limit > 0
        {
            CursorRequestUsage(used: used, limit: limit)
        } else {
            nil
        }

        // Primary: For usable legacy request quotas, use request usage; otherwise preserve plan percentage.
        let primaryUsedPercent = cursorRequests?.usedPercent ?? self.planPercentUsed

        let billingCycleWindowMinutes = Self.billingCycleWindowMinutes(
            start: self.billingCycleStart,
            end: self.billingCycleEnd)

        let primary = RateWindow(
            usedPercent: primaryUsedPercent,
            windowMinutes: billingCycleWindowMinutes,
            resetsAt: self.billingCycleEnd,
            resetDescription: self.billingCycleEnd.map { Self.formatResetDate($0) })

        // Secondary/Tertiary (Auto and API bars) are intentionally dropped: the Cursor
        // tab shows Total plus the dashboard pool rows (Cursor Models, Other Models,
        // Grok Bot), which already break down the same spend without the redundant bars.
        // The parsed `autoPercentUsed`/`apiPercentUsed` fields stay on the snapshot.
        let secondary: RateWindow? = nil
        let tertiary: RateWindow? = nil

        // Prefer a personal cap. Team accounts with no user cap expose only the shared on-demand budget.
        let resolvedOnDemandUsed: Double
        let resolvedOnDemandLimit: Double?
        if (self.onDemandLimitUSD ?? 0) > 0 {
            resolvedOnDemandUsed = self.onDemandUsedUSD
            resolvedOnDemandLimit = self.onDemandLimitUSD
        } else if (self.teamOnDemandLimitUSD ?? 0) > 0 {
            resolvedOnDemandUsed = self.teamOnDemandUsedUSD ?? 0
            resolvedOnDemandLimit = self.teamOnDemandLimitUSD
        } else {
            resolvedOnDemandUsed = self.onDemandUsedUSD
            resolvedOnDemandLimit = self.onDemandLimitUSD
        }

        // Provider cost snapshot for on-demand usage (include budget before first spend)
        let providerCost: ProviderCostSnapshot? = if resolvedOnDemandUsed > 0
            || (resolvedOnDemandLimit ?? 0) > 0
        {
            ProviderCostSnapshot(
                used: resolvedOnDemandUsed,
                limit: resolvedOnDemandLimit ?? 0,
                currencyCode: "USD",
                period: "Monthly",
                resetsAt: self.billingCycleEnd,
                updatedAt: Date())
        } else {
            nil
        }

        // Bot quota row: only when the API reports a bot limit, so accounts without bot
        // usage keep the existing card layout untouched.
        var extraWindows: [NamedRateWindow]?
        if let botLimit = self.botLimitUSD, botLimit > 0 {
            let botUsedPercent = max(0, min(100, (self.botUsedUSD / botLimit) * 100))
            extraWindows = [NamedRateWindow(
                id: "cursor-bot",
                title: "Bot",
                window: RateWindow(
                    usedPercent: botUsedPercent,
                    windowMinutes: billingCycleWindowMinutes,
                    resetsAt: self.billingCycleEnd,
                    resetDescription: nil))]
        }

        // Model mix row: the bar shows the Cursor-served share of reported model spend.
        if let modelShare = self.cursorModelSharePercent {
            let modelsWindow = NamedRateWindow(
                id: "cursor-models",
                title: "Models",
                window: RateWindow(
                    usedPercent: modelShare,
                    windowMinutes: nil,
                    resetsAt: nil,
                    resetDescription: nil))
            extraWindows = (extraWindows ?? []) + [modelsWindow]
        }

        // Dashboard pool rows (cursor.com/dashboard/usage): usage-left for the Cursor Models
        // pool, the Other Models pool, and the Grok Bot weekly window. Each renders only when
        // its dashboard endpoint reported a percent, so other plans keep their layout untouched.
        if let cursorPool = self.cursorModelsUsedPercent {
            extraWindows = (extraWindows ?? []) + [NamedRateWindow(
                id: "cursor-pool-models",
                title: "Cursor Models",
                window: RateWindow(
                    usedPercent: cursorPool,
                    windowMinutes: billingCycleWindowMinutes,
                    resetsAt: self.billingCycleEnd,
                    resetDescription: self.billingCycleEnd.map { Self.formatResetDate($0) }))]
        }
        if let otherPool = self.otherModelsUsedPercent {
            extraWindows = (extraWindows ?? []) + [NamedRateWindow(
                id: "cursor-pool-other",
                title: "Other Models",
                window: RateWindow(
                    usedPercent: otherPool,
                    windowMinutes: billingCycleWindowMinutes,
                    resetsAt: self.billingCycleEnd,
                    resetDescription: self.billingCycleEnd.map { Self.formatResetDate($0) }))]
        }
        if let grokWeekly = self.grokBotWeeklyUsedPercent {
            extraWindows = (extraWindows ?? []) + [NamedRateWindow(
                id: "cursor-grok-bot",
                title: "Grok Bot",
                window: RateWindow(
                    // The Grok Bot window is weekly ("Weekly usage" on the dashboard).
                    usedPercent: grokWeekly,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: self.grokBotWeeklyReset,
                    resetDescription: self.grokBotWeeklyReset.map { Self.formatResetDate($0) }))]
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .cursor,
            accountEmail: self.accountEmail,
            accountOrganization: nil,
            loginMethod: self.membershipType.map { Self.formatMembershipType($0) })
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            extraRateWindows: extraWindows,
            providerCost: providerCost,
            cursorRequests: cursorRequests,
            updatedAt: Date(),
            identity: identity)
    }

    private static func formatResetDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d 'at' h:mma"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "Resets " + formatter.string(from: date)
    }

    private static func billingCycleWindowMinutes(start: Date?, end: Date?) -> Int? {
        guard let start,
              let end
        else { return nil }
        let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
        return minutes > 0 ? minutes : nil
    }

    private static func formatMembershipType(_ type: String) -> String {
        switch type.lowercased() {
        case "enterprise":
            "Cursor Enterprise"
        case "pro":
            "Cursor Pro"
        case "hobby":
            "Cursor Hobby"
        case "team":
            "Cursor Team"
        default:
            "Cursor \(type.capitalized)"
        }
    }
}

// MARK: - Cursor Status Probe Error

public enum CursorStatusProbeError: LocalizedError, Sendable {
    case notLoggedIn
    case networkError(String)
    case parseFailed(String)
    case noSessionCookie

    static let safariFullDiskAccessHint =
        "If you use Safari, grant CodexBar Full Disk Access in System Settings ▸ Privacy & Security."

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Not logged in to Cursor. Please log in via the CodexBar menu."
        case let .networkError(msg):
            "Cursor API error: \(msg)"
        case let .parseFailed(msg):
            "Could not parse Cursor usage: \(msg)"
        case .noSessionCookie:
            "No Cursor session found. \(Self.safariFullDiskAccessHint) "
                + "Please log in to cursor.com in \(cursorCookieImportOrder.loginHint). "
                + "You can also sign in to Cursor from the CodexBar menu (Add / switch account)."
        }
    }
}

// MARK: - Cursor Session Store

public actor CursorSessionStore {
    public static let shared = CursorSessionStore()

    private var sessionCookies: [HTTPCookie] = []
    private var hasLoadedFromDisk = false
    private let fileURL: URL

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = appSupport.appendingPathComponent("CodexBar", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("cursor-session.json")

        // Load saved cookies on init
        Task { await self.loadFromDiskIfNeeded() }
    }

    public func setCookies(_ cookies: [HTTPCookie]) {
        self.hasLoadedFromDisk = true
        self.sessionCookies = cookies
        self.saveToDisk()
    }

    public func getCookies() -> [HTTPCookie] {
        self.loadFromDiskIfNeeded()
        return self.sessionCookies
    }

    public func clearCookies() {
        self.hasLoadedFromDisk = true
        self.sessionCookies = []
        try? FileManager.default.removeItem(at: self.fileURL)
    }

    public func hasValidSession() -> Bool {
        self.loadFromDiskIfNeeded()
        return !self.sessionCookies.isEmpty
    }

    #if DEBUG
    func resetForTesting(clearDisk: Bool = true) {
        self.hasLoadedFromDisk = false
        self.sessionCookies = []
        if clearDisk {
            try? FileManager.default.removeItem(at: self.fileURL)
        }
    }
    #endif

    private func loadFromDiskIfNeeded() {
        guard !self.hasLoadedFromDisk else { return }
        self.hasLoadedFromDisk = true
        self.loadFromDisk()
    }

    private func saveToDisk() {
        // Convert cookie properties to JSON-serializable format
        // Date values must be converted to TimeInterval (Double)
        let cookieData = self.sessionCookies.compactMap { cookie -> [String: Any]? in
            guard let props = cookie.properties else { return nil }
            var serializable: [String: Any] = [:]
            for (key, value) in props {
                let keyString = key.rawValue
                if let date = value as? Date {
                    // Convert Date to TimeInterval for JSON compatibility
                    serializable[keyString] = date.timeIntervalSince1970
                    serializable[keyString + "_isDate"] = true
                } else if let url = value as? URL {
                    serializable[keyString] = url.absoluteString
                    serializable[keyString + "_isURL"] = true
                } else if JSONSerialization.isValidJSONObject([value]) ||
                    value is String ||
                    value is Bool ||
                    value is NSNumber
                {
                    serializable[keyString] = value
                }
            }
            return serializable
        }
        guard !cookieData.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: cookieData, options: [.prettyPrinted])
        else {
            return
        }
        try? data.write(to: self.fileURL)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: self.fileURL),
              let cookieArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }

        self.sessionCookies = cookieArray.compactMap { props in
            // Convert back to HTTPCookiePropertyKey dictionary
            var cookieProps: [HTTPCookiePropertyKey: Any] = [:]
            for (key, value) in props {
                // Skip marker keys
                if key.hasSuffix("_isDate") || key.hasSuffix("_isURL") { continue }

                let propKey = HTTPCookiePropertyKey(key)

                // Check if this was a Date
                if props[key + "_isDate"] as? Bool == true, let interval = value as? TimeInterval {
                    cookieProps[propKey] = Date(timeIntervalSince1970: interval)
                }
                // Check if this was a URL
                else if props[key + "_isURL"] as? Bool == true, let urlString = value as? String {
                    cookieProps[propKey] = URL(string: urlString)
                } else {
                    cookieProps[propKey] = value
                }
            }
            return HTTPCookie(properties: cookieProps)
        }
    }
}

// MARK: - Cursor Status Probe

public struct CursorStatusProbe: Sendable {
    public let baseURL: URL
    public var timeout: TimeInterval = 15.0
    private let browserDetection: BrowserDetection
    private let urlSession: any ProviderHTTPTransport

    public init(
        baseURL: URL = URL(string: "https://cursor.com")!,
        timeout: TimeInterval = 15.0,
        browserDetection: BrowserDetection,
        urlSession: any ProviderHTTPTransport = ProviderHTTPClient.shared)
    {
        self.baseURL = baseURL
        self.timeout = timeout
        self.browserDetection = browserDetection
        self.urlSession = urlSession
    }

    /// Fetch Cursor usage with manual cookie header (for debugging).
    public func fetchWithManualCookies(_ cookieHeader: String) async throws -> CursorStatusSnapshot {
        try await self.fetchWithCookieHeader(cookieHeader)
    }

    /// Fetch Cursor usage using browser cookies with fallback to stored session.
    public func fetch(
        cookieHeaderOverride: String? = nil,
        allowCachedSessions: Bool = true,
        logger: ((String) -> Void)? = nil)
        async throws -> CursorStatusSnapshot
    {
        let log: (String) -> Void = { msg in logger?("[cursor] \(msg)") }
        var firstRecoverableError: CursorStatusProbeError?

        if let override = CookieHeaderNormalizer.normalize(cookieHeaderOverride) {
            log("Using manual cookie header")
            return try await self.fetchWithCookieHeader(override)
        }

        if allowCachedSessions,
           let cached = CookieHeaderCache.load(provider: .cursor),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            log("Using cached cookie header from \(cached.sourceLabel)")
            do {
                return try await self.fetchWithCookieHeader(cached.cookieHeader)
            } catch let error as CursorStatusProbeError {
                if case .notLoggedIn = error {
                    CookieHeaderCache.clear(provider: .cursor)
                } else {
                    throw error
                }
            } catch {
                throw error
            }
        }

        // Try each browser in order. The first browser that *has* session cookie names is not always valid
        // (e.g. stale Chrome tokens); keep trying until the API accepts a session or we run out of browsers.
        let browserCandidates = cursorCookieImportOrder.cookieImportCandidates(using: self.browserDetection)
        switch await self.scanBrowsers(
            browserCandidates,
            importSessions: { browser in
                CursorCookieImporter.importSessionsIfPresent(
                    browser: browser,
                    browserDetection: self.browserDetection,
                    logger: log)
            },
            attemptFetch: { session in
                await self.fetchIfSessionAccepted(session, log: log)
            })
        {
        case let .succeeded(snapshot):
            return snapshot
        case let .exhausted(error):
            firstRecoverableError = error ?? firstRecoverableError
        }

        switch await self.scanBrowsers(
            browserCandidates,
            importSessions: { browser in
                CursorCookieImporter.importDomainCookieSessionsIfPresent(
                    browser: browser,
                    browserDetection: self.browserDetection,
                    logger: log)
            },
            attemptFetch: { session in
                await self.fetchIfSessionAccepted(session, log: log)
            })
        {
        case let .succeeded(snapshot):
            return snapshot
        case let .exhausted(error):
            firstRecoverableError = error ?? firstRecoverableError
        }

        // Fall back to stored session cookies (from "Add Account" login flow)
        if allowCachedSessions {
            let storedCookies = await CursorSessionStore.shared.getCookies()
            if !storedCookies.isEmpty {
                log("Using stored session cookies")
                let cookieHeader = storedCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                do {
                    return try await self.fetchWithCookieHeader(cookieHeader)
                } catch let error as CursorStatusProbeError {
                    if case .notLoggedIn = error {
                        // Clear only when auth is invalid; keep for transient failures.
                        await CursorSessionStore.shared.clearCookies()
                        log("Stored session invalid, cleared")
                    } else {
                        log("Stored session failed: \(error.localizedDescription)")
                        firstRecoverableError = firstRecoverableError ?? error
                    }
                } catch {
                    log("Stored session failed: \(error.localizedDescription)")
                    firstRecoverableError = firstRecoverableError ?? .networkError(error.localizedDescription)
                }
            }
        }

        if let firstRecoverableError {
            throw firstRecoverableError
        }

        throw CursorStatusProbeError.noSessionCookie
    }

    /// Fetch Cursor token-cost data using the same session resolution as status: manual
    /// override, cached header, browser sessions (strict then domain cookies), stored session.
    /// Returns the API-rate per-day, per-model breakdown plus the Cursor-metered window total.
    public func fetchCostReport(
        since: Date?,
        until: Date?,
        calendar: Calendar = .current,
        cookieHeaderOverride: String? = nil,
        allowCachedSessions: Bool = true,
        logger: ((String) -> Void)? = nil) async throws -> CursorCostReport
    {
        let log: (String) -> Void = { msg in logger?("[cursor-cost] \(msg)") }
        let fetcher = CursorUsageEventsFetcher(
            baseURL: self.baseURL,
            transport: self.urlSession,
            timeout: self.timeout)
        func run(_ cookieHeader: String) async throws -> CursorCostReport {
            let result = try await fetcher.fetchUsage(
                cookieHeader: cookieHeader,
                since: since,
                until: until,
                calendar: calendar,
                logger: logger)
            return CursorCostReport(daily: result.daily, meteredCostUSD: result.meteredCostUSD)
        }
        var firstRecoverableError: CursorStatusProbeError?

        if let override = CookieHeaderNormalizer.normalize(cookieHeaderOverride) {
            log("Using manual cookie header")
            return try await run(override)
        }

        if allowCachedSessions,
           let cached = CookieHeaderCache.load(provider: .cursor),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            log("Using cached cookie header from \(cached.sourceLabel)")
            do {
                return try await run(cached.cookieHeader)
            } catch let error as CursorStatusProbeError {
                if case .notLoggedIn = error {
                    CookieHeaderCache.clear(provider: .cursor)
                } else {
                    throw error
                }
            } catch {
                throw error
            }
        }

        // Try each browser in order, strict session names first, then domain cookies —
        // mirroring status fetch. A rejected session moves to the next candidate.
        let browserCandidates = cursorCookieImportOrder.cookieImportCandidates(using: self.browserDetection)
        let strictSessions = browserCandidates.flatMap {
            CursorCookieImporter.importSessionsIfPresent(
                browser: $0,
                browserDetection: self.browserDetection,
                logger: log)
        }
        let domainSessions = browserCandidates.flatMap {
            CursorCookieImporter.importDomainCookieSessionsIfPresent(
                browser: $0,
                browserDetection: self.browserDetection,
                logger: log)
        }
        for session in strictSessions + domainSessions {
            log("Trying Cursor cost session from \(session.sourceLabel)")
            do {
                let report = try await run(session.cookieHeader)
                CookieHeaderCache.store(
                    provider: .cursor,
                    cookieHeader: session.cookieHeader,
                    sourceLabel: session.sourceLabel)
                return report
            } catch let error as CursorStatusProbeError {
                if case .notLoggedIn = error {
                    log("Cursor API rejected cookies from \(session.sourceLabel); trying next browser if any")
                    firstRecoverableError = firstRecoverableError ?? error
                    continue
                }
                log("Cursor cost fetch failed using \(session.sourceLabel): \(error.localizedDescription)")
                firstRecoverableError = firstRecoverableError ?? error
            } catch {
                log("Cursor cost fetch failed using \(session.sourceLabel): \(error.localizedDescription)")
                firstRecoverableError = firstRecoverableError ?? .networkError(error.localizedDescription)
            }
        }

        // Fall back to stored session cookies (from "Add Account" login flow)
        if allowCachedSessions {
            let storedCookies = await CursorSessionStore.shared.getCookies()
            if !storedCookies.isEmpty {
                log("Using stored session cookies")
                let cookieHeader = storedCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                do {
                    return try await run(cookieHeader)
                } catch let error as CursorStatusProbeError {
                    if case .notLoggedIn = error {
                        await CursorSessionStore.shared.clearCookies()
                        log("Stored session invalid, cleared")
                    } else {
                        log("Stored session failed: \(error.localizedDescription)")
                        firstRecoverableError = firstRecoverableError ?? error
                    }
                } catch {
                    log("Stored session failed: \(error.localizedDescription)")
                    firstRecoverableError = firstRecoverableError ?? .networkError(error.localizedDescription)
                }
            }
        }

        if let firstRecoverableError {
            throw firstRecoverableError
        }

        throw CursorStatusProbeError.noSessionCookie
    }

    enum ImportedSessionFetchOutcome {
        case succeeded(CursorStatusSnapshot)
        case tryNextBrowser
        case failed(CursorStatusProbeError)
    }

    enum ImportedSessionScanResult {
        case succeeded(CursorStatusSnapshot)
        case exhausted(CursorStatusProbeError?)
    }

    func scanBrowsers(
        _ browsers: [Browser],
        importSessions: (Browser) -> [CursorCookieImporter.SessionInfo],
        attemptFetch: (CursorCookieImporter.SessionInfo) async -> ImportedSessionFetchOutcome) async
        -> ImportedSessionScanResult
    {
        var firstFailure: CursorStatusProbeError?

        for browser in browsers {
            let sessions = importSessions(browser)
            guard !sessions.isEmpty else { continue }
            for session in sessions {
                switch await attemptFetch(session) {
                case let .succeeded(snapshot):
                    return .succeeded(snapshot)
                case .tryNextBrowser:
                    continue
                case let .failed(error):
                    firstFailure = firstFailure ?? error
                }
            }
        }

        return .exhausted(firstFailure)
    }

    func scanImportedSessions(
        _ sessions: [CursorCookieImporter.SessionInfo],
        attemptFetch: (CursorCookieImporter.SessionInfo) async -> ImportedSessionFetchOutcome) async
        -> ImportedSessionScanResult
    {
        var firstFailure: CursorStatusProbeError?

        for session in sessions {
            switch await attemptFetch(session) {
            case let .succeeded(snapshot):
                return .succeeded(snapshot)
            case .tryNextBrowser:
                continue
            case let .failed(error):
                firstFailure = firstFailure ?? error
            }
        }

        return .exhausted(firstFailure)
    }

    private func fetchIfSessionAccepted(
        _ session: CursorCookieImporter.SessionInfo,
        log: @escaping (String) -> Void) async -> ImportedSessionFetchOutcome
    {
        log("Trying Cursor session from \(session.sourceLabel)")
        do {
            let snapshot = try await self.fetchWithCookieHeader(session.cookieHeader)
            CookieHeaderCache.store(
                provider: .cursor,
                cookieHeader: session.cookieHeader,
                sourceLabel: session.sourceLabel)
            return .succeeded(snapshot)
        } catch let error as CursorStatusProbeError {
            if case .notLoggedIn = error {
                log("Cursor API rejected cookies from \(session.sourceLabel); trying next browser if any")
                return .tryNextBrowser
            }
            log("Cursor fetch failed using \(session.sourceLabel): \(error.localizedDescription)")
            return .failed(error)
        } catch {
            log("Cursor fetch failed using \(session.sourceLabel): \(error.localizedDescription)")
            return .failed(.networkError(error.localizedDescription))
        }
    }

    private func fetchWithCookieHeader(_ cookieHeader: String) async throws -> CursorStatusSnapshot {
        enum FetchPart: Sendable {
            case usageSummary((CursorUsageSummary, String))
            case userInfo(Result<CursorUserInfo, Error>)
        }

        var usageSummaryResult: (CursorUsageSummary, String)?
        var userInfo: CursorUserInfo?

        try await withThrowingTaskGroup(of: FetchPart.self) { group in
            group.addTask {
                try await .usageSummary(self.fetchUsageSummary(cookieHeader: cookieHeader))
            }
            group.addTask {
                do {
                    return try await .userInfo(.success(self.fetchUserInfo(cookieHeader: cookieHeader)))
                } catch {
                    return .userInfo(.failure(error))
                }
            }

            while let result = try await group.next() {
                switch result {
                case let .usageSummary(value):
                    usageSummaryResult = value
                case let .userInfo(value):
                    userInfo = try? value.get()
                }
            }
        }

        guard let usageSummaryResult else {
            throw CursorStatusProbeError.networkError("Cursor usage summary fetch did not complete")
        }

        let (usageSummary, rawJSON) = usageSummaryResult

        // Fetch legacy request usage only if user has a sub ID.
        // Uses try? to avoid breaking the flow for users where this endpoint fails or returns unexpected data.
        var requestUsage: CursorUsageResponse?
        var requestUsageRawJSON: String?
        if let userId = userInfo?.sub {
            do {
                let (usage, usageRawJSON) = try await self.fetchRequestUsage(userId: userId, cookieHeader: cookieHeader)
                requestUsage = usage
                requestUsageRawJSON = usageRawJSON
            } catch {
                // Silently ignore - not all plans have this endpoint
            }
        }

        // Combine raw JSON for debugging
        var combinedRawJSON: String? = rawJSON
        if let usageJSON = requestUsageRawJSON {
            combinedRawJSON = (combinedRawJSON ?? "") + "\n\n--- /api/usage response ---\n" + usageJSON
        }

        // Dashboard pools (Cursor Models / Other Models / Grok Bot weekly). Best effort:
        // plans without the feature, or team accounts needing a teamId body, yield nil
        // and the corresponding rows stay hidden.
        async let periodUsage = self.fetchDashboard(
            path: "api/dashboard/get-current-period-usage",
            cookieHeader: cookieHeader,
            as: CursorPeriodUsage.self)
        async let sandStatus = self.fetchDashboard(
            path: "api/dashboard/get-sand-usage-status",
            cookieHeader: cookieHeader,
            as: CursorSandUsageStatus.self)
        let (resolvedPeriodUsage, resolvedSandStatus) = await (periodUsage, sandStatus)

        return self.parseUsageSummary(
            usageSummary,
            userInfo: userInfo,
            rawJSON: combinedRawJSON,
            requestUsage: requestUsage,
            periodUsage: resolvedPeriodUsage,
            sandStatus: resolvedSandStatus)
    }

    private func fetchUsageSummary(cookieHeader: String) async throws -> (CursorUsageSummary, String) {
        let url = self.baseURL.appendingPathComponent("/api/usage-summary")
        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await self.urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CursorStatusProbeError.networkError("Invalid response")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw CursorStatusProbeError.notLoggedIn
        }

        guard httpResponse.statusCode == 200 else {
            throw CursorStatusProbeError.networkError("HTTP \(httpResponse.statusCode)")
        }

        let rawJSON = String(data: data, encoding: .utf8) ?? "<binary>"

        do {
            let decoder = JSONDecoder()
            let summary = try decoder.decode(CursorUsageSummary.self, from: data)
            return (summary, rawJSON)
        } catch {
            throw CursorStatusProbeError
                .parseFailed("JSON decode failed: \(error.localizedDescription). Raw: \(rawJSON.prefix(200))")
        }
    }

    private func fetchUserInfo(cookieHeader: String) async throws -> CursorUserInfo {
        let url = self.baseURL.appendingPathComponent("/api/auth/me")
        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await self.urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw CursorStatusProbeError.networkError("Failed to fetch user info")
        }

        let decoder = JSONDecoder()
        return try decoder.decode(CursorUserInfo.self, from: data)
    }

    private func fetchRequestUsage(
        userId: String,
        cookieHeader: String) async throws -> (CursorUsageResponse, String)
    {
        let url = self.baseURL.appendingPathComponent("/api/usage")
            .appending(queryItems: [URLQueryItem(name: "user", value: userId)])
        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await self.urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw CursorStatusProbeError.networkError("Failed to fetch request usage")
        }

        let rawJSON = String(data: data, encoding: .utf8) ?? "<binary>"
        let decoder = JSONDecoder()
        let usage = try decoder.decode(CursorUsageResponse.self, from: data)
        return (usage, rawJSON)
    }

    /// Best-effort dashboard POST (`{}` body, web session cookies). Returns nil when the
    /// plan omits the feature, the account needs a teamId body, or the call fails —
    /// callers treat nil as "row hidden", never as an error.
    private func fetchDashboard<RPC: Decodable>(
        path: String,
        cookieHeader: String,
        as type: RPC.Type) async -> RPC?
    {
        var request = URLRequest(url: self.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com/dashboard/usage", forHTTPHeaderField: "Referer")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.httpBody = Data("{}".utf8)
        guard let (data, response) = try? await self.urlSession.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    func parseUsageSummary(
        _ summary: CursorUsageSummary,
        userInfo: CursorUserInfo?,
        rawJSON: String?,
        requestUsage: CursorUsageResponse? = nil,
        periodUsage: CursorPeriodUsage? = nil,
        sandStatus: CursorSandUsageStatus? = nil) -> CursorStatusSnapshot
    {
        func parseBillingCycleDate(_ dateString: String?) -> Date? {
            guard let dateString else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: dateString) ?? ISO8601DateFormatter().date(from: dateString)
        }
        let billingCycleStart = parseBillingCycleDate(summary.billingCycleStart)
        let billingCycleEnd = parseBillingCycleDate(summary.billingCycleEnd)

        // Convert cents to USD (plan percent derives from raw values to avoid percent unit mismatches).
        // Use plan.limit directly - breakdown.total represents total *used* credits, not the limit.
        let planUsedRaw = Double(summary.individualUsage?.plan?.used ?? 0)
        let planLimitRaw = Double(summary.individualUsage?.plan?.limit ?? 0)
        func normPct(_ value: Double?) -> Double? {
            guard let v = value else { return nil }
            if v < 0 { return 0 }
            if v > 100 { return 100 }
            return v
        }

        func normalizeTotalPercent(_ v: Double) -> Double {
            max(0, min(100, v))
        }

        // Cursor's usage-summary percent fields are already in percentage units, even when they are fractional
        // values below 1.0 (for example 0.36 means 0.36%, which the dashboard rounds to 0%).
        let autoPercent = normPct(summary.individualUsage?.plan?.autoPercentUsed)
        let apiPercent = normPct(summary.individualUsage?.plan?.apiPercentUsed)

        // Enterprise / team-member personal cap (cents). Reported under `individualUsage.overall` for accounts
        // that don't get a `plan` block. Falls through to existing logic when absent so non-enterprise paths
        // are untouched.
        let overallUsedRaw = (summary.individualUsage?.overall?.used).map(Double.init)
        let overallLimitRaw = (summary.individualUsage?.overall?.limit).map(Double.init)

        // Shared team/enterprise pool (cents). Last-resort fallback when no individual data is available.
        let pooledUsedRaw = (summary.teamUsage?.pooled?.used).map(Double.init)
        let pooledLimitRaw = (summary.teamUsage?.pooled?.limit).map(Double.init)

        // Headline "Total" precedence:
        //   1. `individualUsage.plan.totalPercentUsed` (existing behavior for Pro/Hobby/etc.)
        //   2. averaged `auto` + `api` lane percents (existing behavior)
        //   3. either lane alone (existing behavior)
        //   4. `individualUsage.plan` ratio (existing behavior)
        //   5. NEW: `individualUsage.overall` ratio (Enterprise/Team personal cap)
        //   6. NEW: `teamUsage.pooled` ratio (last resort when no individual data is reported)
        let planPercentUsed: Double = if let totalPercentUsed = summary.individualUsage?.plan?.totalPercentUsed {
            normalizeTotalPercent(totalPercentUsed)
        } else if let autoUsed = autoPercent, let apiUsed = apiPercent {
            max(0, min(100, (autoUsed + apiUsed) / 2))
        } else if let apiUsed = apiPercent {
            max(0, min(100, apiUsed))
        } else if let autoUsed = autoPercent {
            max(0, min(100, autoUsed))
        } else if planLimitRaw > 0 {
            (planUsedRaw / planLimitRaw) * 100
        } else if let used = overallUsedRaw, let limit = overallLimitRaw, limit > 0 {
            normalizeTotalPercent((used / limit) * 100)
        } else if let used = pooledUsedRaw, let limit = pooledLimitRaw, limit > 0 {
            normalizeTotalPercent((used / limit) * 100)
        } else {
            0
        }

        // USD figures: prefer the source the headline ultimately came from. When `plan` is missing but
        // `overall` or `pooled` carry the cents, surface those so the on-demand display and downstream
        // consumers see real dollar amounts instead of zeros.
        let planUsed: Double
        let planLimit: Double
        if planLimitRaw > 0 || planUsedRaw > 0 {
            planUsed = planUsedRaw / 100.0
            planLimit = planLimitRaw / 100.0
        } else if let usedCents = overallUsedRaw, let limitCents = overallLimitRaw {
            planUsed = usedCents / 100.0
            planLimit = limitCents / 100.0
        } else if let usedCents = pooledUsedRaw, let limitCents = pooledLimitRaw {
            planUsed = usedCents / 100.0
            planLimit = limitCents / 100.0
        } else {
            planUsed = 0
            planLimit = 0
        }

        let onDemandUsed = Double(summary.individualUsage?.onDemand?.used ?? 0) / 100.0
        let onDemandLimit: Double? = summary.individualUsage?.onDemand?.limit.map { Double($0) / 100.0 }

        let teamOnDemandUsed: Double? = summary.teamUsage?.onDemand?.used.map { Double($0) / 100.0 }
        let teamOnDemandLimit: Double? = summary.teamUsage?.onDemand?.limit.map { Double($0) / 100.0 }

        // Bot quota for agentic background runs (cents). The personal quota wins; the shared
        // team bot pool is the fallback when no individual bot block is reported.
        let botBlock = summary.individualUsage?.botUsage ?? summary.teamUsage?.botUsage
        let botUsed = Double(botBlock?.used ?? 0) / 100.0
        let botLimit: Double? = botBlock?.limit.map { Double($0) / 100.0 }

        // Plan spend split between Cursor-served and third-party models (cents).
        let modelSplit = summary.individualUsage?.modelSplit
        let cursorModelUsed: Double? = modelSplit?.cursorModelCents.map { Double($0) / 100.0 }
        let nonCursorModelUsed: Double? = modelSplit?.nonCursorModelCents.map { Double($0) / 100.0 }

        // Dashboard usage pools (cursor.com/dashboard/usage): Cursor Models and Other Models
        // pools plus the Grok Bot weekly window. Best effort — nil when the endpoints omit
        // them (plans without the feature, team accounts needing a teamId body).
        let cursorModelsUsed = normPct(periodUsage?.planUsage?.autoPercentUsed)
        let otherModelsUsed = normPct(periodUsage?.planUsage?.apiPercentUsed)
        let grokBotWeeklyUsed = normPct(sandStatus?.usagePercent)
        let grokBotWeeklyReset = parseBillingCycleDate(sandStatus?.nextResetTimestampUtc)

        // Legacy request-based plan: maxRequestUsage being non-nil indicates a request-based plan
        let requestsUsed: Int? = requestUsage?.gpt4?.numRequestsTotal ?? requestUsage?.gpt4?.numRequests
        let requestsLimit: Int? = requestUsage?.gpt4?.maxRequestUsage

        return CursorStatusSnapshot(
            planPercentUsed: planPercentUsed,
            autoPercentUsed: autoPercent,
            apiPercentUsed: apiPercent,
            planUsedUSD: planUsed,
            planLimitUSD: planLimit,
            onDemandUsedUSD: onDemandUsed,
            onDemandLimitUSD: onDemandLimit,
            teamOnDemandUsedUSD: teamOnDemandUsed,
            teamOnDemandLimitUSD: teamOnDemandLimit,
            billingCycleStart: billingCycleStart,
            billingCycleEnd: billingCycleEnd,
            membershipType: summary.membershipType,
            accountEmail: userInfo?.email,
            accountName: userInfo?.name,
            rawJSON: rawJSON,
            requestsUsed: requestsUsed,
            requestsLimit: requestsLimit,
            botUsedUSD: botUsed,
            botLimitUSD: botLimit,
            cursorModelUsedUSD: cursorModelUsed,
            nonCursorModelUsedUSD: nonCursorModelUsed,
            cursorModelsUsedPercent: cursorModelsUsed,
            otherModelsUsedPercent: otherModelsUsed,
            grokBotWeeklyUsedPercent: grokBotWeeklyUsed,
            grokBotWeeklyReset: grokBotWeeklyReset)
    }
}

#else

// MARK: - Cursor (Unsupported)

public enum CursorStatusProbeError: LocalizedError, Sendable {
    case notSupported

    public var errorDescription: String? {
        "Cursor is only supported on macOS."
    }
}

public struct CursorStatusSnapshot: Sendable {
    public init() {}

    public func toUsageSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: nil)
    }
}

public struct CursorStatusProbe: Sendable {
    public init(
        baseURL: URL = URL(string: "https://cursor.com")!,
        timeout: TimeInterval = 15.0,
        browserDetection: BrowserDetection,
        urlSession: any ProviderHTTPTransport = ProviderHTTPClient.shared)
    {
        _ = baseURL
        _ = timeout
        _ = browserDetection
        _ = urlSession
    }

    public func fetch(logger: ((String) -> Void)? = nil) async throws -> CursorStatusSnapshot {
        _ = logger
        throw CursorStatusProbeError.notSupported
    }

    public func fetch(
        cookieHeaderOverride _: String? = nil,
        allowCachedSessions _: Bool = true,
        logger: ((String) -> Void)? = nil) async throws -> CursorStatusSnapshot
    {
        try await self.fetch(logger: logger)
    }

    public func fetchCostReport(
        since _: Date?,
        until _: Date?,
        calendar _: Calendar = .current,
        cookieHeaderOverride _: String? = nil,
        allowCachedSessions _: Bool = true,
        logger: ((String) -> Void)? = nil) async throws -> CursorCostReport
    {
        _ = logger
        throw CursorStatusProbeError.notSupported
    }
}

#endif

// MARK: - Cursor Cost Report

/// A windowed Cursor cost report: the API-rate per-day, per-model breakdown plus the
/// Cursor-metered total (what the plan actually deducts) over the same window.
///
/// `daily` carries vendor list-price costs (`tokenUsage.totalCents`); `meteredCostUSD` sums
/// each event's `chargedCents` and is `nil` when the events reported no metered amount.
public struct CursorCostReport: Sendable {
    public let daily: CostUsageDailyReport
    public let meteredCostUSD: Double?

    public init(daily: CostUsageDailyReport, meteredCostUSD: Double?) {
        self.daily = daily
        self.meteredCostUSD = meteredCostUSD
    }
}
