import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct MidasIdentityTests {
    @Test func `midas identity is distinct from upstream CodexBar everywhere macOS can observe it`() {
        #expect(MidasIdentity.bundleIdentifier == "com.designprism.midas")
        #expect(MidasIdentity.debugBundleIdentifier == "com.designprism.midas.debug")
        #expect(MidasIdentity.bundleIdentifier != MidasIdentity.Upstream.bundleIdentifier)
        #expect(MidasIdentity.keychainService != MidasIdentity.Upstream.keychainService)
        #expect(MidasIdentity.keychainCacheService != MidasIdentity.Upstream.keychainCacheService)
        #expect(MidasIdentity.supportDirectoryName != MidasIdentity.Upstream.supportDirectoryName)
        #expect(MidasIdentity.teamID != MidasIdentity.Upstream.teamID)
        #expect(MidasIdentity.executableName == "Midas")
        #expect(MidasIdentity.bundleName == "Midas.app")
        #expect(MidasIdentity.defaultsDomains == ["com.designprism.midas", "com.designprism.midas.debug"])
    }

    @Test func `identifiers use reverse-DNS form and never mention upstream`() {
        for identifier in [
            MidasIdentity.bundleIdentifier,
            MidasIdentity.debugBundleIdentifier,
            MidasIdentity.keychainService,
            MidasIdentity.keychainCacheService,
            MidasIdentity.logSubsystem,
        ] {
            #expect(identifier.range(of: #"^[a-z0-9]+(\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil)
            #expect(!identifier.lowercased().contains("steipete"))
            #expect(!identifier.lowercased().contains("codexbar"))
        }
    }

    @Test func `debug detection and legacy mapping stay symmetric`() {
        #expect(MidasIdentity.isDebugBundleIdentifier("com.designprism.midas.debug"))
        #expect(!MidasIdentity.isDebugBundleIdentifier("com.designprism.midas"))
        #expect(!MidasIdentity.isDebugBundleIdentifier(nil))
        #expect(MidasIdentity.bundleIdentifier(matchingLegacy: "com.steipete.codexbar") == "com.designprism.midas")
        #expect(
            MidasIdentity.bundleIdentifier(matchingLegacy: "com.steipete.codexbar.debug")
                == "com.designprism.midas.debug")
        #expect(MidasIdentity.legacyBundleIdentifier(for: "com.designprism.midas") == "com.steipete.codexbar")
        #expect(
            MidasIdentity.legacyBundleIdentifier(for: "com.designprism.midas.debug")
                == "com.steipete.codexbar.debug")
    }

    @Test func `update feed moved with the identity and keeps the legacy feed name distinct`() {
        #expect(MidasUpdateConfiguration.feedURL.hasSuffix("/Midas-appcast-arm64-v2.xml"))
        #expect(MidasUpdateConfiguration.legacyFeedURL.hasSuffix("/Midas-appcast-arm64.xml"))
        #expect(MidasUpdateConfiguration.feedURL != MidasUpdateConfiguration.legacyFeedURL)
    }
}

