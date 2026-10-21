import AppKit
import CodexBarCore
import Darwin
import Foundation
import Network

/// Internal cache IO never follows a link, even if an ancestor is changed during a write.
enum LocalPersistence {
    private static let maximumBytes = 128 * 1024 * 1024

    static func read(_ url: URL) throws -> Data {
        let parent = try self.directory(
            url.deletingLastPathComponent(),
            create: false)
        defer { Darwin.close(parent) }
        let descriptor = Darwin.openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw MidasUsageSyncError.folderUnavailable }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw MidasUsageSyncError.unsafeFile
        }
        guard info.st_size > 0, info.st_size <= self.maximumBytes else { throw MidasUsageSyncError.limitExceeded }
        let data = try handle.read(upToCount: self.maximumBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= self.maximumBytes else { throw MidasUsageSyncError.limitExceeded }
        return data
    }

    static func write(_ data: Data, to url: URL) throws {
        guard data.count <= self.maximumBytes else { throw MidasUsageSyncError.limitExceeded }
        let parent = try self.directory(
            url.deletingLastPathComponent(),
            create: true)
        defer { Darwin.close(parent) }
        var info = stat()
        if fstatat(parent, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw MidasUsageSyncError.unsafeFile }
        } else if errno != ENOENT {
            throw MidasUsageSyncError.folderUnavailable
        }
        let temporary = ".midas-cache-" + UUID().uuidString
        let descriptor = Darwin.openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw MidasUsageSyncError.folderUnavailable }
        defer { Darwin.unlinkat(parent, temporary, 0) }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        guard fsync(descriptor) == 0 else { throw MidasUsageSyncError.folderUnavailable }
        if fstatat(parent, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw MidasUsageSyncError.unsafeFile }
        } else if errno != ENOENT {
            throw MidasUsageSyncError.folderUnavailable
        }
        guard Darwin.renameat(parent, temporary, parent, url.lastPathComponent) == 0,
              fsync(parent) == 0 else { throw MidasUsageSyncError.folderUnavailable }
    }

    private static func directory(
        _ url: URL,
        create: Bool) throws -> Int32
    {
        guard url.isFileURL, !url.pathComponents.contains("."), !url.pathComponents.contains("..") else {
            throw MidasUsageSyncError.unsafeFile
        }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw MidasUsageSyncError.folderUnavailable }
        for component in url.pathComponents.dropFirst() {
            var child = Darwin.openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if child < 0, errno == ENOENT, create {
                if mkdirat(descriptor, component, 0o700) != 0, errno != EEXIST {
                    Darwin.close(descriptor)
                    throw MidasUsageSyncError.folderUnavailable
                }
                child = Darwin.openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            let failure = errno
            Darwin.close(descriptor)
            guard child >= 0 else {
                if failure == ELOOP || failure == ENOTDIR { throw MidasUsageSyncError.unsafeFile }
                throw MidasUsageSyncError.folderUnavailable
            }
            descriptor = child
        }
        return descriptor
    }
}

final class MidasSyncAccountObservation: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(onChange: @escaping @Sendable () -> Void) {
        self.token = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main) { _ in onChange() }
    }

    deinit { NotificationCenter.default.removeObserver(self.token) }
}

final class MidasSyncRecoveryObservation: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let wakeToken: NSObjectProtocol
    init(onRecovery: @escaping @Sendable () -> Void) {
        self.wakeToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main) { _ in onRecovery() }
        self.monitor.pathUpdateHandler = { path in if path.status == .satisfied { onRecovery() } }
        self.monitor.start(queue: DispatchQueue(label: "com.midas.sync-recovery"))
    }

    deinit {
        self.monitor.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self.wakeToken)
    }
}
