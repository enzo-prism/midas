import CodexBarCore
import Foundation
import Observation

@MainActor
@Observable
final class PreferencesSelection {
    var tab: PreferencesTab = .general
    private(set) var requestedProvider: UsageProvider?
    private(set) var providerRequestID = UUID()

    func showProvider(_ provider: UsageProvider) {
        self.requestedProvider = provider
        self.providerRequestID = UUID()
        self.tab = .providers
    }
}
