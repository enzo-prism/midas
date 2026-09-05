import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct MidasProviderNavigationTests {
    @Test func accountActionsTargetTheirOwnProvider() {
        let selection = PreferencesSelection()
        for provider: UsageProvider in [.codex, .cursor, .meta] {
            selection.showProvider(provider)
            #expect(selection.tab == .providers)
            #expect(selection.requestedProvider == provider)
        }
    }

    @Test func repeatingProviderRequestStillResetsFilteredNavigation() {
        let selection = PreferencesSelection()
        selection.showProvider(.cursor)
        let firstRequest = selection.providerRequestID
        selection.showProvider(.cursor)
        #expect(selection.providerRequestID != firstRequest)
        #expect(selection.requestedProvider == .cursor)
    }
}
