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

    @Test func parsesSignedMidasAppcastItem() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
          <channel>
            <title>Midas Updates</title>
            <item>
              <title>Midas 0.35.2</title>
              <sparkle:version>105</sparkle:version>
              <sparkle:shortVersionString>0.35.2</sparkle:shortVersionString>
              <enclosure url="https://github.com/enzo-prism/midas/releases/download/v0.35.2-midas.1/Midas-0.35.2-macos-arm64.zip" length="26642135" type="application/octet-stream" />
            </item>
          </channel>
        </rss>
        """
        let item = try #require(MidasAppcastParser.item(from: xml))
        #expect(item.version == "0.35.2")
        #expect(item.build == 105)
        #expect(item.title == "Midas 0.35.2")
        #expect(item.length == 26_642_135)
        #expect(item.downloadURL.absoluteString
            == "https://github.com/enzo-prism/midas/releases/download/v0.35.2-midas.1/Midas-0.35.2-macos-arm64.zip")
        #expect(item.isNewer(thanBuild: 104))
        #expect(!item.isNewer(thanBuild: 105))
        #expect(!item.isNewer(thanBuild: 106))
    }

    @Test func rejectsNonMidasEnclosureHosts() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
          <channel>
            <item>
              <title>Midas 0.35.2</title>
              <sparkle:version>105</sparkle:version>
              <sparkle:shortVersionString>0.35.2</sparkle:shortVersionString>
              <enclosure url="https://example.com/Midas-0.35.2-macos-arm64.zip" length="1" />
            </item>
          </channel>
        </rss>
        """
        #expect(MidasAppcastParser.item(from: xml) == nil)
    }

    @Test func signedReleasePromptDownloadsNewerAndCurrentBuilds() {
        let item = MidasAppcastItem(
            version: "0.35.2",
            build: 105,
            downloadURL: URL(
                string: "https://github.com/enzo-prism/midas/releases/download/v0.35.2-midas.1/Midas-0.35.2-macos-arm64.zip")!,
            title: "Midas 0.35.2",
            length: 1)
        let newer = MidasSignedReleasePrompt.make(item: item, currentBuild: 82)
        #expect(newer.primaryChoice == .download)
        #expect(newer.primaryTitle == "Download 0.35.2")
        let current = MidasSignedReleasePrompt.make(item: item, currentBuild: 105)
        #expect(current.primaryChoice == .download)
        #expect(current.title.contains("0.35.2"))
    }
}
