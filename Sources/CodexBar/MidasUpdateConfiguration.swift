import Foundation

/// Midas never consumes CodexBar's upstream update feed or signing key.
enum MidasUpdateConfiguration {
    static let feedURL = "https://github.com/enzo-prism/midas/releases/latest/download/Midas-appcast-arm64.xml"
    static let publicKey = "Wamu4ydtrOgeiui2Synb1ixgdZcNwDOpE0TOCtDdEbA="

    static func isValid(feedURL: String?, publicKey: String?) -> Bool {
        feedURL == self.feedURL && publicKey == self.publicKey
    }
}
