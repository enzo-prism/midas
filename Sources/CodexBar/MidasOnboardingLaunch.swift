import Foundation

/// Evaluate before SettingsStore creates defaults or migrates provider configuration.
enum MidasOnboardingLaunch {
    static let pendingKey = "midasOnboardingLaunchPendingV1"
    static let presentedKey = "midasOnboardingPresentedV1"

    static func shouldPresent(
        persistentDefaults: [String: Any],
        hasConfig: Bool,
        hasManagedAccounts: Bool,
        isMidas: Bool,
        isTesting: Bool) -> Bool
    {
        guard isMidas, !isTesting, persistentDefaults[self.presentedKey] == nil else { return false }
        if persistentDefaults[self.pendingKey] as? Bool == true { return true }
        guard !hasConfig, !hasManagedAccounts else { return false }
        let priorUse = persistentDefaults.keys.contains {
            $0.hasPrefix("midas") || $0 == "providerDetectionCompleted" || $0 == "SUHasLaunchedBefore"
        }
        return !priorUse
    }
}
