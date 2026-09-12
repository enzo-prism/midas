import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MidasOnboardingTests {
    @Test func cursorAndMetaDoNotRequireCodexOrPricing() {
        for provider in [UsageProvider.cursor, .meta] {
            #expect(MidasOnboarding.canContinue(selected: [provider], mode: .custom, rate: nil))
        }
        #expect(!MidasOnboarding.canContinue(selected: [], mode: .automatic, rate: nil))
        #expect(MidasOnboarding.canContinue(selected: [.codex], mode: .automatic, rate: nil))
        #expect(MidasOnboarding.canContinue(selected: [.codex], mode: .tokensOnly, rate: nil))
    }

    @Test func customPricingMustBeValidOnlyForCodex() {
        for rate in [Double?.none, 0, -1, .infinity, .nan, 1001] {
            #expect(!MidasOnboarding.canContinue(selected: [.codex, .cursor], mode: .custom, rate: rate))
        }
        #expect(MidasOnboarding.canContinue(selected: [.codex], mode: .custom, rate: 1))
    }

    @Test func unavailableNeverBecomesZeroOrContaminatesTotals() {
        #expect(MidasOnboarding.total([nil, nil]) == nil)
        #expect(MidasOnboarding.total([nil, 0]) == 0)
        #expect(MidasOnboarding.total([2, nil, 3]) == 5)
        #expect(MidasOnboarding.total([.nan, .infinity, -1]) == nil)
        #expect(MidasOnboarding.total([Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude]) == nil)
    }

    @Test func enabledIsNotEvidenceOfConnection() {
        #expect(MidasOnboarding.availability(
            hasUsage: false, isRefreshing: false, hasError: false, isLocal: false) == "Connect to see usage")
        #expect(MidasOnboarding.availability(
            hasUsage: true, isRefreshing: false, hasError: true, isLocal: false) ==
            "Saved usage available · refresh needed")
        #expect(MidasOnboarding.availability(
            hasUsage: false, isRefreshing: false, hasError: false, isLocal: true) == "No activity on this Mac yet")
    }

    @Test @MainActor func cleanPreferencesAndDeferredProgressSurviveRelaunch() throws {
        let suite = "MidasOnboarding-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clean = PreferencesSelection(onboardingDefaults: defaults)
        #expect(!clean.spendSetupPending)
        #expect(clean.spendSetupStep == .services)
        clean.spendSetupStep = .overview
        clean.spendSetupPending = true
        let resumed = PreferencesSelection(onboardingDefaults: defaults)
        #expect(resumed.spendSetupPending)
        #expect(resumed.spendSetupStep == .overview)
        resumed.spendSetupPending = false
        #expect(!PreferencesSelection(onboardingDefaults: defaults).spendSetupPending)
    }
}
