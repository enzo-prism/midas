import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct GeminiAntigravityIntegrationTests {
    @Test func quotaMapperSilosGeminiModelsMapsRollingWindowsAndDeduplicatesEffortVariants() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let fiveHourReset = now.addingTimeInterval(4.5 * 3600)
        let weeklyReset = now.addingTimeInterval(7 * 24 * 3600)

        var antigravitySnapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Claude Sonnet 4.5 (High)",
                    modelId: "claude-sonnet-4-5-high",
                    remainingFraction: 0.20,
                    resetTime: fiveHourReset,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "GPT-OSS 120B (Medium)",
                    modelId: "MODEL_OPENAI_GPT_OSS_120B_MEDIUM",
                    remainingFraction: 0.10,
                    resetTime: fiveHourReset,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 2.5 Flash (High)",
                    modelId: "gemini-2.5-flash-high",
                    remainingFraction: 0.90,
                    resetTime: fiveHourReset,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 2.5 Flash (Low)",
                    modelId: "gemini-2.5-flash-low",
                    remainingFraction: 0.90,
                    resetTime: fiveHourReset,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 2.5 Pro (High)",
                    modelId: "gemini-2.5-pro-high",
                    remainingFraction: 0.75,
                    resetTime: weeklyReset,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 2.5 Pro (Low)",
                    modelId: "gemini-2.5-pro-low",
                    remainingFraction: 0.75,
                    resetTime: weeklyReset,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini Experimental Preview",
                    modelId: "gemini-experimental-preview",
                    remainingFraction: nil,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: "personal@example.com",
            accountPlan: "Google AI Pro",
            source: .local)

        antigravitySnapshot.geminiQuotaSummary = try JSONDecoder().decode(
            GeminiQuotaSummary.Envelope.self,
            from: Data("""
            {"response":{"groups":[{"buckets":[
              {"bucketId":"3p-weekly","remainingFraction":0.01},
              {"bucketId":"gemini-weekly","remainingFraction":0.63,"resetTime":"2025-10-10T10:00:00Z"},
              {"bucketId":"gemini-5h","remainingFraction":0.82,"resetTime":"2025-10-10T11:00:00Z"}
            ]}]}}
            """.utf8)).response

        let usage = try GeminiAntigravityQuotaMapper.toUsageSnapshot(from: antigravitySnapshot, now: now)

        #expect(usage.identity?.providerID == .gemini)
        #expect(usage.identity?.accountEmail == "personal@example.com")
        #expect(usage.identity?.loginMethod == "Google AI Pro")

        // Claude/GPT lower remaining fractions (20%, 10%) must never leak into Gemini.
        let primary = try #require(usage.primary)
        #expect(abs(primary.usedPercent - 18.0) < 0.01)
        #expect(primary.windowMinutes == 300)
        #expect(primary.resetsAt == ISO8601DateFormatter().date(from: "2025-10-10T11:00:00Z"))

        let secondary = try #require(usage.secondary)
        #expect(abs(secondary.usedPercent - 37.0) < 0.01)
        #expect(secondary.windowMinutes == 10080)
        #expect(secondary.resetsAt == ISO8601DateFormatter().date(from: "2025-10-10T10:00:00Z"))

        let extras = try #require(usage.extraRateWindows)
        #expect(extras.count == 3)
        #expect(extras.map(\.title) == ["Gemini 2.5 Pro", "Gemini Experimental Preview", "Gemini 2.5 Flash"])
        #expect(extras[1].usageKnown == false)
    }

    @Test func quotaMapperFiltersRemoteCatalogNoiseAndSortsDeterministically() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let fiveHourReset = now.addingTimeInterval(4 * 3600)

        let antigravitySnapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 2.5 Image",
                    modelId: "gemini-2.5-image",
                    remainingFraction: 1.0,
                    resetTime: fiveHourReset,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 2.5 Flash (Max)",
                    modelId: "gemini-2.5-flash-max",
                    remainingFraction: 0.90,
                    resetTime: fiveHourReset,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 2.5 Pro (High)",
                    modelId: "gemini-2.5-pro-high",
                    remainingFraction: 0.70,
                    resetTime: fiveHourReset,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini Tab Autocomplete",
                    modelId: "tab_gemini_autocomplete",
                    remainingFraction: 1.0,
                    resetTime: fiveHourReset,
                    resetDescription: nil),
            ],
            accountEmail: "personal@example.com",
            accountPlan: "Paid",
            source: .remote)

        let usage = try GeminiAntigravityQuotaMapper.toUsageSnapshot(from: antigravitySnapshot, now: now)
        let extras = try #require(usage.extraRateWindows)
        #expect(extras.map(\.title) == ["Gemini 2.5 Pro", "Gemini 2.5 Flash"])

        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(MidasOrbitQuota.make(provider: .gemini, snapshot: usage) == nil)
        #expect(extras.allSatisfy { $0.window.windowMinutes == nil })
    }

    @Test func summaryKeepsRealZeroAndFullAndOmitsUnreportedLimits() throws {
        for fraction in [0, 1] {
            let summary = try JSONDecoder().decode(GeminiQuotaSummary.self, from: Data("""
            {"buckets":[{"bucketId":"gemini-5h","remainingFraction":\(fraction)},
                        {"bucketId":"gemini-weekly","remainingAmount":500},
                        {"bucketId":"3p-weekly","remainingFraction":1}]}
            """.utf8))
            #expect(summary.fiveHour?.remainingPercent == Double(fraction * 100))
            #expect(summary.fiveHour?.resetsAt == nil)
            #expect(summary.weekly == nil)
        }
    }

    @Test func geminiAutoPipelinePrefersDesktopGroupLimits() async {
        struct StubClaudeFetcher: ClaudeUsageFetching {
            func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
                throw ClaudeUsageError.parseFailed("stub")
            }

            func debugRawProbe(model _: String) async -> String {
                "stub"
            }

            func detectVersion() -> String? {
                nil
            }
        }

        let descriptor = ProviderDescriptorRegistry.descriptor(for: .gemini)
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 10,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
        #expect(strategies.map(\.id) == [
            "gemini.antigravity-local",
            "gemini.antigravity-oauth",
            "gemini.api",
            "gemini.antigravity-cli",
        ])
    }

    @Test func midasOrbitSelectsGeminiWeeklyPool() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 5 * 60,
                resetsAt: now.addingTimeInterval(3 * 3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 35,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(5 * 24 * 3600),
                resetDescription: nil),
            tertiary: nil,
            updatedAt: now)

        let orbit = try #require(MidasOrbitQuota.make(provider: .gemini, snapshot: snapshot))
        #expect(orbit.id == "secondary")
        #expect(orbit.title == "Weekly limit")
        #expect(abs(orbit.remainingPercent - 65) < 0.01)
    }

    @Test func remoteUsageFetcherFallsBackToDailyCloudCodeEndpointWhenProductionReturnsEmpty() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        let credentials = AntigravityOAuthCredentials(
            accessToken: "test-access-token",
            refreshToken: nil,
            expiryDate: Date().addingTimeInterval(3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "personal@example.com"),
            email: "personal@example.com")
        let token = try AntigravityOAuthCredentialsStore.tokenAccountValue(for: credentials)

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }
            if host == "cloudcode-pa.googleapis.com" {
                if url.path == "/v1internal:loadCodeAssist" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.jsonData([
                            "currentTier": ["id": "standard-tier", "name": "Paid"],
                            "cloudaicompanionProject": "proj-1",
                        ]))
                }
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["models": [:]]))
            }
            if host == "daily-cloudcode-pa.googleapis.com" {
                if url.path == "/v1internal:loadCodeAssist" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.jsonData([
                            "currentTier": ["id": "standard-tier", "name": "Paid"],
                            "cloudaicompanionProject": "proj-1",
                        ]))
                }
                if url.path == "/v1internal:retrieveUserQuotaSummary" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: Data(#"{"groups":[{"buckets":[{"bucketId":"gemini-weekly","remainingFraction":0.45}]}]}"#
                            .utf8))
                }
                if url.path == "/v1internal:fetchAvailableModels" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.jsonData([
                            "models": [
                                "gemini-2.5-pro": [
                                    "displayName": "Gemini 2.5 Pro",
                                    "quotaInfo": [
                                        "remainingFraction": 0.8,
                                        "resetTime": "2026-11-24T20:00:00Z",
                                    ],
                                ],
                            ],
                        ]))
                }
            }
            return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
        }

        let fetcher = AntigravityRemoteUsageFetcher(
            timeout: 1,
            homeDirectory: env.homeURL.path,
            environment: [AntigravityOAuthCredentialsStore.environmentCredentialsKey: token],
            dataLoader: dataLoader)
        let snapshot = try await fetcher.fetch(includeGeminiSummary: true)
        let usage = try GeminiAntigravityQuotaMapper.toUsageSnapshot(from: snapshot)
        #expect(usage.primary == nil)
        #expect(usage.secondary?.remainingPercent == 45)
        #expect(snapshot.accountEmail == "personal@example.com")
        #expect(snapshot.modelQuotas.count == 1)
        #expect(snapshot.modelQuotas[0].modelId == "gemini-2.5-pro")
    }

    @Test func accountMatcherRejectsMismatchedGoogleAccountAndAcceptsCaseInsensitiveMatch() throws {
        try GeminiAccountMatcher.validate(
            reportedEmail: "Personal@Example.com",
            expectedEmail: "personal@example.com")
        try GeminiAccountMatcher.validate(reportedEmail: "any@example.com", expectedEmail: nil)

        #expect(throws: GeminiStatusProbeError.accountMismatch(
            expected: "personal@example.com",
            found: "work@example.com"))
        {
            try GeminiAccountMatcher.validate(
                reportedEmail: "work@example.com",
                expectedEmail: "personal@example.com")
        }
    }

    @Test func configEnvironmentAppliesPinnedGeminiAccountEmailWithoutClobberingEnv() {
        let config = ProviderConfig(id: .gemini, enabled: true, accountEmail: "personal@example.com")

        let applied = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: .gemini,
            config: config)
        #expect(applied[GeminiSettingsReader.accountEmailEnvironmentKey] == "personal@example.com")

        let preserved = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [GeminiSettingsReader.accountEmailEnvironmentKey: "override@example.com"],
            provider: .gemini,
            config: config)
        #expect(preserved[GeminiSettingsReader.accountEmailEnvironmentKey] == "override@example.com")
    }

    @Test func transcriptScannerParsesGeminiStepsIgnoresOtherProvidersAndPricesModels() throws {
        let geminiFlashLine = """
        {"step_index":1,"type":"PLANNER_RESPONSE","created_at":"2026-11-19T19:01:00Z",\
        "model":"gemini-2.5-flash-high","input_tokens":100000,"cache_read_tokens":500000,"output_tokens":10000}
        """
        let geminiProLine = """
        {"step_index":2,"type":"PLANNER_RESPONSE","created_at":"2026-11-19T19:05:00Z",\
        "model":"gemini-2.5-pro-tiered-xhigh","input_tokens":150000,"cache_read_tokens":100000,"output_tokens":2000}
        """
        let claudeLine = """
        {"step_index":3,"type":"PLANNER_RESPONSE","created_at":"2026-11-19T19:06:00Z",\
        "model":"claude-sonnet-4-5","input_tokens":50000,"cache_read_tokens":0,"output_tokens":1000}
        """
        let userLine = """
        {"step_index":0,"type":"USER_INPUT","created_at":"2026-11-19T19:00:00Z","content":"hello"}
        """

        let flashStep = try #require(GeminiTranscriptLogScanner._parseStepForTesting(fromLine: geminiFlashLine))
        let proStep = try #require(GeminiTranscriptLogScanner._parseStepForTesting(fromLine: geminiProLine))
        #expect(GeminiTranscriptLogScanner._parseStepForTesting(fromLine: claudeLine) == nil)
        #expect(GeminiTranscriptLogScanner._parseStepForTesting(fromLine: userLine) == nil)

        #expect(GeminiTranscriptLogScanner.normalizeModelIDForPricing(flashStep.model) == "gemini-2.5-flash")
        #expect(GeminiTranscriptLogScanner.normalizeModelIDForPricing(proStep.model) == "gemini-2.5-pro")

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-19T20:00:00Z"))
        let since = try #require(utc.date(byAdding: .day, value: -29, to: now))
        let emptyCacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-test-pricing-\(UUID().uuidString)", isDirectory: true)

        let snapshot = GeminiTranscriptLogScanner._buildTokenSnapshotForTesting(
            steps: [flashStep, proStep],
            since: since,
            until: now,
            now: now,
            historyDays: 30,
            pricingCacheRoot: emptyCacheRoot,
            calendar: utc)

        #expect(snapshot.costProvenance == .listPriceEstimate)
        #expect(snapshot.last30DaysTokens == 862_000)
        #expect(snapshot.sessionTokens == 862_000)
        // Flash: 100k*0.3e-6 + 500k*0.03e-6 + 10k*2.5e-6 = 0.03 + 0.015 + 0.025 = 0.07
        // Pro (>200k prompt = 250k): 150k*2.5e-6 + 100k*0.25e-6 + 2k*15e-6 = 0.375 + 0.025 + 0.03 = 0.43
        let totalCost = try #require(snapshot.last30DaysCostUSD)
        #expect(abs(totalCost - 0.50) < 0.0001)

        // Unknown fictitious models remain unpriced rather than inventing rates.
        #expect(CostUsagePricing.geminiCostUSD(
            model: "gemini-99-fictitious",
            inputTokens: 1000,
            cacheReadTokens: 0,
            outputTokens: 100,
            cacheRoot: emptyCacheRoot) == nil)
    }

    @Test @MainActor func midasPresentationPinsGeminiHeadlineWindowsAndResolvesFullColorLogo() throws {
        let now = Date()
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 0,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(7 * 24 * 3600),
                resetDescription: nil),
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "gemini-model-flash",
                    title: "Gemini 2.5 Flash",
                    window: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
            ],
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .gemini,
                accountEmail: "personal@example.com",
                accountOrganization: nil,
                loginMethod: "Google AI Pro"))

        let metadata = try #require(ProviderDefaults.metadata[.gemini])
        let card = UsageMenuCardView.Model.make(.init(
            provider: .gemini,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "personal@example.com", plan: "Google AI Pro"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let presentation = MidasProviderPresentation.make(
            provider: .gemini,
            card: card,
            snapshot: snapshot,
            tokenSnapshot: nil,
            isRefreshing: false,
            isStale: false)

        #expect(presentation.hero?.title == "5-hour limit")
        #expect(presentation.metrics.contains { $0.id == "secondary" && $0.title == "Weekly limit" })

        let overview = MidasAccountQuotaLayout.overviewMetrics(presentation)
        #expect(overview.map(\.id) == ["primary", "secondary"])
        #expect(MidasProviderLogoLoader.resourceName(for: .gemini, dark: false) == "MidasLogo-gemini")
        #expect(MidasProviderLogoLoader.resourceName(for: .gemini, dark: true) == "MidasLogo-gemini")
    }
}
