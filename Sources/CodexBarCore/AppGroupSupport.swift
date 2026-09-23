import Foundation
#if os(macOS)
import Security
#endif

public enum AppGroupSupport {
    public static let defaultTeamID = MidasIdentity.teamID
    /// Info.plist key carrying the signing team. The key name is inherited and intentionally stable.
    public static let teamIDInfoKey = "CodexBarTeamID"
    /// Upstream CodexBar group ids from before team-prefixed groups existed.
    public static let legacyReleaseGroupID = "group.\(MidasIdentity.Upstream.bundleIdentifier)"
    public static let legacyDebugGroupID = "group.\(MidasIdentity.Upstream.debugBundleIdentifier)"
    public static let widgetSnapshotFilename = "widget-snapshot.json"
    /// Version 2: Midas 0.37.0 moved to its own bundle identifier and app group.
    public static let migrationVersion = 2
    public static let migrationVersionKey = "appGroupMigrationVersion"
    private static let sharedDefaultsMigrationKeys = [
        "debugDisableKeychainAccess",
        "widgetSelectedProvider",
    ]

    public struct MigrationResult: Sendable {
        public enum Status: String, Sendable {
            case alreadyCompleted
            case targetUnavailable
            case noChangesNeeded
            case migrated
        }

        public let status: Status
        public let copiedSnapshot: Bool
        public let copiedDefaults: Int

        public init(status: Status, copiedSnapshot: Bool = false, copiedDefaults: Int = 0) {
            self.status = status
            self.copiedSnapshot = copiedSnapshot
            self.copiedDefaults = copiedDefaults
        }
    }

    public static func currentGroupID(for bundleID: String? = Bundle.main.bundleIdentifier) -> String {
        self.currentGroupID(teamID: self.resolvedTeamID(), bundleID: bundleID)
    }

    static func currentGroupID(teamID: String, bundleID: String?) -> String {
        "\(teamID).\(MidasIdentity.bundleIdentifier(matchingLegacy: bundleID))"
    }

    /// Group ids that earlier builds may have written to, newest first: Midas builds before 0.36.0
    /// (team-prefixed CodexBar identity) and upstream CodexBar's original `group.` identifier.
    public static func legacyGroupIDs(
        for bundleID: String? = Bundle.main.bundleIdentifier,
        teamID: String? = nil) -> [String]
    {
        let team = teamID ?? self.resolvedTeamID()
        let midasEra = "\(team).\(MidasIdentity.legacyBundleIdentifier(for: bundleID))"
        return [midasEra, self.legacyGroupID(for: bundleID)]
    }

    public static func resolvedTeamID(bundle: Bundle = .main) -> String {
        self.resolvedTeamID(
            infoDictionaryOverride: bundle.infoDictionary,
            bundleURLOverride: bundle.bundleURL)
    }

    static func resolvedTeamID(
        infoDictionaryOverride: [String: Any]?,
        bundleURLOverride: URL?) -> String
    {
        if let teamID = self.codeSignatureTeamID(bundleURL: bundleURLOverride) {
            return teamID
        }
        if let teamID = infoDictionaryOverride?[self.teamIDInfoKey] as? String,
           !teamID.isEmpty
        {
            return teamID
        }
        return self.defaultTeamID
    }

    public static func legacyGroupID(for bundleID: String? = Bundle.main.bundleIdentifier) -> String {
        self.isDebugBundleID(bundleID) ? self.legacyDebugGroupID : self.legacyReleaseGroupID
    }

    public static func sharedDefaults(
        bundleID: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default)
        -> UserDefaults?
    {
        guard self.currentContainerURL(bundleID: bundleID, fileManager: fileManager) != nil else { return nil }
        return UserDefaults(suiteName: self.currentGroupID(for: bundleID))
    }

