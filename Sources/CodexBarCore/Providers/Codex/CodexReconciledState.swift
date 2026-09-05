import Foundation

public struct CodexReconciledState: Sendable {
    public let session: RateWindow?
    public let weekly: RateWindow?
    /// Named model-specific limits (e.g. Codex Spark) surfaced through `UsageSnapshot.extraRateWindows`.
    public let extraRateWindows: [NamedRateWindow]
    /// On-demand rate-limit reset credits (OAuth sources only; nil when unavailable).
    public let resetCredits: CodexResetCreditsSnapshot?
    public let identity: ProviderIdentitySnapshot?
    public let updatedAt: Date

    public init(
        session: RateWindow?,
        weekly: RateWindow?,
        extraRateWindows: [NamedRateWindow] = [],
        resetCredits: CodexResetCreditsSnapshot? = nil,
        identity: ProviderIdentitySnapshot?,
        updatedAt: Date)
    {
        self.session = session
        self.weekly = weekly
        self.extraRateWindows = extraRateWindows
        self.resetCredits = resetCredits
        self.identity = identity
        self.updatedAt = updatedAt
    }

    public static func fromCLI(
        primary: RateWindow?,
        secondary: RateWindow?,
        identity: ProviderIdentitySnapshot?,
        updatedAt: Date = Date()) -> CodexReconciledState?
    {
        self.make(primary: primary, secondary: secondary, identity: identity, updatedAt: updatedAt)
    }

    public static func fromOAuth(
        response: CodexUsageResponse,
        credentials: CodexOAuthCredentials,
        resetCredits: CodexResetCreditsSnapshot? = nil,
        updatedAt: Date = Date()) -> CodexReconciledState?
    {
        let resolvedResetCredits = resetCredits ?? self.countOnlyResetCredits(
            summary: response.rateLimitResetCredits,
            updatedAt: updatedAt)
        return self.make(
            primary: self.makeWindow(response.rateLimit?.primaryWindow),
            secondary: self.makeWindow(response.rateLimit?.secondaryWindow),
            extraRateWindows: CodexAdditionalRateLimitMapper.extraRateWindows(
                from: response.additionalRateLimits,
                now: updatedAt),
            resetCredits: resolvedResetCredits,
            identity: self.oauthIdentity(response: response, credentials: credentials),
            updatedAt: updatedAt)
    }

    /// Count-only fallback from the usage-body `rate_limit_reset_credits` summary, which
    /// carries no per-credit expiries. Returns nil when the body reports no counts so
    /// older/partial payloads keep a nil (unknown) state instead of a misleading zero.
    private static func countOnlyResetCredits(
        summary: CodexUsageResponse.RateLimitResetCreditsSummary?,
        updatedAt: Date) -> CodexResetCreditsSnapshot?
    {
        guard let availableCount = summary?.availableCount else { return nil }
        return CodexResetCreditsSnapshot.countOnly(availableCount: availableCount, updatedAt: updatedAt)
    }

    public static func fromAttachedDashboard(
        snapshot: OpenAIDashboardSnapshot,
        provider: UsageProvider = .codex,
        accountEmail: String? = nil,
        accountPlan: String? = nil) -> CodexReconciledState?
    {
        let resolvedEmail = accountEmail ?? snapshot.signedInEmail
        let resolvedPlan = accountPlan ?? snapshot.accountPlan
        let identity = ProviderIdentitySnapshot(
            providerID: provider,
            accountEmail: resolvedEmail,
            accountOrganization: nil,
            loginMethod: resolvedPlan)

        return self.make(
            primary: snapshot.primaryLimit,
            secondary: snapshot.secondaryLimit,
            extraRateWindows: snapshot.extraRateWindows ?? [],
            identity: identity,
            updatedAt: snapshot.updatedAt)
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: self.session,
            secondary: self.weekly,
            tertiary: nil,
            extraRateWindows: self.extraRateWindows.isEmpty ? nil : self.extraRateWindows,
            codexResetCredits: self.resetCredits,
            updatedAt: self.updatedAt,
            identity: self.identity)
    }

    public static func oauthIdentity(
        response: CodexUsageResponse,
        credentials: CodexOAuthCredentials) -> ProviderIdentitySnapshot
    {
        ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: self.resolveAccountEmail(from: credentials),
            accountOrganization: nil,
            loginMethod: self.resolvePlan(response: response, credentials: credentials))
    }

    private static func make(
        primary: RateWindow?,
        secondary: RateWindow?,
        extraRateWindows: [NamedRateWindow] = [],
        resetCredits: CodexResetCreditsSnapshot? = nil,
        identity: ProviderIdentitySnapshot?,
        updatedAt: Date) -> CodexReconciledState?
    {
        let normalized = CodexRateWindowNormalizer.normalize(primary: primary, secondary: secondary)
        // Extra windows are supplemental, so they never resurrect a snapshot on their own: keep the
        // existing primary/weekly gate to preserve current behavior when only extra limits are present.
        guard normalized.primary != nil || normalized.secondary != nil else {
            return nil
        }

        return CodexReconciledState(
            session: normalized.primary,
            weekly: normalized.secondary,
            extraRateWindows: extraRateWindows,
            resetCredits: resetCredits,
            identity: identity,
            updatedAt: updatedAt)
    }

    private static func makeWindow(_ window: CodexUsageResponse.WindowSnapshot?) -> RateWindow? {
        guard let window else { return nil }
        let resetDate = Date(timeIntervalSince1970: TimeInterval(window.resetAt))
        let resetDescription = UsageFormatter.resetDescription(from: resetDate)
        return RateWindow(
            usedPercent: Double(window.usedPercent),
            windowMinutes: window.limitWindowSeconds / 60,
            resetsAt: resetDate,
            resetDescription: resetDescription)
    }

    private static func resolveAccountEmail(from credentials: CodexOAuthCredentials) -> String? {
        guard let idToken = credentials.idToken,
              isIDTokenFresh(idToken),
              let payload = UsageFetcher.parseJWT(idToken)
        else {
            return nil
        }

        let profileDict = payload["https://api.openai.com/profile"] as? [String: Any]
        let email = (payload["email"] as? String) ?? (profileDict?["email"] as? String)
        return email?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolvePlan(response: CodexUsageResponse, credentials: CodexOAuthCredentials) -> String? {
        if let plan = response.planType?.rawValue, !plan.isEmpty { return plan }
        guard let idToken = credentials.idToken,
              Self.isIDTokenFresh(idToken),
              let payload = UsageFetcher.parseJWT(idToken)
        else {
            return nil
        }

        let authDict = payload["https://api.openai.com/auth"] as? [String: Any]
        let plan = (authDict?["chatgpt_plan_type"] as? String) ?? (payload["chatgpt_plan_type"] as? String)
        return plan?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns true when the id_token is either fresh (exp in the future) or has no `exp` claim
    /// (treated as non-expiring for identity purposes — preserves prior behavior for legacy
    /// tokens that don't carry `exp`).
    private static func isIDTokenFresh(_ idToken: String) -> Bool {
        guard let exp = UsageFetcher.parseJWTExp(idToken) else { return true }
        return exp > Date()
    }
}
