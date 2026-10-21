#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Owner-only, immutable numeric pages with atomic publication manifests. No provider credentials enter this store.
/// Canonical local history and rebuildable peer caches use different roots; callers pin a manifest in their metadata.
public struct MidasUsageCanonicalStore: Sendable {
    private struct Page: Codable {
        let events: [MidasUsageSyncEvent]
        let accountDays: [MidasUsageSyncAccountDay]
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let workspaceID: UUID
        let deviceID: UUID
        let deviceName: String
        let publishedAt: Date
        let excludedRecords: Int
        let eventCount: Int
        let accountDayCount: Int
        let pages: [String]
    }

    private struct Head: Codable {
        let revision: String
        let previous: String?
    }

    // POSIX locks are process-scoped; also serialize concurrent tasks inside this process.
    private static let ioLock = NSRecursiveLock()
    private static let maximumPageBytes = 1024 * 1024
    private static let maximumManifestBytes = 1024 * 1024
    private static let pageRows = 512
    public let root: URL

    public init(root: URL) throws {
        let root = root.standardizedFileURL
        let external = ["/Volumes/", "/media/", "/mnt/", "/run/media/"]
        guard root.isFileURL, !external.contains(where: { root.path.hasPrefix($0) }),
              root.resolvingSymlinksInPath().path == root.path else { throw MidasUsageSyncError.unsafeFile }
        self.root = root
        for directory in [
            root,
            root.appendingPathComponent("pages"),
            root.appendingPathComponent("manifests"),
            root.appendingPathComponent("heads"),
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try Self.checkDirectory(directory)
        }
    }

    public func load(
        workspaceID: UUID,
        deviceID: UUID,
        revision: String? = nil,
        now: Date = Date()) throws -> MidasUsageSyncPublication?
    {
        try self.locked {
            try self.loadUnlocked(workspaceID: workspaceID, deviceID: deviceID, revision: revision, now: now)
        }
    }

    /// Returns a content-addressed immutable manifest token, which may be pinned by a separate atomic app checkpoint.
    @discardableResult
    public func save(_ publication: MidasUsageSyncPublication, now: Date = Date()) throws -> String {
        try self.locked { try self.saveUnlocked(publication, now: now) }
    }

    /// Merges the last durable source, a migrated publication, and a partial scan before changing the head.
    public func retain(
        previous: MidasUsageSyncPublication?,
        fresh: MidasUsageSyncPublication,
        now: Date = Date()) throws -> MidasUsageSyncPublication
    {
        try self.locked {
            let durable = try self.loadUnlocked(
                workspaceID: fresh.workspaceID,
                deviceID: fresh.deviceID,
                revision: nil,
                now: now)
            let imported: MidasUsageSyncPublication? = if let previous {
                try MidasUsageSyncLedger.retainingCanonicalHistory(previous: durable, fresh: previous)
            } else {
                durable
            }
            let retained = try MidasUsageSyncLedger.retainingCanonicalHistory(previous: imported, fresh: fresh)
            try self.saveUnlocked(retained, now: now)
            return retained
        }
    }

    /// Only call after the owner's checkpoint commits. Current and previous heads are always retained.
    /// This removes obsolete encodings, never a measurement absent from the winning canonical head.
    public func prune(retainingRevisions revisions: [String]) throws {
        try self.locked {
            var manifests = Set(revisions)
            for file in try FileManager.default.contentsOfDirectory(
                at: self.root.appendingPathComponent("heads"),
                includingPropertiesForKeys: nil)
            {
                guard file.pathExtension == "json" else { continue }
                let data = try Self.read(file, limit: 4096)
                let head = try JSONDecoder().decode(Head.self, from: data)
                manifests.insert(head.revision)
                if let previous = head.previous { manifests.insert(previous) }
            }
            var pages: Set<String> = []
            for revision in manifests {
                try Self.checkDigest(revision)
                let data = try Self.read(self.manifestURL(revision), limit: Self.maximumManifestBytes)
                guard Self.digest(data) == revision else { throw MidasUsageSyncError.invalidRecord }
                let manifest = try JSONDecoder().decode(Manifest.self, from: data)
                pages.formUnion(manifest.pages)
            }
            for (directory, retained) in [("manifests", manifests), ("pages", pages)] {
                for file in try FileManager.default.contentsOfDirectory(
                    at: self.root.appendingPathComponent(directory),
                    includingPropertiesForKeys: nil)
                {
                    guard file.pathExtension == "json" else { continue }
                    let digest = file.deletingPathExtension().lastPathComponent
                    try Self.checkDigest(digest)
                    if retained.contains(digest) { continue }
                    _ = try Self.read(file, limit: Self.maximumPageBytes)
                    guard unlink(file.path) == 0 else { throw MidasUsageSyncError.unsafeFile }
                }
            }
        }
    }

