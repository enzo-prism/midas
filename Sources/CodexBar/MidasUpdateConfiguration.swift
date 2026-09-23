import Foundation

/// Midas never consumes CodexBar's upstream update feed or signing key.
///
/// Midas 0.37.0 introduced its own bundle identifier. Sparkle refuses to install an update whose
/// bundle identifier differs from the running app, so builds with the Midas identity read the
/// `-v2` feed. The original feed name stays published for 0.33.3–0.36.0 clients as an
/// informational item that points them at the manual download.
enum MidasUpdateConfiguration {
    static let feedFileName = "Midas-appcast-arm64-v2.xml"
    static let legacyFeedFileName = "Midas-appcast-arm64.xml"
    static let feedURL = "https://github.com/enzo-prism/midas/releases/latest/download/\(feedFileName)"
    static let legacyFeedURL = "https://github.com/enzo-prism/midas/releases/latest/download/\(legacyFeedFileName)"
    static let publicKey = "Wamu4ydtrOgeiui2Synb1ixgdZcNwDOpE0TOCtDdEbA="
    static let releasesURL = URL(string: "https://github.com/enzo-prism/midas/releases/latest")!

    static func isValid(feedURL: String?, publicKey: String?) -> Bool {
        feedURL == self.feedURL && publicKey == self.publicKey
    }
}
