import Foundation

/// Lets one process at a time run a provider CLI that refreshes its own OAuth session.
///
/// The ElevenLabs CLI keeps a rotating refresh token in its Keychain entry and deletes that entry
/// when a refresh is rejected. Two copies of the CLI refreshing at the same moment (the app, the
/// bundled CLI run by a collector, or a collector calling the provider CLI itself) spend the same
/// refresh token twice: the second refresh fails and the user is signed out. A CLI stopped between
/// the refresh and the Keychain write loses the new token the same way.
///
/// Each run therefore takes an exclusive `flock(2)` on a shared file in
/// `~/Library/Caches/Midas/locks/` and runs in its own task, so cancelling the caller never stops
/// the CLI partway through. Other tools can serialize with Midas by taking the same lock, for
/// example `perl -e 'use Fcntl ":flock"; $^F = 255; open my $l, ">>", shift; flock $l, LOCK_EX;
/// exec @ARGV' <lock file> <cli> <args>`.
public struct ProviderCLIRunLock: Sendable {
    public static let elevenLabs = ProviderCLIRunLock(name: "elevenlabs-cli")
    public static let suno = ProviderCLIRunLock(name: "suno-cli")

    /// How long a run waits for another holder before giving up.
    public static let defaultWaitTimeout: TimeInterval = 90

    public let fileURL: URL

    public init(name: String, directory: URL = ProviderCLIRunLock.defaultDirectory) {
        self.fileURL = directory.appendingPathComponent("\(name).lock", isDirectory: false)
    }

    public static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Caches", isDirectory: true)
        return caches
            .appendingPathComponent(MidasIdentity.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("locks", isDirectory: true)
    }

    /// Runs `operation` while holding the lock.
    ///
    /// The operation runs in a detached task: a cancelled caller still waits for it to finish, and
    /// the CLI it starts is never killed because a newer refresh replaced this one.
    public func run<T: Sendable>(
        waitTimeout: TimeInterval = ProviderCLIRunLock.defaultWaitTimeout,
        _ operation: @escaping @Sendable () async throws -> T) async throws -> T
    {
        let lock = self
        return try await Task.detached {
            let descriptor = try await lock.acquire(waitTimeout: waitTimeout)
            defer { Self.release(descriptor) }
            return try await operation()
        }.value
    }

    func acquire(waitTimeout: TimeInterval) async throws -> Int32 {
        let directory = self.fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ProviderCLIRunLockError.unavailable(error.localizedDescription)
        }
        let descriptor = open(self.fileURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw ProviderCLIRunLockError.unavailable(String(cString: strerror(errno)))
        }

        let deadline = Date().addingTimeInterval(waitTimeout)
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return descriptor
            }
            let failure = errno
            guard failure == EWOULDBLOCK || failure == EINTR else {
                close(descriptor)
                throw ProviderCLIRunLockError.unavailable(String(cString: strerror(failure)))
            }
            guard Date() < deadline else {
                close(descriptor)
                throw ProviderCLIRunLockError.busy
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    static func release(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

public enum ProviderCLIRunLockError: LocalizedError, Equatable, Sendable {
    /// Another process kept the lock for the whole wait.
    case busy
    /// The lock file could not be created or locked.
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .busy:
            "Another usage check is still running this CLI. Midas will try again on the next refresh."
        case let .unavailable(reason):
            "Could not take the CLI run lock: \(reason)"
        }
    }
}
