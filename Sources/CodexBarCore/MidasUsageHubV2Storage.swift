import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Rebuildable transport pages. Critical collection/outbox state is deliberately stored elsewhere.
struct MidasUsageHubV2Storage {
    struct Index: Codable {
        let schemaVersion: Int
        let workspace: MidasUsageSyncWorkspace
        let deviceID: UUID
        var heads: [MidasUsageHubV2Head]
        var pendingUpload: MidasUsageHubV2Upload?
        var pendingFingerprint: String?
        var acceptedFingerprint: String?
        var acceptedRevision: Int?

        init(workspace: MidasUsageSyncWorkspace, deviceID: UUID) {
            self.schemaVersion = 1
            self.workspace = workspace
            self.deviceID = deviceID
            self.heads = []
        }
    }

    let root: URL

    static func defaultRoot() -> URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(MidasIdentity.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("usage-sync/transport-v2", isDirectory: true)
        #else
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share", isDirectory: true)
            .appendingPathComponent(MidasIdentity.supportDirectoryName.lowercased(), isDirectory: true)
            .appendingPathComponent("usage-sync/transport-v2", isDirectory: true)
        #endif
    }

    init(root: URL, workspaceID: UUID, deviceID: UUID) throws {
        let prefixes = ["/Volumes", "/media", "/mnt", "/run/media"]
        let base = root.standardizedFileURL
        guard base.isFileURL, !prefixes.contains(where: { base.path == $0 || base.path.hasPrefix($0 + "/") }) else {
            throw MidasUsageSyncError.unsafeFile
        }
        self.root = base.appendingPathComponent(workspaceID.uuidString, isDirectory: true)
            .appendingPathComponent(deviceID.uuidString, isDirectory: true)
        let descriptor = try Self.directory(self.root, create: true)
        _ = close(descriptor)
        let pages = try Self.directory(self.root.appendingPathComponent("pages", isDirectory: true), create: true)
        _ = close(pages)
    }

    func loadIndex(workspace: MidasUsageSyncWorkspace, deviceID: UUID) throws -> Index {
        guard let data = try self.read("index.json", maximumBytes: 16 * 1024 * 1024) else {
            return Index(workspace: workspace, deviceID: deviceID)
        }
        do {
            let index = try JSONDecoder().decode(Index.self, from: data)
            guard index.schemaVersion == 1, index.workspace == workspace, index.deviceID == deviceID else {
                throw MidasUsageSyncError.wrongWorkspace
            }
            return index
        } catch MidasUsageSyncError.wrongWorkspace {
            throw MidasUsageSyncError.wrongWorkspace
        } catch {
            // Preserve the damaged bytes; only rebuildable page/index state is discarded.
            try self.quarantine("index.json")
            return Index(workspace: workspace, deviceID: deviceID)
        }
    }

