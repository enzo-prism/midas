import CodexBarCore
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Internal, owner-only numeric state. Provider secrets never enter this store.
struct MidasUsageCollectorStorage {
    let root: URL

    init(root: URL) throws {
        self.root = root.standardizedFileURL
        let externalPrefixes = ["/Volumes/", "/media/", "/mnt/", "/run/media/"]
        guard root.isFileURL,
              !externalPrefixes.contains(where: { self.root.path.hasPrefix($0) }),
              self.root.resolvingSymlinksInPath().path == self.root.path
        else { throw MidasUsageSyncError.unsafeFile }
        try FileManager.default.createDirectory(
            at: self.root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: self.root.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0
        else { throw MidasUsageSyncError.unsafeFile }
    }

    func load<T: Decodable>(
        _ name: String, maximumBytes: Int = MidasUsageSyncPublication.maximumFileBytes) throws -> T?
    {
        let url = self.root.appendingPathComponent(name)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw MidasUsageSyncError.unsafeFile
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
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
        if T.self == MidasUsageSyncPublication.self {
            return try MidasUsageSyncCodec.decodePublication(data) as? T
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// POSIX advisory locking releases automatically on process exit, including crashes.
    func lock() throws -> FileHandle {
        let path = self.root.appendingPathComponent("collector.lock").path
        let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        guard descriptor >= 0 else { throw MidasUsageSyncError.unsafeFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              fcntl(descriptor, F_SETLK, &lock) == 0
        else {
            try? handle.close()
            throw MidasUsageSyncError.unsafeFile
        }
        return handle
    }

    func save(
        _ value: some Encodable,
        name: String,
        maximumBytes: Int = MidasUsageSyncPublication.maximumFileBytes) throws
    {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumBytes else { throw MidasUsageSyncError.limitExceeded }
        let destination = self.root.appendingPathComponent(name)
        let temporary = self.root.appendingPathComponent(".\(UUID().uuidString).pending")
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
        let directory = open(self.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw MidasUsageSyncError.unsafeFile }
        defer { _ = close(directory) }
        guard fsync(directory) == 0 else { throw MidasUsageSyncError.unsafeFile }
    }
}
