import Foundation

/// Product identity for Midas.
///
/// Midas is a fork of CodexBar (https://github.com/steipete/CodexBar, MIT License) that ships and
/// evolves as its own project. Everything macOS, users, or other apps can observe — bundle
/// identifier, executable, app-group, Keychain services, storage folders, log subsystem, and the
/// update feed — belongs to Midas and is defined here. Swift module and target names
/// (`CodexBarCore`, `CodexBar`, `CodexBarCLI`, …) are inherited source-level names and are kept
/// unchanged so upstream changes can still be reviewed and merged; they are not product identity.
///
/// `MidasIdentity.Upstream` records the inherited CodexBar identifiers. They exist only for
/// attribution and one-time migration of data written by builds older than Midas 0.37.0.
public enum MidasIdentity {
    public static let productName = "Midas"
    public static let bundleIdentifier = "com.designprism.midas"
    public static let debugBundleIdentifier = "com.designprism.midas.debug"
    public static let widgetBundleIdentifierSuffix = "widget"
    public static let executableName = "Midas"
    public static let bundleName = "Midas.app"
    public static let teamID = "L49MKXGVM4"
    public static let developerName = "Lorenzo Quaid Sison"
    public static let repositoryURL = URL(string: "https://github.com/enzo-prism/midas")!
    public static let releasesURL = URL(string: "https://github.com/enzo-prism/midas/releases")!
    public static let websiteURL = URL(string: "https://midas-by-prism.vercel.app")!

    /// Folder name under `~/Library/Application Support`, `~/Library/Caches`, and `~/Library/Logs`.
    public static let supportDirectoryName = "Midas"
    /// Keychain service for provider cookies and API tokens stored by the app.
    public static let keychainService = "com.designprism.midas"
    /// Keychain service for short-lived credential caches.
    public static let keychainCacheService = "com.designprism.midas.cache"
    public static let logSubsystem = "com.designprism.midas"
    /// UserDefaults domains the CLI consults for app preferences (release first, then debug).
    public static let defaultsDomains = [bundleIdentifier, debugBundleIdentifier]

    /// Identifiers inherited from upstream CodexBar. Read-only: used for attribution and to adopt
    /// data written before Midas had its own identity. Never write new data under these.
    public enum Upstream {
        public static let productName = "CodexBar"
        public static let author = "Peter Steinberger"
        public static let license = "MIT License"
        public static let repositoryURL = URL(string: "https://github.com/steipete/CodexBar")!
        public static let licenseURL = URL(string: "https://github.com/steipete/CodexBar/blob/main/LICENSE")!
        public static let bundleIdentifier = "com.steipete.codexbar"
        public static let debugBundleIdentifier = "com.steipete.codexbar.debug"
        public static let teamID = "Y5PE65HELJ"
        public static let supportDirectoryName = "CodexBar"
        public static let keychainService = "com.steipete.CodexBar"
        public static let keychainCacheService = "com.steipete.codexbar.cache"
        public static let defaultsDomains = [bundleIdentifier, debugBundleIdentifier]
    }

    public static func isDebugBundleIdentifier(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return bundleID.hasSuffix(".debug")
    }

    /// The Midas bundle identifier that corresponds to a legacy CodexBar-era identifier.
    public static func bundleIdentifier(matchingLegacy legacyID: String?) -> String {
        self.isDebugBundleIdentifier(legacyID) ? self.debugBundleIdentifier : self.bundleIdentifier
    }

    /// The legacy CodexBar-era identifier that corresponds to a Midas identifier.
    public static func legacyBundleIdentifier(for bundleID: String?) -> String {
        self.isDebugBundleIdentifier(bundleID) ? Upstream.debugBundleIdentifier : Upstream.bundleIdentifier
    }
}
