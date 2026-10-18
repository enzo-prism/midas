import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Connection files contain a revocable usage-sync secret and must remain on private internal storage.
public enum MidasUsageHubConnectionFile {
    public static func load(at url: URL) throws -> MidasUsageHubConnection {
        guard url.isFileURL else { throw MidasUsageHubError.unsafeConnectionFile }
        let parent = try self.openParent(of: url)
        defer { _ = close(parent) }
        let descriptor = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw MidasUsageHubError.unsafeConnectionFile }
        defer { _ = close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(),
              metadata.st_mode & 0o777 == 0o600,
              metadata.st_size > 0, metadata.st_size <= 8192
        else { throw MidasUsageHubError.unsafeConnectionFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: 8193) ?? Data()
        guard data.count <= 8192 else { throw MidasUsageHubError.unsafeConnectionFile }
        let connection: MidasUsageHubConnection
        do {
            connection = try JSONDecoder().decode(MidasUsageHubConnection.self, from: data)
        } catch {
            throw MidasUsageHubError.invalidConnection
        }
        try connection.validate()
        return connection
    }

    /// Does not overwrite an enrollment. The parent must already be a private directory owned by this user.
    public static func save(_ connection: MidasUsageHubConnection, to url: URL) throws {
        try connection.validate()
        let externalRoots = ["/Volumes", "/media", "/mnt", "/run/media"]
        guard url.isFileURL,
              !externalRoots.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") })
        else { throw MidasUsageHubError.unsafeConnectionFile }
        let parent = try self.openParent(of: url)
        defer { _ = close(parent) }
        var metadata = stat()
        guard fstat(parent, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0
        else { throw MidasUsageHubError.unsafeConnectionFile }
        let temporary = ".hub-connection-" + UUID().uuidString
        let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw MidasUsageHubError.unsafeConnectionFile }
        defer {
            _ = close(descriptor)
            _ = unlinkat(parent, temporary, 0)
        }
        let data = try JSONEncoder().encode(connection)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                #if canImport(Darwin)
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                #else
                let written = Glibc.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                #endif
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw MidasUsageHubError.unsafeConnectionFile }
                offset += written
            }
        }
        guard fsync(descriptor) == 0, linkat(parent, temporary, parent, url.lastPathComponent, 0) == 0 else {
            throw MidasUsageHubError.unsafeConnectionFile
        }
        guard fsync(parent) == 0 else { throw MidasUsageHubError.unsafeConnectionFile }
        guard try self.load(at: url) == connection else { throw MidasUsageHubError.unsafeConnectionFile }
    }

    private static func openParent(of url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.lastPathComponent.isEmpty else {
            throw MidasUsageHubError.unsafeConnectionFile
        }
        let components = url.deletingLastPathComponent().path.split(separator: "/").map(String.init)
        guard !components.contains("."), !components.contains("..") else {
            throw MidasUsageHubError.unsafeConnectionFile
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw MidasUsageHubError.unsafeConnectionFile }
        for component in components {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            _ = close(descriptor)
            guard next >= 0 else { throw MidasUsageHubError.unsafeConnectionFile }
            descriptor = next
        }
        return descriptor
    }
}