    private func loadUnlocked(
        workspaceID: UUID,
        deviceID: UUID,
        revision requestedRevision: String?,
        now: Date) throws -> MidasUsageSyncPublication?
    {
        let revision: String
        if let requested = requestedRevision {
            revision = requested
        } else {
            guard let data = try Self.readOptional(self.headURL(workspaceID, deviceID), limit: 4096) else { return nil }
            revision = try JSONDecoder().decode(Head.self, from: data).revision
        }
        try Self.checkDigest(revision)
        let data = try Self.read(self.manifestURL(revision), limit: Self.maximumManifestBytes)
        guard Self.digest(data) == revision else { throw MidasUsageSyncError.invalidRecord }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.schemaVersion == 1, manifest.workspaceID == workspaceID, manifest.deviceID == deviceID,
              manifest.eventCount >= 0, manifest.accountDayCount >= 0,
              manifest.eventCount <= MidasUsageSyncPublication.maximumCanonicalRecords,
              manifest.accountDayCount <= MidasUsageSyncPublication.maximumCanonicalRecords - manifest.eventCount,
              manifest.pages.count <= 8192 else { throw MidasUsageSyncError.invalidRecord }
        var events: [MidasUsageSyncEvent] = []
        var accounts: [MidasUsageSyncAccountDay] = []
        events.reserveCapacity(manifest.eventCount)
        accounts.reserveCapacity(manifest.accountDayCount)
        for digest in manifest.pages {
            try Task.checkCancellation()
            try Self.checkDigest(digest)
            let data = try Self.read(self.pageURL(digest), limit: Self.maximumPageBytes)
            guard Self.digest(data) == digest else { throw MidasUsageSyncError.invalidRecord }
            let page = try JSONDecoder().decode(Page.self, from: data)
            guard events.count + page.events.count <= manifest.eventCount,
                  accounts.count + page.accountDays.count <= manifest.accountDayCount
            else {
                throw MidasUsageSyncError.invalidRecord
            }
            events += page.events
            accounts += page.accountDays
        }
        guard events.count == manifest.eventCount, accounts.count == manifest.accountDayCount else {
            throw MidasUsageSyncError.invalidRecord
        }
        let publication = MidasUsageSyncPublication(
            workspaceID: workspaceID,
            deviceID: deviceID,
            deviceName: manifest.deviceName,
            publishedAt: manifest.publishedAt,
            events: events,
            accountDays: accounts,
            excludedRecords: manifest.excludedRecords)
        try publication.validateCanonical(workspaceID: workspaceID, now: now)
        return publication
    }

