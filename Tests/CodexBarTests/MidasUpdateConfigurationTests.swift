import Foundation
import Testing
@testable import CodexBar

struct MidasUpdateConfigurationTests {
    @Test func acceptsOnlyMidasFeedAndSigningKey() {
        #expect(MidasUpdateConfiguration.isValid(
            feedURL: MidasUpdateConfiguration.feedURL,
            publicKey: MidasUpdateConfiguration.publicKey))
        #expect(Data(base64Encoded: MidasUpdateConfiguration.publicKey)?.count == 32)
    }

    @Test func rejectsMissingConfiguration() {
        #expect(!MidasUpdateConfiguration.isValid(feedURL: nil, publicKey: nil))
        #expect(!MidasUpdateConfiguration.isValid(
            feedURL: MidasUpdateConfiguration.feedURL,
            publicKey: nil))
        #expect(!MidasUpdateConfiguration.isValid(
            feedURL: nil,
            publicKey: MidasUpdateConfiguration.publicKey))
    }

    @Test func rejectsUpstreamFeedAndKey() {
        #expect(!MidasUpdateConfiguration.isValid(
            feedURL: "https://raw.githubusercontent.com/steipete/CodexBar/main/appcast.xml",
            publicKey: MidasUpdateConfiguration.publicKey))
        #expect(!MidasUpdateConfiguration.isValid(
            feedURL: MidasUpdateConfiguration.feedURL,
            publicKey: "AGCY8w5vHirVfGGDGc8Szc5iuOqupZSh9pMj/Qs67XI="))
    }

    @Test func rejectsLookalikeAndInsecureFeedURLs() {
        let rejected = [
            MidasUpdateConfiguration.feedURL.replacingOccurrences(of: "https://", with: "http://"),
            MidasUpdateConfiguration.feedURL + "?redirect=upstream",
            MidasUpdateConfiguration.feedURL.replacingOccurrences(of: "github.com/", with: "github.com.evil.test/"),
            MidasUpdateConfiguration.feedURL.replacingOccurrences(of: "enzo-prism/midas", with: "other/midas"),
            MidasUpdateConfiguration.feedURL.replacingOccurrences(of: "arm64", with: "x86_64"),
        ]
        for feedURL in rejected {
            #expect(!MidasUpdateConfiguration.isValid(
                feedURL: feedURL,
                publicKey: MidasUpdateConfiguration.publicKey))
        }
    }

    @Test func rejectsChangedOrWhitespaceSigningKey() {
        for key in ["", "invalid", MidasUpdateConfiguration.publicKey + "\n"] {
            #expect(!MidasUpdateConfiguration.isValid(
                feedURL: MidasUpdateConfiguration.feedURL,
                publicKey: key))
        }
    }
}
