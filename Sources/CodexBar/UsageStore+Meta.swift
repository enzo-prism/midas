import CodexBarCore
import Foundation

extension UsageStore {
    /// Cursor cookie settings for the spend path, mirroring the quota path's web session
    /// (browser import or manual header). Nil for other providers.
    func cursorCostSettings(for provider: UsageProvider) -> ProviderSettingsSnapshot.CursorProviderSettings? {
        guard provider == .cursor else { return nil }
        return self.settings.cursorSettingsSnapshot(tokenOverride: nil)
    }

    nonisolated static func debugMetaLog() -> String {
        let resolution = ProviderTokenResolver.metaResolution()
        let hasAny = resolution != nil
        let source = resolution?.source.rawValue ?? "none"
        let root = MuseSessionLogScanner.defaultSessionsRoot()
        let rootExists = FileManager.default.fileExists(atPath: root.path)
        let fileCount = MuseSessionLogScanner.listSessionFiles(root: root, since: .distantPast).count
        let model = MuseSessionLogScanner.configuredModel() ?? "none"
        return "META_API_KEY=\(hasAny ? "present" : "missing") source=\(source) " +
            "sessionsRoot=\(root.path) exists=\(rootExists) files=\(fileCount) model=\(model)"
    }
}
