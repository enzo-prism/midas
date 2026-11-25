import Foundation

public enum GeminiProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .gemini,
            metadata: ProviderMetadata(
                id: .gemini,
                displayName: "Gemini",
                sessionLabel: "Pro",
                weeklyLabel: "Flash",
                opusLabel: "Flash Lite",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Gemini usage",
                cliName: "gemini",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://gemini.google.com",
                changelogURL: "https://github.com/google-gemini/gemini-cli/releases",
                statusPageURL: nil,
                statusLinkURL: "https://www.google.com/appsstatus/dashboard/products/npdyhgECDJ6tB66MxXyo/history",
                statusWorkspaceProductID: "npdyhgECDJ6tB66MxXyo"),
            branding: ProviderBranding(
                iconStyle: .gemini,
                iconResourceName: "ProviderIcon-gemini",
                color: ProviderColor(red: 171 / 255, green: 135 / 255, blue: 234 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "No Gemini usage logs found yet." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli, .oauth, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "gemini",
                versionDetector: { _ in ProviderVersionDetector.geminiVersion() }))
    }

    public static func windowLabels(
        snapshot: UsageSnapshot,
        metadata: ProviderMetadata = Self.descriptor.metadata)
        -> (primary: String, secondary: String, tertiary: String, showsTertiary: Bool)
    {
        let hasFiveHourPrimary = snapshot.primary?.windowMinutes == 5 * 60
        let hasWeeklySecondary = snapshot.secondary?.windowMinutes == 7 * 24 * 60
        if hasWeeklySecondary {
            return (
                hasFiveHourPrimary ? "5-hour" : metadata.sessionLabel,
                "Weekly",
                metadata.opusLabel ?? "Flash Lite",
                false)
        }
        if hasFiveHourPrimary {
            if snapshot.secondary == nil {
                return ("5-hour", metadata.weeklyLabel, metadata.opusLabel ?? "Flash Lite", false)
            }
            return (metadata.sessionLabel, metadata.weeklyLabel, metadata.opusLabel ?? "Flash Lite", false)
        }
        return (
            metadata.sessionLabel,
            metadata.weeklyLabel,
            metadata.opusLabel ?? "Flash Lite",
            metadata.supportsOpus)
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        let cliOAuth = GeminiStatusFetchStrategy()
        let antigravityLocal = GeminiAntigravityLocalFetchStrategy()
        let antigravityOAuth = GeminiAntigravityOAuthFetchStrategy()
        let antigravityCLI = GeminiAntigravityCLIFetchStrategy()
        switch context.sourceMode {
        case .api:
            return [cliOAuth]
        case .cli:
            return [antigravityLocal, antigravityCLI]
        case .oauth:
            return [antigravityOAuth]
        case .auto:
            return [antigravityLocal, antigravityOAuth, cliOAuth, antigravityCLI]
        case .web:
            return []
        }
    }
}

struct GeminiStatusFetchStrategy: ProviderFetchStrategy {
    static let sourceLabel = "oauth-api"

    let id: String = "gemini.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        if context.sourceMode == .api { return true }
        let credsPath = NSHomeDirectory() + "/.gemini/oauth_creds.json"
        return FileManager.default.fileExists(atPath: credsPath)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = GeminiStatusProbe()
        let snap = try await probe.fetch()
        let expectedEmail = GeminiSettingsReader.expectedAccountEmail(environment: context.env)
        try GeminiAccountMatcher.validate(reportedEmail: snap.accountEmail, expectedEmail: expectedEmail)
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: Self.sourceLabel)
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto
    }
}

/// Reads Gemini-only model quotas from a running local Antigravity desktop language server.
struct GeminiAntigravityLocalFetchStrategy: ProviderFetchStrategy {
    static let sourceLabel = "antigravity-local"

    let id: String = "gemini.antigravity-local"
    let kind: ProviderFetchKind = .localProbe

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = AntigravityStatusProbe(processScope: .ideOnly)
        let expectedEmail = GeminiSettingsReader.expectedAccountEmail(environment: context.env)
        let snap: AntigravityStatusSnapshot = if let registered = try await probe
            .registeredDesktopSnapshot(expectedEmail: expectedEmail)
        {
            registered
        } else {
            try await probe.fetch()
        }
        try GeminiAccountMatcher.validate(reportedEmail: snap.accountEmail, expectedEmail: expectedEmail)
        let usage = try GeminiAntigravityQuotaMapper.toUsageSnapshot(from: snap)
        return self.makeResult(
            usage: usage,
            sourceLabel: Self.sourceLabel)
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto || context.sourceMode == .cli
    }
}

/// Reads Gemini-only model quotas from Cloud Code PA via Google OAuth credentials scoped to Gemini.
struct GeminiAntigravityOAuthFetchStrategy: ProviderFetchStrategy {
    static let sourceLabel = "oauth"

    let id: String = "gemini.antigravity-oauth"
    let kind: ProviderFetchKind = .oauth

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        if context.sourceMode == .oauth { return true }
        return Self.resolvedCredentials(context: context) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let expectedEmail = GeminiSettingsReader.expectedAccountEmail(environment: context.env)
        guard let resolved = Self.resolvedCredentials(context: context) else {
            throw GeminiStatusProbeError.notLoggedIn
        }
        try GeminiAccountMatcher.validate(
            reportedEmail: resolved.credentials.resolvedAccountEmail,
            expectedEmail: expectedEmail)

