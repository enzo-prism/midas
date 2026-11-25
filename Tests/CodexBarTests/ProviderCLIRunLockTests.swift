import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ProviderCLIRunLockTests {
    /// The command the midas-web collector uses to share the lock with Midas.
    private static let perlLock = #"""
    use Fcntl qw(:flock); $^F = 255; open(my $l, ">>", shift) or die "lock: $!"; \#
    flock($l, LOCK_EX) or die "lock: $!"; exec { $ARGV[0] } @ARGV or die "exec: $!";
    """#

    private static func makeLock() -> (ProviderCLIRunLock, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "midas-run-lock-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (ProviderCLIRunLock(name: "test-cli", directory: directory), directory)
    }

    @Test
    func `lives in the Midas caches folder`() {
        let url = ProviderCLIRunLock.elevenLabs.fileURL
        #expect(url.lastPathComponent == "elevenlabs-cli.lock")
        #expect(url.path.hasSuffix("/Library/Caches/Midas/locks/elevenlabs-cli.lock"))
        #expect(ProviderCLIRunLock.suno.fileURL.lastPathComponent == "suno-cli.lock")
    }

    @Test
    func `concurrent runs never overlap`() async throws {
        let (lock, directory) = Self.makeLock()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = OverlapCounter()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await lock.run {
                        await counter.enter()
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        await counter.leave()
                    }
                }
            }
            try await group.waitForAll()
        }

        #expect(await counter.maximum == 1)
        #expect(await counter.completed == 4)
    }

    @Test
    func `a cancelled caller still lets the run finish`() async throws {
        let (lock, directory) = Self.makeLock()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = OverlapCounter()

        let caller = Task {
            try await lock.run {
                await counter.enter()
                try? await Task.sleep(nanoseconds: 200_000_000)
                await counter.leave()
                return Task.isCancelled
            }
        }
        caller.cancel()
        let operationSawCancellation = try await caller.value

        #expect(operationSawCancellation == false)
        #expect(await counter.completed == 1)
    }

    @Test
    func `gives up when another holder keeps the lock`() async throws {
        let (lock, directory) = Self.makeLock()
        defer { try? FileManager.default.removeItem(at: directory) }
        let held = try await lock.acquire(waitTimeout: 1)
        defer { ProviderCLIRunLock.release(held) }

        await #expect(throws: ProviderCLIRunLockError.busy) {
            try await lock.run(waitTimeout: 0.3) { 1 }
        }
    }

    @Test
    func `waits for a CLI started under the collector's perl lock`() async throws {
        let (lock, directory) = Self.makeLock()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appending(path: "cli-finished")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-e", Self.perlLock, lock.fileURL.path,
            "/bin/sh", "-c", "sleep 1; touch \"$0\"", marker.path,
        ]
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        // Wait until perl holds the lock.
        let probe = open(lock.fileURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        defer { close(probe) }
        var heldByPerl = false
        for _ in 0..<100 {
            if flock(probe, LOCK_EX | LOCK_NB) == 0 {
                _ = flock(probe, LOCK_UN)
            } else {
                heldByPerl = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(heldByPerl)

        let markerPath = marker.path
        let cliHadFinished = try await lock.run(waitTimeout: 30) {
            FileManager.default.fileExists(atPath: markerPath)
        }
        #expect(cliHadFinished)
    }
}

private actor OverlapCounter {
    private var current = 0
    private(set) var maximum = 0
    private(set) var completed = 0

    func enter() {
        self.current += 1
        self.maximum = max(self.maximum, self.current)
    }

    func leave() {
        self.current -= 1
        self.completed += 1
    }
}
