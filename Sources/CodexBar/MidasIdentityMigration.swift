import CodexBarCore
import Foundation

/// One-time adoption of local data written by Midas builds that still ran under CodexBar's identity
/// (bundle id `com.steipete.codexbar`, storage folders named `CodexBar` or after the bundle id)
/// before Midas 0.37.0.
///
/// Runs before anything reads preferences. Copies, never moves or deletes, so an upstream CodexBar
/// install on the same Mac keeps its own data. Keychain items are adopted lazily by
/// `MidasLegacyKeychain`, and the widget app group by `AppGroupSupport`.
enum MidasIdentityMigration {
    static let versionKey = "midasIdentityMigrationVersion"
    /// Version 2 also merges the bundle-identifier-named Application Support folder (plan history).
    static let version = 2
    static let librarySubdirectories = ["Application Support", "Caches", "Logs"]
    /// Migration bookkeeping that must not be carried over from the legacy domain.
    static let skippedDefaultsKeys: Set<String> = [
        versionKey,
        AppGroupSupport.migrationVersionKey,
        "KeychainMigrationV1Completed",
    ]

    struct Result: Equatable, Sendable {
        enum Status: String, Sendable {
            case alreadyCompleted
            case skipped
            case migrated
            case nothingToMigrate
        }

        var status: Status
        var copiedDefaultsKeys = 0
        var copiedItems = 0
    }

    static func runIfNeeded(
        defaults: UserDefaults = .standard,
        bundleID: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default,
        libraryDirectory: URL? = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first,
        defaultsDomainsOverride: (current: String, legacy: String)? = nil)
        -> Result
    {
        if defaults.integer(forKey: self.versionKey) >= self.version {
            return Result(status: .alreadyCompleted)
        }
        guard let bundleID, !bundleID.isEmpty,
              bundleID == MidasIdentity.bundleIdentifier || bundleID == MidasIdentity.debugBundleIdentifier
        else {
            // Unbundled (swift run / tests) or foreign identity: leave data alone and retry next launch.
            return Result(status: .skipped)
        }

        // Persistent domains are global by name, so tests must pass hermetic domain names here.
        let domains = defaultsDomainsOverride
            ?? (current: bundleID, legacy: MidasIdentity.legacyBundleIdentifier(for: bundleID))
        let copiedKeys = self.adoptDefaults(
            defaults: defaults,
            currentDomain: domains.current,
            legacyDomain: domains.legacy)
        let copiedItems = self.adoptLibraryDirectories(fileManager: fileManager, libraryDirectory: libraryDirectory)

        defaults.set(self.version, forKey: self.versionKey)
        let status: Result.Status = (copiedKeys + copiedItems) > 0 ? .migrated : .nothingToMigrate
        return Result(status: status, copiedDefaultsKeys: copiedKeys, copiedItems: copiedItems)
    }

    /// Copies every preference from the legacy domain that the current domain does not define yet.
    static func adoptDefaults(defaults: UserDefaults, currentDomain: String, legacyDomain: String) -> Int {
        guard currentDomain != legacyDomain,
              let legacy = defaults.persistentDomain(forName: legacyDomain), !legacy.isEmpty
        else { return 0 }
        var current = defaults.persistentDomain(forName: currentDomain) ?? [:]
        var copied = 0
        for (key, value) in legacy where current[key] == nil && !self.skippedDefaultsKeys.contains(key) {
            current[key] = value
            copied += 1
        }
        if copied > 0 {
            defaults.setPersistentDomain(current, forName: currentDomain)
        }
        return copied
    }

    /// Copies `<Library>/<sub>/CodexBar/*` into `<Library>/<sub>/Midas/` and
    /// `<Library>/<sub>/com.steipete.codexbar/*` into `<Library>/<sub>/com.designprism.midas/`, item by
    /// item, skipping anything already present so a partially populated Midas folder is merged, not replaced.
    static func adoptLibraryDirectories(fileManager: FileManager, libraryDirectory: URL?) -> Int {
        guard let libraryDirectory else { return 0 }
        let folderPairs = [
            (MidasIdentity.Upstream.supportDirectoryName, MidasIdentity.supportDirectoryName),
            (MidasIdentity.Upstream.bundleIdentifier, MidasIdentity.bundleIdentifier),
        ]
        var copied = 0
        for sub in self.librarySubdirectories {
            let base = libraryDirectory.appendingPathComponent(sub, isDirectory: true)
            for (legacyName, currentName) in folderPairs {
                let source = base.appendingPathComponent(legacyName, isDirectory: true)
                let target = base.appendingPathComponent(currentName, isDirectory: true)
                copied += self.mergeDirectory(from: source, into: target, fileManager: fileManager)
            }
        }
        return copied
    }

    static func mergeDirectory(from source: URL, into target: URL, fileManager: FileManager) -> Int {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let items = try? fileManager.contentsOfDirectory(
                  at: source,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles])
        else { return 0 }
        try? fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        var copied = 0
        for item in items {
            let destination = target.appendingPathComponent(item.lastPathComponent)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            do {
                try fileManager.copyItem(at: item, to: destination)
                copied += 1
            } catch {
                continue
            }
        }
        return copied
    }
}