    public static func currentContainerURL(
        bundleID: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default)
        -> URL?
    {
        #if os(macOS)
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: self.currentGroupID(for: bundleID))
        #else
        nil
        #endif
    }

    public static func snapshotURL(
        bundleID: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> URL
    {
        if let container = self.currentContainerURL(bundleID: bundleID, fileManager: fileManager) {
            return container.appendingPathComponent(self.widgetSnapshotFilename, isDirectory: false)
        }

        let directory = self.localFallbackDirectory(fileManager: fileManager, homeDirectory: homeDirectory)
        return directory.appendingPathComponent(self.widgetSnapshotFilename, isDirectory: false)
    }

    public static func localFallbackDirectory(
        fileManager: FileManager = .default,
        homeDirectory _: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> URL
    {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = base.appendingPathComponent(MidasIdentity.supportDirectoryName, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func legacyContainerCandidateURL(
        bundleID: String? = Bundle.main.bundleIdentifier,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> URL
    {
        self.groupContainerURL(groupID: self.legacyGroupID(for: bundleID), homeDirectory: homeDirectory)
    }

    public static func legacyContainerCandidateURLs(
        bundleID: String? = Bundle.main.bundleIdentifier,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> [URL]
    {
        self.legacyGroupIDs(for: bundleID).map { self.groupContainerURL(groupID: $0, homeDirectory: homeDirectory) }
    }

    private static func groupContainerURL(groupID: String, homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
            .appendingPathComponent(groupID, isDirectory: true)
    }

    public static func migrateLegacyDataIfNeeded(
        bundleID: String? = Bundle.main.bundleIdentifier,
        standardDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        currentDefaultsOverride: UserDefaults? = nil,
        legacyDefaultsOverride: UserDefaults? = nil,
        currentSnapshotURLOverride: URL? = nil,
        legacySnapshotURLOverride: URL? = nil)
        -> MigrationResult
    {
        if standardDefaults.integer(forKey: self.migrationVersionKey) >= self.migrationVersion {
            return MigrationResult(status: .alreadyCompleted)
        }

        guard let currentDefaults = currentDefaultsOverride ?? self.sharedDefaults(
            bundleID: bundleID,
            fileManager: fileManager)
        else {
            return MigrationResult(status: .targetUnavailable)
        }

        let legacyDefaultsCandidates: [UserDefaults] = if let legacyDefaultsOverride {
            [legacyDefaultsOverride]
        } else {
            self.legacyGroupIDs(for: bundleID).compactMap { UserDefaults(suiteName: $0) }
        }
        let currentSnapshotURL = currentSnapshotURLOverride
            ?? self.currentContainerURL(bundleID: bundleID, fileManager: fileManager)?
            .appendingPathComponent(self.widgetSnapshotFilename, isDirectory: false)
        let legacySnapshotURLs: [URL] = if let legacySnapshotURLOverride {
            [legacySnapshotURLOverride]
        } else {
            self.legacyContainerCandidateURLs(bundleID: bundleID, homeDirectory: homeDirectory)
                .map { $0.appendingPathComponent(self.widgetSnapshotFilename, isDirectory: false) }
        }

        let copiedSnapshot = {
            guard let currentSnapshotURL else { return false }
            guard !fileManager.fileExists(atPath: currentSnapshotURL.path),
                  let legacySnapshotURL = legacySnapshotURLs.first(where: { fileManager.fileExists(atPath: $0.path) })
            else {
                return false
            }
            do {
                try fileManager.createDirectory(
                    at: currentSnapshotURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try fileManager.copyItem(at: legacySnapshotURL, to: currentSnapshotURL)
                return true
            } catch {
                return false
            }
        }()

        let copiedDefaults = self.copyLegacySharedDefaults(
            from: legacyDefaultsCandidates,
            to: currentDefaults)

        let result = if copiedSnapshot || copiedDefaults > 0 {
            MigrationResult(
                status: .migrated,
                copiedSnapshot: copiedSnapshot,
                copiedDefaults: copiedDefaults)
        } else {
            MigrationResult(status: .noChangesNeeded)
        }

        standardDefaults.set(self.migrationVersion, forKey: self.migrationVersionKey)
        return result
    }

    private static func copyLegacySharedDefaults(
        from legacyCandidates: [UserDefaults],
        to currentDefaults: UserDefaults) -> Int
    {
        var copied = 0
        for key in self.sharedDefaultsMigrationKeys {
            guard currentDefaults.object(forKey: key) == nil,
                  let legacyValue = legacyCandidates.lazy.compactMap({ $0.object(forKey: key) }).first
            else {
                continue
            }
            currentDefaults.set(legacyValue, forKey: key)
            copied += 1
        }
        return copied
    }

    private static func isDebugBundleID(_ bundleID: String?) -> Bool {
        MidasIdentity.isDebugBundleIdentifier(bundleID)
    }

    private static func codeSignatureTeamID(bundleURL: URL?) -> String? {
        #if os(macOS)
        guard let bundleURL else { return nil }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let code = staticCode
        else {
            return nil
        }

        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoCF) == errSecSuccess,
            let info = infoCF as? [String: Any],
            let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String,
            !teamID.isEmpty
        else {
            return nil
        }
        return teamID
        #else
        _ = bundleURL
        return nil
        #endif
    }
}
