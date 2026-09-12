import CodexBarCore
import Foundation
import Observation

@MainActor
@Observable
final class PreferencesSelection {
    var tab: PreferencesTab = .general
    var requestsSpendSetup = false
    @ObservationIgnored private let onboardingDefaults: UserDefaults
    var spendSetupPending: Bool {
        didSet { self.onboardingDefaults.set(self.spendSetupPending, forKey: "midasOnboardingPendingV1") }
    }

    var spendSetupStep: MidasOnboardingStep {
        didSet { self.onboardingDefaults.set(self.spendSetupStep.rawValue, forKey: "midasOnboardingStepV1") }
    }

    private(set) var requestedProvider: UsageProvider?
    private(set) var providerRequestID = UUID()

    init(onboardingDefaults: UserDefaults = .standard) {
        self.onboardingDefaults = onboardingDefaults
        self.spendSetupPending = onboardingDefaults.bool(forKey: "midasOnboardingPendingV1")
        self.spendSetupStep = MidasOnboardingStep(rawValue: onboardingDefaults.integer(forKey: "midasOnboardingStepV1"))
            ?? .services
    }

    func showProvider(_ provider: UsageProvider) {
        self.requestedProvider = provider
        self.providerRequestID = UUID()
        self.tab = .providers
    }
}
