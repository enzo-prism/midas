import Foundation

/// The latest signed Midas item from the public Sparkle feed.
struct MidasAppcastItem: Equatable, Sendable {
    let version: String
    let build: Int
    let downloadURL: URL
    let title: String
    let length: Int?

    func isNewer(thanBuild currentBuild: Int) -> Bool {
        self.build > currentBuild
    }
}

enum MidasAppcastParser {
    static func item(from xml: String) -> MidasAppcastItem? {
        guard let data = xml.data(using: .utf8) else { return nil }
        return self.item(from: data)
    }

    static func item(from data: Data) -> MidasAppcastItem? {
        let parser = Delegate()
        let xmlParser = XMLParser(data: data)
        xmlParser.shouldProcessNamespaces = true
        xmlParser.delegate = parser
        guard xmlParser.parse() else { return nil }
        return parser.item
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        private var currentElement = ""
        private var versionText = ""
        private var shortVersionText = ""
        private var titleText = ""
        private var enclosureURL: String?
        private var enclosureLength: Int?
        private var sawItem = false

        var item: MidasAppcastItem? {
            guard self.sawItem,
                  let build = Int(self.versionText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  build > 0,
                  let url = URL(string: self.enclosureURL ?? ""),
                  url.scheme == "https",
                  url.host == "github.com",
                  url.path.contains("/enzo-prism/midas/releases/download/")
            else { return nil }
            let version = self.shortVersionText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !version.isEmpty else { return nil }
            let title = self.titleText.trimmingCharacters(in: .whitespacesAndNewlines)
            return MidasAppcastItem(
                version: version,
                build: build,
                downloadURL: url,
                title: title.isEmpty ? "Midas \(version)" : title,
                length: self.enclosureLength)
        }

        func parser(
            _: XMLParser,
            didStartElement elementName: String,
            namespaceURI _: String?,
            qualifiedName _: String?,
            attributes attributeDict: [String: String] = [:])
        {
            self.currentElement = elementName
            if elementName == "item" {
                self.sawItem = true
                self.titleText = ""
            }
            guard elementName == "enclosure" else { return }
            self.enclosureURL = attributeDict["url"]
            if let length = attributeDict["length"] { self.enclosureLength = Int(length) }
        }

        func parser(_: XMLParser, foundCharacters string: String) {
            switch self.currentElement {
            case "version":
                self.versionText += string
            case "shortVersionString":
                self.shortVersionText += string
            case "title":
                if self.sawItem { self.titleText += string }
            default:
                break
            }
        }

        func parser(
            _: XMLParser,
            didEndElement elementName: String,
            namespaceURI _: String?,
            qualifiedName _: String?)
        {
            if elementName == self.currentElement { self.currentElement = "" }
        }
    }
}
