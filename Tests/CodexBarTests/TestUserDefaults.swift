import Foundation

/// Test-only replacement for `UserDefaults(suiteName:)` that keeps suites out of `~/Library/Preferences`.
///
/// A plain suite name becomes a plist in the user's real Preferences folder, and removing the domain
/// leaves an empty file behind. Thousands of them accumulated, and that churn coincided with the
/// user's preferences daemon no longer persisting any app's settings. CFPreferences accepts an
/// absolute path as a domain name, so every test suite lives in a per-process temporary folder that
/// is deleted when the test process exits. Use `domain(_:)` wherever a test passes a suite name to
/// `removePersistentDomain(forName:)` or `persistentDomain(forName:)`.
enum TestUserDefaults {
    private static let root: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("midas-test-defaults-\(getpid())-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        atexit { TestUserDefaults.removeRoot() }
        return url
    }()

    /// The isolated domain for a test suite name. Already-isolated names are returned unchanged.
    static func domain(_ name: String) -> String {
        let rootPath = self.root.path
        if name.hasPrefix(rootPath + "/") { return name }
        let file = name.replacingOccurrences(of: "/", with: "-")
        return self.root.appendingPathComponent(file).path
    }

    static func suite(_ name: String) -> UserDefaults? {
        UserDefaults(suiteName: self.domain(name))
    }

    private static func removeRoot() {
        try? FileManager.default.removeItem(at: self.root)
    }
}