    func saveIndex(_ index: Index) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(index)
        guard data.count <= 16 * 1024 * 1024 else { throw MidasUsageSyncError.limitExceeded }
        try self.write(data, name: "index.json")
    }

    func page(_ digest: String, maximumBytes: Int) throws -> Data? {
        guard Self.validDigest(digest) else { throw MidasUsageHubError.invalidResponse }
        return try self.read("pages/" + digest + ".json", maximumBytes: maximumBytes)
    }

    func pageIdentity(_ digest: String, byteCount: Int) throws -> String? {
        guard Self.validDigest(digest) else { throw MidasUsageHubError.invalidResponse }
        let parent = try Self.directory(self.root.appendingPathComponent("pages"), create: false)
        defer { _ = close(parent) }
        var info = stat()
        if fstatat(parent, digest + ".json", &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw MidasUsageSyncError.unsafeFile
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw MidasUsageSyncError.unsafeFile
        }
        guard info.st_size == byteCount else { return nil }
        #if canImport(Darwin)
        let modified = info.st_mtimespec
        let changed = info.st_ctimespec
        #else
        let modified = info.st_mtim
        let changed = info.st_ctim
        #endif
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):"
            + "\(modified.tv_sec):\(modified.tv_nsec):\(changed.tv_sec):\(changed.tv_nsec)"
    }

    func savePage(_ data: Data, digest: String) throws {
        guard Self.validDigest(digest) else { throw MidasUsageHubError.invalidResponse }
        try self.write(data, name: "pages/" + digest + ".json")
    }

    func quarantinePage(_ digest: String) throws {
        guard Self.validDigest(digest) else { throw MidasUsageHubError.invalidResponse }
        try self.quarantine("pages/" + digest + ".json")
    }

    func lock() throws -> FileHandle {
        let parent = try Self.directory(self.root, create: false)
        defer { _ = close(parent) }
        let descriptor = openat(parent, "transport.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw MidasUsageSyncError.unsafeFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              fcntl(descriptor, F_SETLK, &lock) == 0
        else {
            try? handle.close()
            throw MidasUsageSyncError.unsafeFile
        }
        return handle
    }

    /// Only unreferenced, rebuildable blobs are removed, after the selected checkpoint is applied.
    func prunePages(keeping digests: Set<String>) throws {
        let pages = self.root.appendingPathComponent("pages", isDirectory: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: pages.path) {
            guard name.hasSuffix(".json") else { continue }
            let digest = String(name.dropLast(5))
            guard Self.validDigest(digest), !digests.contains(digest) else { continue }
            let parent = try Self.directory(pages, create: false)
            defer { _ = close(parent) }
            let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw MidasUsageSyncError.unsafeFile }
            var info = stat()
            let safe = fstat(descriptor, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
                && info.st_uid == geteuid() && info.st_mode & 0o077 == 0
            _ = close(descriptor)
            guard safe, unlinkat(parent, name, 0) == 0 else { throw MidasUsageSyncError.unsafeFile }
        }
    }

    static func validDigest(_ digest: String) -> Bool {
        digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func read(_ name: String, maximumBytes: Int) throws -> Data? {
        let url = self.root.appendingPathComponent(name)
        let parent = try Self.directory(url.deletingLastPathComponent(), create: false)
        defer { _ = close(parent) }
        let descriptor = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw MidasUsageSyncError.unsafeFile
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_size >= 0, info.st_size <= maximumBytes
        else { throw MidasUsageSyncError.unsafeFile }
        var data = Data()
        while data.count <= maximumBytes {
            let chunk = try handle.read(upToCount: min(64 * 1024, maximumBytes + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else { throw MidasUsageSyncError.limitExceeded }
        return data
    }

    private func write(_ data: Data, name: String) throws {
        let url = self.root.appendingPathComponent(name)
        let parent = try Self.directory(url.deletingLastPathComponent(), create: false)
        defer { _ = close(parent) }
        var existing = stat()
        if fstatat(parent, url.lastPathComponent, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_uid == geteuid(),
                  existing.st_mode & 0o077 == 0
            else {
                throw MidasUsageSyncError.unsafeFile
            }
        } else if errno != ENOENT {
            throw MidasUsageSyncError.unsafeFile
        }
        let temporary = "." + UUID().uuidString + ".pending"
        let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw MidasUsageSyncError.unsafeFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            _ = unlinkat(parent, temporary, 0)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard renameat(parent, temporary, parent, url.lastPathComponent) == 0, fsync(parent) == 0 else {
            throw MidasUsageSyncError.unsafeFile
        }
    }

    private func quarantine(_ name: String) throws {
        let url = self.root.appendingPathComponent(name)
        let parent = try Self.directory(url.deletingLastPathComponent(), create: false)
        defer { _ = close(parent) }
        let target = ".quarantine-" + UUID().uuidString + "-" + url.lastPathComponent
        guard renameat(parent, url.lastPathComponent, parent, target) == 0, fsync(parent) == 0 else {
            throw MidasUsageSyncError.unsafeFile
        }
        // Diagnostic copies are rebuildable too; repeated corrupt transfers cannot fill the disk.
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".quarantine-") && $0 != target }.sorted()
        for old in names.dropLast(7) {
            var info = stat()
            guard fstatat(parent, old, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
                  unlinkat(parent, old, 0) == 0 else { throw MidasUsageSyncError.unsafeFile }
        }
    }

    /// Walk without following symlinks, including while creating private intermediate directories.
    private static func directory(_ url: URL, create: Bool) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw MidasUsageSyncError.unsafeFile }
        var path = url.path
        #if os(macOS)
        // Foundation standardizes /private/var back to /var even after resolving symlinks.
        // Expand only these immutable platform aliases before the no-follow walk.
        for alias in ["var", "tmp"] where path == "/" + alias || path.hasPrefix("/" + alias + "/") {
            guard try FileManager.default.destinationOfSymbolicLink(atPath: "/" + alias) == "private/" + alias else {
                throw MidasUsageSyncError.unsafeFile
            }
            path = "/private" + path
        }
        #endif
        let components = path.split(separator: "/").map(String.init)
        guard !components.contains("."), !components.contains("..") else { throw MidasUsageSyncError.unsafeFile }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw MidasUsageSyncError.unsafeFile }
        for component in components {
            var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT, create {
                guard mkdirat(descriptor, component, 0o700) == 0 || errno == EEXIST else {
                    _ = close(descriptor)
                    throw MidasUsageSyncError.unsafeFile
                }
                next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            _ = close(descriptor)
            guard next >= 0 else { throw MidasUsageSyncError.unsafeFile }
            descriptor = next
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            _ = close(descriptor)
            throw MidasUsageSyncError.unsafeFile
        }
        return descriptor
    }
}