    private func saveUnlocked(_ publication: MidasUsageSyncPublication, now: Date) throws -> String {
        try publication.validateCanonical(workspaceID: publication.workspaceID, now: now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Identity buckets keep changes in a busy day from shifting every later page.
        var eventBuckets: [String: [MidasUsageSyncEvent]] = [:]
        var accountBuckets: [String: [MidasUsageSyncAccountDay]] = [:]
        for event in publication.events {
            eventBuckets[String(event.id.prefix(2)), default: []].append(event)
        }
        for row in publication
            .accountDays
        {
            accountBuckets[String(row.accountScope.prefix(2)), default: []].append(row)
        }
        var pages: [String] = []
        for key in Set(eventBuckets.keys).union(accountBuckets.keys).sorted() {
            let events = (eventBuckets[key] ?? []).sorted {
                $0.provider == $1.provider ? $0.id < $1.id : $0.provider.rawValue < $1.provider.rawValue
            }
            let accounts = (accountBuckets[key] ?? []).sorted {
                if $0.provider != $1.provider { return $0.provider.rawValue < $1.provider.rawValue }
                return $0.accountScope == $1.accountScope ? $0.day < $1.day : $0.accountScope < $1.accountScope
            }
            for start in stride(from: 0, to: max(events.count, accounts.count), by: Self.pageRows) {
                try Task.checkCancellation()
                let page = Page(
                    events: start < events.count ? Array(events[start..<min(start + Self.pageRows, events.count)]) : [],
                    accountDays: start < accounts.count ? Array(accounts[start..<min(
                        start + Self.pageRows,
                        accounts.count)]) : [])
                let data = try encoder.encode(page)
                guard data.count <= Self.maximumPageBytes else { throw MidasUsageSyncError.limitExceeded }
                let digest = Self.digest(data)
                try Self.writeImmutable(data, to: self.pageURL(digest), limit: Self.maximumPageBytes)
                pages.append(digest)
            }
        }
        let manifest = Manifest(
            schemaVersion: 1,
            workspaceID: publication.workspaceID,
            deviceID: publication.deviceID,
            deviceName: publication.deviceName,
            publishedAt: publication.publishedAt,
            excludedRecords: publication.excludedRecords,
            eventCount: publication.events.count,
            accountDayCount: publication.accountDays.count,
            pages: pages)
        let data = try encoder.encode(manifest)
        guard data.count <= Self.maximumManifestBytes else { throw MidasUsageSyncError.limitExceeded }
        let revision = Self.digest(data)
        try Self.writeImmutable(data, to: self.manifestURL(revision), limit: Self.maximumManifestBytes)
        let headURL = self.headURL(publication.workspaceID, publication.deviceID)
        let old = try Self.readOptional(headURL, limit: 4096).map { try JSONDecoder().decode(Head.self, from: $0) }
        let previous = old?.revision == revision ? old?.previous : old?.revision
        try Self.writeAtomic(encoder.encode(Head(revision: revision, previous: previous)), to: headURL)
        return revision
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        Self.ioLock.lock()
        defer { Self.ioLock.unlock() }
        for directory in [
            self.root,
            self.root.appendingPathComponent("pages"),
            self.root.appendingPathComponent("manifests"),
            self.root.appendingPathComponent("heads"),
        ] {
            try Self.checkDirectory(directory)
        }
        let descriptor = open(
            self.root.appendingPathComponent("store.lock").path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK,
            mode_t(0o600))
        guard descriptor >= 0 else { throw MidasUsageSyncError.unsafeFile }
        defer { _ = close(descriptor) }
        var info = stat()
        var recordLock = flock()
        recordLock.l_type = Int16(F_WRLCK)
        recordLock.l_whence = Int16(SEEK_SET)
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              fcntl(descriptor, F_SETLK, &recordLock) == 0 else { throw MidasUsageSyncError.unsafeFile }
        return try body()
    }

    private func pageURL(_ digest: String) -> URL {
        self.root.appendingPathComponent("pages/\(digest).json")
    }

    private func manifestURL(_ digest: String) -> URL {
        self.root.appendingPathComponent("manifests/\(digest).json")
    }

    private func headURL(_ workspace: UUID, _ device: UUID) -> URL {
        self.root.appendingPathComponent("heads/\(workspace.uuidString)-\(device.uuidString).json")
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func checkDigest(_ value: String) throws {
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else {
            throw MidasUsageSyncError.invalidRecord
        }
    }

    private static func checkDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw MidasUsageSyncError.unsafeFile }
    }

    private static func readOptional(_ url: URL, limit: Int) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw MidasUsageSyncError.unsafeFile
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_size >= 0, info.st_size <= limit
        else {
            throw MidasUsageSyncError.unsafeFile
        }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count == Int(info.st_size), data.count <= limit else { throw MidasUsageSyncError.unsafeFile }
        return data
    }

    private static func read(_ url: URL, limit: Int) throws -> Data {
        guard let data = try self.readOptional(url, limit: limit) else { throw MidasUsageSyncError.invalidRecord }
        return data
    }

    private static func writeImmutable(_ data: Data, to url: URL, limit: Int) throws {
        if let existing = try self.readOptional(url, limit: limit) {
            guard existing == data else { throw MidasUsageSyncError.invalidRecord }
            return
        }
        try self.writeAtomic(data, to: url)
    }

    private static func writeAtomic(_ data: Data, to destination: URL) throws {
        try self.checkDirectory(destination.deletingLastPathComponent())
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pending")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw MidasUsageSyncError.unsafeFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            _ = unlink(temporary.path)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, destination.path) == 0 else { throw MidasUsageSyncError.unsafeFile }
        let directory = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw MidasUsageSyncError.unsafeFile }
        defer { _ = close(directory) }
        guard fsync(directory) == 0 else { throw MidasUsageSyncError.unsafeFile }
    }
}