        var fetchEnv = context.env
        fetchEnv[AntigravityOAuthCredentialsStore.environmentCredentialsKey] = try AntigravityOAuthCredentialsStore
            .tokenAccountValue(for: resolved.credentials)

        let fetcher = AntigravityRemoteUsageFetcher(
            environment: fetchEnv,
            credentialsUpdateHandler: { updated in
                if let accountID = context.selectedTokenAccountID,
                   let updater = context.tokenAccountTokenUpdater,
                   let token = try? AntigravityOAuthCredentialsStore.tokenAccountValue(for: updated)
                {
                    await updater(.gemini, accountID, token)
                }
                if resolved.persistToGeminiStore {
                    try? GeminiOAuthCredentialsStore.store().save(updated)
                }
            })
        let snap = try await fetcher.fetch(includeGeminiSummary: true)
        try GeminiAccountMatcher.validate(reportedEmail: snap.accountEmail, expectedEmail: expectedEmail)
        let usage = try GeminiAntigravityQuotaMapper.toUsageSnapshot(from: snap)
        return self.makeResult(
            usage: usage,
            sourceLabel: Self.sourceLabel)
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto
    }

    private struct ResolvedCredentials {
        let credentials: AntigravityOAuthCredentials
        let persistToGeminiStore: Bool
    }

    private static func resolvedCredentials(context: ProviderFetchContext) -> ResolvedCredentials? {
        if let value = context.env[GeminiSettingsReader.oauthCredentialsEnvironmentKey],
           let credentials = AntigravityOAuthCredentialsStore.credentials(fromTokenAccountValue: value)
        {
            return ResolvedCredentials(credentials: credentials, persistToGeminiStore: false)
        }
        if let credentials = try? GeminiOAuthCredentialsStore.store().load() {
            return ResolvedCredentials(credentials: credentials, persistToGeminiStore: true)
        }
        if let credentials = try? AntigravityOAuthCredentialsStore().load() {
            let expectedEmail = GeminiSettingsReader.expectedAccountEmail(environment: context.env)
            if expectedEmail == nil
                || (try? GeminiAccountMatcher.validate(
                    reportedEmail: credentials.resolvedAccountEmail,
                    expectedEmail: expectedEmail)) != nil
            {
                return ResolvedCredentials(credentials: credentials, persistToGeminiStore: false)
            }
        }
        return nil
    }
}

/// Reads Gemini-only model quotas from `agy` CLI HTTPS server when signed into the matching Google account.
struct GeminiAntigravityCLIFetchStrategy: ProviderFetchStrategy {
    static let sourceLabel = "antigravity-cli"

    let id: String = "gemini.antigravity-cli"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        await AntigravityCLIHTTPSFetchStrategy().isAvailable(context)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let binary = BinaryLocator.resolveAntigravityBinary(env: context.env) else {
            throw GeminiStatusProbeError.notLoggedIn
        }
        let session = AntigravityCLISession.shared
        let pid = try await session.beginProbe(binary: binary, idleWindow: context.persistentCLISessionIdleWindow)
        let deadline = Date().addingTimeInterval(5.0)
        let resetAfterFetch = AntigravityCLIHTTPSFetchStrategy.shouldResetSessionAfterFetch(context)
        let snap: AntigravityStatusSnapshot
        do {
            snap = try await AntigravityCLIHTTPSFetchStrategy.waitForSnapshot(
                pid: pid,
                deadline: deadline,
                dependencies: AntigravityCLIHTTPSFetchStrategy.SnapshotWaitDependencies(
                    pollIntervalNanoseconds: 200_000_000,
                    listeningPorts: { pid, timeout in
                        try await AntigravityStatusProbe.listeningPorts(pid: pid, timeout: timeout)
                    },
                    drainOutput: {
                        await session.drainOutput()
                    },
                    fetchSnapshot: { ports in
                        let timeout = min(2.0, max(0.2, deadline.timeIntervalSinceNow))
                        return try await AntigravityStatusProbe(timeout: timeout)
                            .fetchFromPorts(ports, deadline: deadline, includeGeminiSummary: true)
                    }))
            await session.finishProbe(success: true, resetAfterFetch: resetAfterFetch)
        } catch {
            let authRequired = (error as? AntigravityStatusProbeError) == .authenticationRequired
            await session.finishProbe(
                success: false,
                resetAfterFetch: resetAfterFetch || authRequired,
                forceTerminate: authRequired)
            if Self.requiresGoogleOAuthSignIn(error) {
                throw GeminiStatusProbeError.notLoggedIn
            }
            throw error
        }

        let expectedEmail = GeminiSettingsReader.expectedAccountEmail(environment: context.env)
        try GeminiAccountMatcher.validate(reportedEmail: snap.accountEmail, expectedEmail: expectedEmail)
        let usage = try GeminiAntigravityQuotaMapper.toUsageSnapshot(from: snap)
        return self.makeResult(
            usage: usage,
            sourceLabel: Self.sourceLabel)
    }

    private static func requiresGoogleOAuthSignIn(_ error: Error) -> Bool {
        if let probeError = error as? AntigravityStatusProbeError {
            switch probeError {
            case .authenticationRequired, .missingCSRFToken:
                return true
            case let .apiError(message):
                let lower = message.lowercased()
                return lower.contains("http 401") || lower.contains("csrf") || lower.contains("unauthenticated")
            default:
                return false
            }
        }
        return false
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
