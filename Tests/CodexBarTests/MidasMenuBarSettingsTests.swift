import CodexBarCore
import Foundation
import Observation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct MidasMenuBarSettingsTests {
    @Test func defaultsChooseLedgerWithoutChangingLegacyPreferences() throws {
        let (settings, defaults, suite) = try self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(settings.midasMenuBarMode == .ledger)
        #expect(settings.midasMenuBarFocusProvider == .codex)
        #expect(!settings.midasMenuBarHideSpend)
        settings.mergeIcons = false
        settings.midasMenuBarMode = .focus
        settings.midasMenuBarMode = .legacy
        #expect(!settings.mergeIcons)
    }

    @Test func allPreferencesPersistAndReload() throws {
        let (settings, defaults, suite) = try self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.midasMenuBarMode = .constellation
        settings.midasMenuBarFocusProvider = .meta
        settings.midasMenuBarHideSpend = true
        #expect(defaults.string(forKey: "midasMenuBarMode") == "constellation")
        #expect(defaults.string(forKey: "midasMenuBarFocusProvider") == "meta")
        #expect(defaults.bool(forKey: "midasMenuBarHideSpend"))
        let reloaded = self.store(defaults: defaults, suite: suite)
        #expect(reloaded.midasMenuBarMode == .constellation)
        #expect(reloaded.midasMenuBarFocusProvider == .meta)
        #expect(reloaded.midasMenuBarHideSpend)
    }

    @Test func invalidStoredValuesHaveSafeDefaults() throws {
        let (_, defaults, suite) = try self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("future-style", forKey: "midasMenuBarMode")
        defaults.set("missing-provider", forKey: "midasMenuBarFocusProvider")
        let reloaded = self.store(defaults: defaults, suite: suite)
        #expect(reloaded.midasMenuBarMode == .ledger)
        #expect(reloaded.midasMenuBarFocusProvider == .codex)
    }

    @Test func preferencesParticipateInObservation() throws {
        let (settings, defaults, suite) = try self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let flag = ObservationFlag()
        withObservationTracking {
            _ = settings.midasMenuBarMode
            _ = settings.midasMenuBarFocusProvider
            _ = settings.midasMenuBarHideSpend
        } onChange: {
            flag.markChanged()
        }
        settings.midasMenuBarHideSpend = true
        #expect(flag.changed)
    }

    @Test func descriptionsPreserveCodexWeeklyMeaning() {
        #expect(DisplayPane.menuBarDescription(.focus).contains("weekly capacity remaining"))
        #expect(DisplayPane.menuBarDescription(.ledger).contains("estimate"))
        #expect(MidasMenuBarMode.allCases.allSatisfy { !DisplayPane.menuBarPreview($0).isEmpty })
    }

    @Test func orbitMigrationPromotesNewAndLedgerMidasDefaultsOnlyOnce() throws {
        for initial in [nil, "ledger"] as [String?] {
            let suite = "MidasOrbitMigration-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            if let initial { defaults.set(initial, forKey: "midasMenuBarMode") }
            defaults.set("meta", forKey: "midasMenuBarFocusProvider")
            #expect(SettingsStore.loadMidasMenuBarMode(userDefaults: defaults, isMidasApp: true) == .orbit)
            #expect(defaults.string(forKey: "midasMenuBarFocusProvider") == "meta")
            defaults.set("ledger", forKey: "midasMenuBarMode")
            #expect(SettingsStore.loadMidasMenuBarMode(userDefaults: defaults, isMidasApp: true) == .ledger)
        }
    }

    @Test func orbitMigrationPreservesExplicitAlternativeModes() throws {
        for initial in [MidasMenuBarMode.focus, .constellation, .legacy, .orbit] {
            let suite = "MidasOrbitPreservation-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(initial.rawValue, forKey: "midasMenuBarMode")
            #expect(SettingsStore.loadMidasMenuBarMode(userDefaults: defaults, isMidasApp: true) == initial)
            #expect(defaults.bool(forKey: "midasMenuBarOrbitMigrationCompleted"))
        }
    }

    @Test func nonMidasLaunchDoesNotConsumeOrbitMigration() throws {
        let suite = "MidasOrbitOtherBundle-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SettingsStore.loadMidasMenuBarMode(userDefaults: defaults, isMidasApp: false) == .ledger)
        #expect(!defaults.bool(forKey: "midasMenuBarOrbitMigrationCompleted"))
        #expect(SettingsStore.loadMidasMenuBarMode(userDefaults: defaults, isMidasApp: true) == .orbit)
    }

    private func makeSettings() throws -> (SettingsStore, UserDefaults, String) {
        let suite = "MidasMenuBarSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (self.store(defaults: defaults, suite: suite), defaults, suite)
    }

    private func store(defaults: UserDefaults, suite: String) -> SettingsStore {
        SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite, reset: false),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
    }

    private final class ObservationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var changed: Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.value
        }

        func markChanged() {
            self.lock.lock()
            self.value = true
            self.lock.unlock()
        }
    }
}
