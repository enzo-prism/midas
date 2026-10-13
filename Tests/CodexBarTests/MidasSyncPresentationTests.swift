import Foundation
import Testing
@testable import CodexBar

struct MidasSyncPresentationTests {
    @Test func disconnectedSyncDescribesLocalUsage() {
        let presentation = MidasSyncPresentation(
            isEnabled: false, includesSyncedUsage: true, hasFolder: false, otherMacCount: 2)
        #expect(presentation.title == "Usage on this Mac")
        #expect(presentation.sharingSummary == nil)
    }

    @Test func pausedSyncDoesNotClaimCombinedUsage() {
        let presentation = MidasSyncPresentation(
            isEnabled: false, includesSyncedUsage: true, hasFolder: true, otherMacCount: 2)
        #expect(presentation.title == "Sync paused")
        #expect(presentation.sharingSummary == nil)
    }

    @Test func syncWithoutFolderAsksForSetup() {
        let presentation = MidasSyncPresentation(
            isEnabled: true, includesSyncedUsage: true, hasFolder: false, otherMacCount: 1)
        #expect(presentation.title == "Choose a sync folder")
        #expect(presentation.sharingSummary == nil)
    }

    @Test func savedLocalUsageWaitsForAnotherMac() {
        let presentation = MidasSyncPresentation(
            isEnabled: true, includesSyncedUsage: true, hasFolder: true, otherMacCount: 0)
        #expect(presentation.title == "Combined usage")
        #expect(presentation.sharingSummary == "Waiting for usage from another Mac.")
    }

    @Test func localScopeCanKeepReceivingUsage() {
        let presentation = MidasSyncPresentation(
            isEnabled: true, includesSyncedUsage: false, hasFolder: true, otherMacCount: 1)
        #expect(presentation.title == "Usage on this Mac")
        #expect(presentation.sharingSummary == "Usage received from 1 other Mac.")
    }

    @Test func multipleMacsAreDescribedAsReceivedUsage() {
        let presentation = MidasSyncPresentation(
            isEnabled: true, includesSyncedUsage: true, hasFolder: true, otherMacCount: 2)
        #expect(presentation.sharingSummary == "Usage received from 2 other Macs.")
    }

    @Test @MainActor func syncTabIsAnIndependentSettingsDestination() throws {
        #expect(PreferencesTab.allCases.contains(.sync))
        #expect(PreferencesTab.sync.title == "Sync")
        #expect(PreferencesTab.sync.symbol == "icloud")
        #expect(PreferencesTab.sync.preferredWidth == PreferencesTab.defaultWidth)

        let suite = "MidasSyncNavigationTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selection = PreferencesSelection(onboardingDefaults: defaults)
        selection.tab = .sync
        #expect(selection.tab == .sync)
        #expect(selection.requestedProvider == nil)
        #expect(!selection.requestsSpendSetup)
    }
}