struct MidasIdentityMigrationTests {
    @Test func `adopts legacy defaults without overwriting current values or migration flags`() throws {
        let suite = "MidasIdentityMigrationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let legacyDomain = "\(suite).legacy"
        let currentDomain = "\(suite).current"
        defer {
            defaults.removePersistentDomain(forName: legacyDomain)
            defaults.removePersistentDomain(forName: currentDomain)
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.setPersistentDomain([
            "menuBarDisplayMode": "orbit",
            "resetTimesShowAbsolute": true,
            "KeychainMigrationV1Completed": true,
            AppGroupSupport.migrationVersionKey: 1,
        ], forName: legacyDomain)
        defaults.setPersistentDomain(["resetTimesShowAbsolute": false], forName: currentDomain)

        let copied = MidasIdentityMigration.adoptDefaults(
            defaults: defaults,
            currentDomain: currentDomain,
            legacyDomain: legacyDomain)

        let current = try #require(defaults.persistentDomain(forName: currentDomain))
        #expect(copied == 1)
        #expect(current["menuBarDisplayMode"] as? String == "orbit")
        #expect(current["resetTimesShowAbsolute"] as? Bool == false)
        #expect(current["KeychainMigrationV1Completed"] == nil)
        #expect(current[AppGroupSupport.migrationVersionKey] == nil)
    }

    @Test func `merges legacy library folders item by item and leaves the source intact`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let legacy = support.appendingPathComponent("CodexBar", isDirectory: true)
        let current = support.appendingPathComponent("Midas", isDirectory: true)
        try fileManager.createDirectory(at: legacy.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacy.appendingPathComponent("accounts.json"))
        try Data("legacy".utf8).write(to: legacy.appendingPathComponent("nested/history.json"))
        try Data("keep".utf8).write(to: legacy.appendingPathComponent("existing.json"))
        try Data("current".utf8).write(to: current.appendingPathComponent("existing.json"))
        let legacyByID = support.appendingPathComponent(MidasIdentity.Upstream.bundleIdentifier, isDirectory: true)
        let currentByID = support.appendingPathComponent(MidasIdentity.bundleIdentifier, isDirectory: true)
        try fileManager.createDirectory(
            at: legacyByID.appendingPathComponent("history"),
            withIntermediateDirectories: true)
        try Data("plan".utf8).write(to: legacyByID.appendingPathComponent("history/codex.json"))

        let copied = MidasIdentityMigration.adoptLibraryDirectories(fileManager: fileManager, libraryDirectory: root)

        #expect(copied == 3)
        #expect(try String(contentsOf: currentByID.appendingPathComponent("history/codex.json"), encoding: .utf8) ==
            "plan")
        #expect(try String(contentsOf: current.appendingPathComponent("accounts.json"), encoding: .utf8) == "legacy")
        #expect(
            try String(contentsOf: current.appendingPathComponent("nested/history.json"), encoding: .utf8)
                == "legacy")
        #expect(try String(contentsOf: current.appendingPathComponent("existing.json"), encoding: .utf8) == "current")
        #expect(fileManager.fileExists(atPath: legacy.appendingPathComponent("accounts.json").path))
        #expect(MidasIdentityMigration.adoptLibraryDirectories(fileManager: fileManager, libraryDirectory: root) == 0)
    }

    @Test func `runs once per bundle and skips unbundled or foreign identities`() throws {
        let suite = "MidasIdentityMigrationTests-run-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let domains = (current: "\(suite).current", legacy: "\(suite).legacy")
        defer {
            defaults.removePersistentDomain(forName: suite)
            defaults.removePersistentDomain(forName: domains.current)
            defaults.removePersistentDomain(forName: domains.legacy)
        }
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

        #expect(
            MidasIdentityMigration.runIfNeeded(
                defaults: defaults,
                bundleID: nil,
                libraryDirectory: empty,
                defaultsDomainsOverride: domains).status == .skipped)
        #expect(
            MidasIdentityMigration.runIfNeeded(
                defaults: defaults,
                bundleID: "com.steipete.codexbar",
                libraryDirectory: empty,
                defaultsDomainsOverride: domains).status == .skipped)
        #expect(defaults.integer(forKey: MidasIdentityMigration.versionKey) == 0)

        defaults.setPersistentDomain(["menuBarDisplayMode": "orbit"], forName: domains.legacy)
        let first = MidasIdentityMigration.runIfNeeded(
            defaults: defaults,
            bundleID: MidasIdentity.bundleIdentifier,
            libraryDirectory: empty,
            defaultsDomainsOverride: domains)
        #expect(first.status == .migrated)
        #expect(first.copiedDefaultsKeys == 1)
        #expect(defaults.persistentDomain(forName: domains.current)?["menuBarDisplayMode"] as? String == "orbit")
        #expect(defaults.integer(forKey: MidasIdentityMigration.versionKey) == MidasIdentityMigration.version)
        let second = MidasIdentityMigration.runIfNeeded(
            defaults: defaults,
            bundleID: MidasIdentity.bundleIdentifier,
            libraryDirectory: empty,
            defaultsDomainsOverride: domains)
        #expect(second.status == .alreadyCompleted)
    }
}
