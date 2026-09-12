import Foundation
import Testing
@testable import CodexBar

struct MidasOnboardingLaunchTests {
    @Test func interruptedFirstLaunchRetriesUntilSheetAppears() {
        #expect(MidasOnboardingLaunch.shouldPresent(
            persistentDefaults: [MidasOnboardingLaunch.pendingKey: true],
            hasConfig: true,
            hasManagedAccounts: false,
            isMidas: true,
            isTesting: false))
        #expect(!MidasOnboardingLaunch.shouldPresent(
            persistentDefaults: [
                MidasOnboardingLaunch.pendingKey: true,
                MidasOnboardingLaunch.presentedKey: true,
            ],
            hasConfig: true,
            hasManagedAccounts: false,
            isMidas: true,
            isTesting: false))
    }

    @Test func onlyFreshMidasInstallPresentsSetup() {
        #expect(MidasOnboardingLaunch.shouldPresent(
            persistentDefaults: [:],
            hasConfig: false,
            hasManagedAccounts: false,
            isMidas: true,
            isTesting: false))
        #expect(!MidasOnboardingLaunch.shouldPresent(
            persistentDefaults: [:],
            hasConfig: false,
            hasManagedAccounts: false,
            isMidas: false,
            isTesting: false))
        #expect(!MidasOnboardingLaunch.shouldPresent(
            persistentDefaults: [:],
            hasConfig: false,
            hasManagedAccounts: false,
            isMidas: true,
            isTesting: true))
    }

    @Test func existingConfigurationOrAccountsSuppressUpgradeInterruption() {
        #expect(!MidasOnboardingLaunch.shouldPresent(
            persistentDefaults: [:],
            hasConfig: true,
            hasManagedAccounts: false,
            isMidas: true,
            isTesting: false))
        #expect(!MidasOnboardingLaunch.shouldPresent(
            persistentDefaults: [:],
            hasConfig: false,
            hasManagedAccounts: true,
            isMidas: true,
            isTesting: false))
    }

    @Test func storedEvidenceIncludingExplicitFalseIsPreserved() {
        for key in [
            MidasOnboardingLaunch.presentedKey,
            "midasMenuBarMode",
            "providerDetectionCompleted",
            "SUHasLaunchedBefore",
        ] {
            #expect(!MidasOnboardingLaunch.shouldPresent(
                persistentDefaults: [key: false],
                hasConfig: false,
                hasManagedAccounts: false,
                isMidas: true,
                isTesting: false))
        }
        #expect(MidasOnboardingLaunch.shouldPresent(
            persistentDefaults: ["NSNavLastRootDirectory": "/tmp"],
            hasConfig: false,
            hasManagedAccounts: false,
            isMidas: true,
            isTesting: false))
    }
}
