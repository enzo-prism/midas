import CodexBarCore
import Foundation

protocol ZaiSnapshotStoring: Sendable {
    func load() -> UsageSnapshot?
    func store(_ snapshot: UsageSnapshot?)
}

/// On-disk hydration cache for the z.ai quota snapshot.
///
/// `UsageSnapshot.zaiUsage` was previously excluded from Codable (`fetched fresh each time`),
/// which meant cold launches showed an empty card until the first background refresh completed.
/// This store persists the last successful quota snapshot to a small JSON file (mode 0600) so the
/// card renders instantly on launch. The hourly `modelUsage` payload is intentionally dropped at
/// encode time (`ZaiUsageSnapshot.encode`) to keep the cache small; the chart rehydrates that
/// detail on the next live refresh.
struct FileZaiSnapshotStore: ZaiSnapshotStoring, @unchecked Sendable {
    private static let currentVersion = 1

    private struct Payload: Codable {
        let version: Int
        let snapshot: UsageSnapshot
    }

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL = Self.defaultURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load() -> UsageSnapshot? {
        guard self.fileManager.fileExists(atPath: self.fileURL.path),
              let data = try? Data(contentsOf: self.fileURL)
        else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data),
              payload.version == Self.currentVersion
        else {
            return nil
        }
        return payload.snapshot
    }

    func store(_ snapshot: UsageSnapshot?) {
        guard let snapshot else {
            try? self.fileManager.removeItem(at: self.fileURL)
            return
        }
        let payload = Payload(version: Self.currentVersion, snapshot: snapshot)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }

        let directory = self.fileURL.deletingLastPathComponent()
        do {
            if !self.fileManager.fileExists(atPath: directory.path) {
                try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try data.write(to: self.fileURL, options: [.atomic])
            #if os(macOS)
            try? self.fileManager.setAttributes([
                .posixPermissions: NSNumber(value: Int16(0o600)),
            ], ofItemAtPath: self.fileURL.path)
            #endif
        } catch {
            // Snapshot hydration is best-effort; never make menu refresh fail because disk cache failed.
        }
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("zai-snapshot.json", isDirectory: false)
    }
}
