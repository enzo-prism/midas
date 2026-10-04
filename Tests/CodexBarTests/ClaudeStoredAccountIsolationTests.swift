import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeStoredAccountIsolationTests {
    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            throw ClaudeUsageError.parseFailed("Global CLI must not run for a stored account")
        }

        func debugRawProbe(model _: String) async -> String {
            "stub"
        }

        func detectVersion() -> String? {
            nil
        }
    }

    private func context(
        source: ProviderSourceMode,
        environment: [String: String] = [:],
        cookie: String? = nil,
        cookieSource: ProviderCookieSource = .manual) -> ProviderFetchContext
    {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: source,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: .make(claude: .init(
                usageDataSource: .auto,
                webExtrasEnabled: true,
                cookieSource: cookieSource,
                manualCookieHeader: cookie)),
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            selectedTokenAccountID: UUID())
    }

    @Test(arguments: ProviderSourceMode.allCases)
    func `stored session cookie pins web regardless of global source`(source: ProviderSourceMode) async {
        let context = self.context(source: source, cookie: "sessionKey=sk-ant-session-isolated")
        let strategies = await ClaudeProviderDescriptor.descriptor.fetchPlan.pipeline.resolveStrategies(context)

        #expect(strategies.map(\.id) == ["claude.web"])
        #expect(strategies.first?
            .shouldFallback(on: ClaudeUsageError.parseFailed("expired"), context: context) == false)
    }

    @Test(arguments: ProviderSourceMode.allCases)
    func `stored OAuth token pins OAuth regardless of global source`(source: ProviderSourceMode) async {
        let context = self.context(
            source: source,
            environment: [ClaudeOAuthCredentialsStore.environmentTokenKey: "sk-ant-oat-isolated"],
            cookieSource: .off)
        let strategies = await ClaudeProviderDescriptor.descriptor.fetchPlan.pipeline.resolveStrategies(context)

        #expect(strategies.map(\.id) == ["claude.oauth"])
        #expect(strategies.first?
            .shouldFallback(on: ClaudeUsageError.oauthFailed("expired"), context: context) == false)
    }

    @Test(arguments: ProviderSourceMode.allCases)
    func `stored admin key pins admin API regardless of global source`(source: ProviderSourceMode) async {
        let context = self.context(
            source: source,
            environment: [ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey: "sk-ant-admin-isolated"],
            cookieSource: .off)
        let strategies = await ClaudeProviderDescriptor.descriptor.fetchPlan.pipeline.resolveStrategies(context)

        #expect(strategies.map(\.id) == ["claude.admin-api"])
    }

    @Test(arguments: ProviderSourceMode.allCases)
    func `missing stored credentials never use global auth`(source: ProviderSourceMode) async {
        let context = self.context(source: source, cookieSource: .auto)
        let outcome = await ClaudeProviderDescriptor.descriptor.fetchOutcome(context: context)

        #expect(outcome.attempts.isEmpty)
        if case .success = outcome.result {
            Issue.record("Missing stored credentials must fail without global auth")
        }
    }

    @Test
    func `stored OAuth availability does not consult global credentials`() async {
        let context = self.context(source: .auto)
        #expect(await ClaudeOAuthFetchStrategy().isAvailable(context) == false)
    }

    @Test
    func `stored web availability does not import browser credentials`() async {
        let context = self.context(source: .auto, cookieSource: .auto)
        let strategy = ClaudeWebFetchStrategy(browserDetection: context.browserDetection)
        #expect(await strategy.isAvailable(context) == false)
    }

    @Test
    func `cookie without sessionKey does not enable global auth`() async {
        let context = self.context(source: .auto, cookie: "unrelated=value")
        let strategies = await ClaudeProviderDescriptor.descriptor.fetchPlan.pipeline.resolveStrategies(context)
        #expect(strategies.isEmpty)
    }
}
