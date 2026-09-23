import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

struct AnthropicProviderTests {
    private static let now = Date(timeIntervalSince1970: 1_700_179_200) // 2023-11-17T00:00:00Z

    private func makeContext(
        env: [String: String] = [AnthropicSettingsReader.adminAPIKeyEnvironmentKey: "sk-ant-admin-test"],
        historyDays: Int = 30) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection,
            costUsageHistoryDays: historyDays)
    }

    private static func okResponse(_ request: URLRequest, body: String, status: Int = 200) throws
        -> (Data, URLResponse)
    {
        let response = try HTTPURLResponse(
            url: #require(request.url),
            statusCode: status,
            httpVersion: nil,
            headerFields: nil)!
        return (Data(body.utf8), response)
    }

    private static func query(_ request: URLRequest, _ name: String) -> [String] {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return [] }
        return components.queryItems?.filter { $0.name == name }.compactMap(\.value) ?? []
    }

    private static let emptyPage = #"{"data":[],"has_more":false,"next_page":null}"#

    // MARK: - Descriptor + settings

    @Test
    func `descriptor registers a separate api-only provider`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .anthropic)

        #expect(descriptor.metadata.displayName == "Anthropic")
        #expect(descriptor.metadata.defaultEnabled == false)
        #expect(descriptor.cli.name == "anthropic")
        #expect(descriptor.cli.aliases.contains("anthropic-api"))
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        #expect(descriptor.tokenCost.supportsTokenCost)
        #expect(UsageStore.tokenCostRequiresProviderSnapshot(.anthropic))
    }

    @Test
    func `admin key reader strips bearer prefix and prefers primary env key`() {
        #expect(AnthropicSettingsReader.adminAPIKey(environment: [
            AnthropicSettingsReader.adminAPIKeyEnvironmentKey: "  Bearer sk-ant-admin-primary ",
            ClaudeAdminAPISettingsReader.alternateAdminAPIKeyEnvironmentKey: "sk-ant-admin-alt",
        ]) == "sk-ant-admin-primary")
        #expect(AnthropicSettingsReader.adminAPIKey(environment: [
            ClaudeAdminAPISettingsReader.alternateAdminAPIKeyEnvironmentKey: "sk-ant-admin-alt",
        ]) == "sk-ant-admin-alt")
        #expect(AnthropicSettingsReader.adminAPIKey(environment: [:]) == nil)
    }

    @Test
    func `config key only reaches the anthropic environment`() {
        let config = ProviderConfig(id: .anthropic, apiKey: "sk-ant-admin-config")
        let anthropicEnv = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .anthropic,
            config: config)
        let claudeEnv = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .claude,
            config: nil)

        #expect(anthropicEnv[AnthropicSettingsReader.adminAPIKeyEnvironmentKey] == "sk-ant-admin-config")
        #expect(claudeEnv[ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey] == nil)
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .anthropic))
    }

    @Test
    func `token accounts inject the admin key`() {
        let env = TokenAccountSupportCatalog.envOverride(for: .anthropic, token: "sk-ant-admin-org-b")

        #expect(env?[AnthropicSettingsReader.adminAPIKeyEnvironmentKey] == "sk-ant-admin-org-b")
    }

    // MARK: - Strategy

    @Test
    func `strategy passes history days and labels identity as anthropic`() async throws {
        let strategy = AnthropicAdminAPIFetchStrategy(usageFetcher: { apiKey, days in
            #expect(apiKey == "sk-ant-admin-test")
            #expect(days == 90)
            return ClaudeAdminAPIUsageSnapshot(
                daily: [],
                updatedAt: Self.now,
                historyDays: days,
                organizationName: "Prism Labs")
        })

        let result = try await strategy.fetch(self.makeContext(historyDays: 90))

        #expect(result.sourceLabel == "admin-api")
        #expect(result.usage.identity?.providerID == .anthropic)
        #expect(result.usage.identity?.accountOrganization == "Prism Labs")
        #expect(result.usage.identity?.loginMethod == "Admin API")
        #expect(result.usage.claudeAdminAPIUsage?.historyDays == 90)
    }

    @Test
    func `strategy is unavailable without a key`() async {
        let strategy = AnthropicAdminAPIFetchStrategy()

        #expect(await strategy.isAvailable(self.makeContext(env: [:])) == false)
        await #expect(throws: AnthropicSettingsError.self) {
            _ = try await strategy.fetch(self.makeContext(env: [:]))
        }
    }

    // MARK: - Fetcher

    @Test
    func `fetcher chunks long history into 31 day pages and sends admin headers`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            try Self.okResponse(request, body: Self.emptyPage)
        }

        let snapshot = try await ClaudeAdminAPIUsageFetcher.fetchUsage(
            apiKey: " sk-ant-admin-test ",
            costURL: #require(URL(string: "https://api.anthropic.test/v1/organizations/cost_report")),
            messagesURL: #require(URL(string: "https://api.anthropic.test/v1/organizations/usage_report/messages")),
            session: transport,
            now: Self.now,
            historyDays: 90,
            retryPolicy: .disabled)

        let requests = await transport.requests()
        let limits = requests.compactMap { Self.query($0, "limit").first.flatMap(Int.init) }
        #expect(snapshot.historyDays == 90)
        #expect(requests.count == 6)
        #expect(limits == [31, 31, 28, 31, 31, 28])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "x-api-key") == "sk-ant-admin-test" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01" })
        #expect(Self.query(requests[0], "group_by[]") == ["description"])
        #expect(Self.query(requests[3], "group_by[]") == ["model"])
        // Contiguous ranges ending at the start of tomorrow (UTC).
        #expect(Self.query(requests[0], "starting_at") == ["2023-08-20T00:00:00Z"])
        #expect(Self.query(requests[2], "ending_at") == ["2023-11-18T00:00:00Z"])
    }

    @Test
    func `fetcher follows next page tokens and fetches organization name`() async throws {
        let firstCostPage = """
        {"data":[{"starting_at":"2023-11-15T00:00:00Z","ending_at":"2023-11-16T00:00:00Z",
          "results":[{"amount":"250","currency":"USD","description":"Claude Sonnet Usage"}]}],
         "has_more":true,"next_page":"page_2"}
        """
        let secondCostPage = """
        {"data":[{"starting_at":"2023-11-16T00:00:00.000Z","ending_at":"2023-11-17T00:00:00.000Z",
          "results":[{"amount":"123.45","currency":"USD","description":"Web Search Usage"}]}],
         "has_more":false,"next_page":null}
        """
        let messagesPage = """
        {"data":[{"starting_at":"2023-11-16T00:00:00Z","ending_at":"2023-11-17T00:00:00Z",
          "results":[{"uncached_input_tokens":100,"cache_read_input_tokens":20,"output_tokens":30,
            "cache_creation":{"ephemeral_5m_input_tokens":5,"ephemeral_1h_input_tokens":5},
            "model":"claude-sonnet-4-5"}]}],
         "has_more":false,"next_page":null}
        """
        let transport = ProviderHTTPTransportStub { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/organizations/me") {
                return try Self.okResponse(request, body: #"{"id":"org_1","type":"organization","name":"Prism Labs"}"#)
            }
            if path.hasSuffix("/messages") {
                return try Self.okResponse(request, body: messagesPage)
            }
            let page = Self.query(request, "page").first
            return try Self.okResponse(request, body: page == "page_2" ? secondCostPage : firstCostPage)
        }

        let snapshot = try await ClaudeAdminAPIUsageFetcher.fetchUsage(
            apiKey: "sk-ant-admin-test",
            costURL: #require(URL(string: "https://api.anthropic.test/v1/organizations/cost_report")),
            messagesURL: #require(URL(string: "https://api.anthropic.test/v1/organizations/usage_report/messages")),
            organizationURL: #require(URL(string: "https://api.anthropic.test/v1/organizations/me")),
            session: transport,
            now: Self.now,
            historyDays: 3,
            retryPolicy: .disabled)

        let requests = await transport.requests()
        #expect(requests.count == 4)
        #expect(Self.query(requests[1], "page") == ["page_2"])
        #expect(snapshot.organizationName == "Prism Labs")
        #expect(snapshot.daily.map(\.day) == ["2023-11-15", "2023-11-16"])
        #expect(snapshot.daily[0].costUSD == 2.5)
        // Fractional-second timestamps merge into the same UTC day as whole-second message buckets.
        #expect(abs(snapshot.daily[1].costUSD - 1.2345) < 0.000_001)
        #expect(snapshot.daily[1].totalTokens == 160)
        #expect(snapshot.daily[1].cacheCreationInputTokens == 10)
    }

    @Test
    func `organization lookup failure does not fail the fetch`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            if request.url?.path.hasSuffix("/organizations/me") == true {
                return try Self.okResponse(request, body: "{}", status: 500)
            }
            return try Self.okResponse(request, body: Self.emptyPage)
        }

        let snapshot = try await ClaudeAdminAPIUsageFetcher.fetchUsage(
            apiKey: "sk-ant-admin-test",
            costURL: #require(URL(string: "https://api.anthropic.test/cost")),
            messagesURL: #require(URL(string: "https://api.anthropic.test/messages")),
            organizationURL: #require(URL(string: "https://api.anthropic.test/v1/organizations/me")),
            session: transport,
            now: Self.now,
            historyDays: 1,
            retryPolicy: .disabled)

        #expect(snapshot.organizationName == nil)
        #expect(snapshot.daily.isEmpty)
    }

    @Test
    func `rejected key surfaces anthropic error message`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            try Self.okResponse(
                request,
                body: #"{"type":"error","error":{"type":"permission_error","message":"Admin key required"}}"#,
                status: 403)
        }

        do {
            _ = try await ClaudeAdminAPIUsageFetcher.fetchUsage(
                apiKey: "sk-ant-api03-not-admin",
                costURL: #require(URL(string: "https://api.anthropic.test/cost")),
                messagesURL: #require(URL(string: "https://api.anthropic.test/messages")),
                session: transport,
                now: Self.now,
                historyDays: 1,
                retryPolicy: .disabled)
            Issue.record("Expected a rejected-key error")
        } catch let error as ClaudeAdminAPIUsageError {
            #expect(error == .apiError(endpoint: "cost_report", statusCode: 403, message: "Admin key required"))
            #expect(error.isCredentialRejected)
            #expect(error.errorDescription?.contains("Admin key required") == true)
            #expect(error.errorDescription?.contains("sk-ant-admin") == true)
        }
    }

    @Test
    func `runaway pagination is bounded`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let next = "p\((Self.query(request, "page").first.flatMap { Int($0.dropFirst()) } ?? 0) + 1)"
            return try Self.okResponse(request, body: #"{"data":[],"has_more":true,"next_page":"\#(next)"}"#)
        }

        await #expect(throws: ClaudeAdminAPIUsageError.paginationLimitExceeded(endpoint: "cost_report")) {
            _ = try await ClaudeAdminAPIUsageFetcher.fetchUsage(
                apiKey: "sk-ant-admin-test",
                costURL: #require(URL(string: "https://api.anthropic.test/cost")),
                messagesURL: #require(URL(string: "https://api.anthropic.test/messages")),
                session: transport,
                now: Self.now,
                historyDays: 1,
                retryPolicy: .disabled)
        }
    }

    // MARK: - Cost history + Midas

    private func sampleUsage(historyDays: Int? = 30) -> ClaudeAdminAPIUsageSnapshot {
        func bucket(_ day: String, offset: TimeInterval, cost: Double, tokens: Int) -> ClaudeAdminAPIUsageSnapshot
            .DailyBucket
        {
            ClaudeAdminAPIUsageSnapshot.DailyBucket(
                day: day,
                startTime: Self.now.addingTimeInterval(offset),
                endTime: Self.now.addingTimeInterval(offset + 86400),
                costUSD: cost,
                inputTokens: tokens / 2,
                cacheCreationInputTokens: 0,
                cacheReadInputTokens: tokens / 4,
                outputTokens: tokens / 4,
                totalTokens: tokens,
                costItems: [],
                models: [.init(
                    name: "claude-sonnet-4-5",
                    inputTokens: tokens / 2,
                    cacheCreationInputTokens: 0,
                    cacheReadInputTokens: tokens / 4,
                    outputTokens: tokens / 4,
                    totalTokens: tokens)])
        }
        return ClaudeAdminAPIUsageSnapshot(
            daily: [
                bucket("2023-11-15", offset: -2 * 86400, cost: 4, tokens: 400),
                bucket("2023-11-16", offset: -86400, cost: 6.5, tokens: 800),
            ],
            updatedAt: Self.now,
            historyDays: historyDays)
    }

    @Test
    func `projects billed daily spend into cost history`() {
        let token = self.sampleUsage().toCostUsageTokenSnapshot()

        #expect(token.costProvenance == .vendorBilled)
        #expect(token.historyDays == 30)
        #expect(token.last30DaysCostUSD == 10.5)
        #expect(token.last30DaysTokens == 1200)
        #expect(token.sessionCostUSD == 6.5)
        #expect(token.daily.map(\.date) == ["2023-11-15", "2023-11-16"])
        #expect(token.daily[1].cacheReadTokens == 200)
        #expect(token.daily[1].modelsUsed == ["claude-sonnet-4-5"])
    }

    @Test
    func `legacy cached snapshots without history default to thirty days`() throws {
        let legacy = #"{"daily":[],"updatedAt":0}"#
        let decoded = try JSONDecoder().decode(ClaudeAdminAPIUsageSnapshot.self, from: Data(legacy.utf8))

        #expect(decoded.historyDays == nil)
        #expect(decoded.effectiveHistoryDays == 30)
        #expect(decoded.organizationName == nil)
    }

    @Test
    func `claude admin source keeps its claude identity`() {
        let usage = self.sampleUsage().toUsageSnapshot()

        #expect(usage.identity?.providerID == .claude)
    }

    @Test
    func `midas shows billed spend but keeps it out of the estimate total`() throws {
        let anthropic = MidasProviderPresentation.make(
            provider: .anthropic,
            card: nil,
            snapshot: nil,
            tokenSnapshot: self.sampleUsage().toCostUsageTokenSnapshot(),
            isRefreshing: false,
            isStale: false)
        let codex = MidasProviderPresentation.make(
            provider: .codex,
            card: nil,
            snapshot: nil,
            tokenSnapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: nil,
                last30DaysCostUSD: 12,
                costProvenance: .listPriceEstimate,
                daily: [],
                updatedAt: Self.now),
            isRefreshing: false,
            isStale: false)

        let spend = try #require(anthropic.spend)
        #expect(spend.isBilled)
        #expect(spend.isEstimate == false)
        #expect(spend.isDisplayable)
        #expect(spend.title == "Billed API spend")
        #expect(spend.amount == 10.5)

        let total = MidasTotalSpend(presentations: [codex, anthropic])
        #expect(total.totals.first?.amount == 12)
        #expect(total.includedProviderCount == 1)
        #expect(total.billedProviderCount == 1)
        #expect(total.hasIncompleteCoverage == false)
        #expect(total.coverageText == "1 of 2 providers · 1 billed shown separately")
    }

    @Test
    func `cost history labels billed provenance`() {
        let presentation = MidasCostPresentation(
            snapshot: self.sampleUsage().toCostUsageTokenSnapshot(),
            period: .month,
            now: Self.now,
            reportingCalendar: Calendar(identifier: .gregorian))

        #expect(presentation.costLabel == "Billed API spend")
    }

    @Test
    func `cli total keeps billed anthropic spend separate`() throws {
        func snapshot(tokens: Int, cost: Double, provenance: CostProvenance) -> CostUsageTokenSnapshot {
            CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: tokens,
                last30DaysCostUSD: cost,
                costProvenance: provenance,
                daily: [],
                updatedAt: Self.now)
        }
        let total = try #require(CodexBarCLI.renderTotalSection(
            [
                (provider: .claude, snapshot: snapshot(tokens: 2000, cost: 2.5, provenance: .unknown)),
                (provider: .anthropic, snapshot: snapshot(tokens: 9000, cost: 40, provenance: .vendorBilled)),
            ],
            useColor: false))

        #expect(total.contains("Total: $2.50"))
        #expect(total.contains("2K tokens"))
        #expect(total.contains("billed separately: Anthropic"))
    }
}
