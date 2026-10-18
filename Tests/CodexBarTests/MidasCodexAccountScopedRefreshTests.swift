import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension CodexAccountScopedRefreshTests {
    @Test
    func `single filtered account retains verified identity when quota omits email`() async throws {
        let settings = self.makeSettingsStore(suite: "MidasCodexAccountScopedRefreshTests-single-filter")
        settings.refreshFrequency = .manual
        settings.midasTrackAllAccounts = false
        settings.multiAccountMenuLayout = .segmented
        let target = ManagedCodexAccount(
            id: UUID(),
            email: "selected@example.com",
            managedHomePath: "/synthetic/codex-selected",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let other = ManagedCodexAccount(
            id: UUID(),
            email: "excluded@example.com",
            managedHomePath: "/synthetic/codex-excluded",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [target, other])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: other.id)
        settings.midasCodexAccountEmailFilter = target.email
        let store = self.makeUsageStore(settings: settings)
        self.installContextualCodexProvider(on: store) { context in
            #expect(context.env["CODEX_HOME"] == target.managedHomePath)
            return UsageSnapshot(
                primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date())
        }

        #expect(store.shouldFetchAllCodexVisibleAccounts())
        await store.refreshProvider(.codex, allowDisabled: true)

        let snapshot = try #require(store.snapshot(for: .codex))
        #expect(snapshot.accountEmail(for: .codex) == target.email)
        #expect(snapshot.primary?.usedPercent == 42)
        #expect(store.codexAccountSnapshots.count == 1)
        #expect(store.codexAccountSnapshots.first?.account.email == target.email)
        #expect(store.lastCodexAccountScopedRefreshGuard?.source == .managedAccount(id: target.id))
        #expect(store.codexConsumerProjection(surface: .liveCard).rateWindow(for: .session)?.usedPercent == 42)
    }
}
