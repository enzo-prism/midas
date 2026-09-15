import AppKit
import Foundation

/// Downloads the latest signed Midas ZIP from the public feed when Sparkle cannot run.
///
/// Development, Apple Development, and ad-hoc builds cannot use Sparkle (it requires a
/// Developer ID signature). Check for Updates still reads the same appcast Sparkle uses
/// and opens the signed GitHub archive.
@MainActor
final class MidasSignedReleaseUpdater: UpdaterProviding {
    var automaticallyChecksForUpdates: Bool = false
    var automaticallyDownloadsUpdates: Bool = false
    let isAvailable: Bool = true
    let unavailableReason: String? = nil
    let updateStatus = UpdateStatus()

    private let session: URLSession
    private let openURL: (URL) -> Bool
    private let currentBuild: Int
    private let present: (MidasSignedReleasePrompt) -> MidasSignedReleaseChoice

    init(
        session: URLSession = .shared,
        currentBuild: Int = MidasSignedReleaseUpdater.runningBuild(),
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        present: @escaping (MidasSignedReleasePrompt) -> MidasSignedReleaseChoice = {
            MidasSignedReleaseUpdater.presentAlert($0)
        })
    {
        self.session = session
        self.currentBuild = currentBuild
        self.openURL = openURL
        self.present = present
    }

    func checkForUpdates(_ sender: Any?) {
        _ = sender
        Task { @MainActor in
            await self.check()
        }
    }

    func installUpdate() {
        self.checkForUpdates(nil)
    }

    func check() async {
        NSApp.activate(ignoringOtherApps: true)
        do {
            let item = try await self.loadLatestItem()
            let prompt = MidasSignedReleasePrompt.make(item: item, currentBuild: self.currentBuild)
            switch self.present(prompt) {
            case .download:
                _ = self.openURL(item.downloadURL)
            case .openReleases:
                _ = self.openURL(MidasUpdateConfiguration.releasesURL)
            case .cancel:
                break
            }
        } catch {
            switch self.present(.failed(error.localizedDescription)) {
            case .download, .openReleases:
                _ = self.openURL(MidasUpdateConfiguration.releasesURL)
            case .cancel:
                break
            }
        }
    }

    private func loadLatestItem() async throws -> MidasAppcastItem {
        guard let url = URL(string: MidasUpdateConfiguration.feedURL) else {
            throw URLError(.badURL)
        }
        let (data, response) = try await self.session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard let item = MidasAppcastParser.item(from: data) else {
            throw URLError(.cannotParseResponse)
        }
        return item
    }

    static func runningBuild() -> Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    static func presentAlert(_ prompt: MidasSignedReleasePrompt) -> MidasSignedReleaseChoice {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.alertStyle = .informational
        alert.addButton(withTitle: prompt.primaryTitle)
        alert.addButton(withTitle: "Cancel")
        let result = alert.runModal()
        if result == .alertFirstButtonReturn { return prompt.primaryChoice }
        return .cancel
    }
}

enum MidasSignedReleaseChoice {
    case download
    case openReleases
    case cancel
}

struct MidasSignedReleasePrompt: Equatable {
    let title: String
    let message: String
    let primaryTitle: String
    let primaryChoice: MidasSignedReleaseChoice

    static func make(item: MidasAppcastItem, currentBuild: Int) -> Self {
        if item.isNewer(thanBuild: currentBuild) {
            return Self(
                title: "Midas \(item.version) is available",
                message: "Download the latest signed Midas for Apple Silicon. Sparkle in-app install needs a Developer ID copy of Midas from Applications.",
                primaryTitle: "Download \(item.version)",
                primaryChoice: .download)
        }
        return Self(
            title: "Latest signed Midas is \(item.version)",
            message: "This build cannot use Sparkle in-app updates. You can still download the latest signed Midas ZIP from GitHub.",
            primaryTitle: "Download \(item.version)",
            primaryChoice: .download)
    }

    static func failed(_ detail: String) -> Self {
        Self(
            title: "Could not check for updates",
            message: "\(detail)\n\nOpen GitHub releases to download Midas manually.",
            primaryTitle: "Open Releases",
            primaryChoice: .openReleases)
    }
}
