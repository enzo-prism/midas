import CodexBarCore
import Darwin
import Foundation
import Testing
@testable import CodexBar

struct MidasUsageSyncFolderTests {
    private let now = Date(timeIntervalSince1970: 1_789_171_200)
    private let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test func twoDevicesConvergeAndReplaceOnlyTheirOwnFiles() async throws {
        let folder = try self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = try await MidasUsageSyncFolder.workspace(at: folder)
        let first = self.publication(workspace: workspace, device: self.first, tokens: 100)
        let second = self.publication(workspace: workspace, device: self.second, tokens: 200)
        let initial = try await self.exchange(folder, workspace, first)
        #expect(initial.publicationSucceeded)
        #expect(initial.publications == [first])
        _ = try await self.exchange(folder, workspace, second)
        let received = try await self.exchange(folder, workspace, nil)
        #expect(!received.publicationSucceeded)
        #expect(received.publications == [first, second])
        let secondData = try Data(contentsOf: self.file(folder, self.second))
        let updated = self.publication(workspace: workspace, device: self.first, tokens: 300)
        let final = try await self.exchange(folder, workspace, updated)
        #expect(final.publications == [updated, second])
        #expect(try Data(contentsOf: self.file(folder, self.second)) == secondData)
        #expect(final.unavailableFiles == 0)
        #expect(final.rejectedFiles == 0)
    }

    @Test func stalledExchangeAdvancesValidationTimeAfterCoordinationAndBetweenPeerReads() async throws {
        let folder = try self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = try await MidasUsageSyncFolder.workspace(at: folder)
        _ = try await self.exchange(folder, workspace, nil)
        let third = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let peer = self.publication(workspace: workspace, device: self.second, date: self.now.addingTimeInterval(601))
        let latest = self.publication(workspace: workspace, device: third, date: self.now.addingTimeInterval(1201))
        try JSONEncoder().encode(peer).write(to: self.file(folder, self.second))
        try JSONEncoder().encode(latest).write(to: self.file(folder, third))
        let local = self.publication(workspace: workspace, device: self.first)
        let elapsed = ElapsedClock([601, 602, 603, 1202])
        let result = try await MidasUsageSyncFolder.exchange(
            at: folder,
            workspace: workspace,
            local: local,
            now: self.now,
            elapsedTime: { elapsed.read() })
        #expect(result.publicationSucceeded)
        #expect(result.publications == [local, peer, latest])
        #expect(result.rejectedFiles == 0)
        #expect(result.unavailableFiles == 0)
    }

    @Test func concurrentWorkspaceInitializersPreserveTheWinner() async throws {
        let folder = try self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspaces = try await withThrowingTaskGroup(of: MidasUsageSyncWorkspace.self) { group in
            for _ in 0..<12 {
                group.addTask { try await MidasUsageSyncFolder.workspace(at: folder) }
            }
            var results: [MidasUsageSyncWorkspace] = []
            for try await workspace in group {
                results.append(workspace)
            }
            return results
        }
        let first = try #require(workspaces.first)
        #expect(workspaces.count == 12)
        #expect(workspaces.allSatisfy { $0 == first })
        #expect(try await MidasUsageSyncFolder.workspace(at: folder) == first)
    }

    @Test func corruptPeerIsRejectedAndOtherDeviceRemainsAvailable() async throws {
        let folder = try self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = try await MidasUsageSyncFolder.workspace(at: folder)
        let first = self.publication(workspace: workspace, device: self.first)
        _ = try await self.exchange(folder, workspace, first)
        try Data("invalid JSON".utf8).write(to: self.file(folder, self.second))
        let result = try await self.exchange(folder, workspace, nil)
        #expect(result.publications == [first])
        #expect(result.rejectedFiles == 1)
        #expect(result.unavailableFiles == 0)
    }

    @Test func oversizedSparsePeerFileIsRejectedWithoutReadingItsContents() async throws {
        let folder = try self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = try await MidasUsageSyncFolder.workspace(at: folder)
        _ = try await self.exchange(folder, workspace, self.publication(workspace: workspace, device: self.first))
        let peer = self.file(folder, self.second)
        #expect(FileManager.default.createFile(atPath: peer.path, contents: nil))
        let handle = try FileHandle(forWritingTo: peer)
        try handle.truncate(atOffset: UInt64(MidasUsageSyncPublication.maximumFileBytes + 1))
        try handle.close()
        let result = try await self.exchange(folder, workspace, nil)
        #expect(result.publications.count == 1)
        #expect(result.rejectedFiles == 1)
    }

    @Test func ownerMismatchForeignWorkspaceAndFutureSchemaAreRejected() async throws {
        let folder = try self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = try await MidasUsageSyncFolder.workspace(at: folder)
        _ = try await self.exchange(folder, workspace, self.publication(workspace: workspace, device: self.first))
        var schema = self.publication(workspace: workspace, device: self.second)
        schema.schemaVersion = 2
        let invalid = [
            self.publication(workspace: workspace, device: self.first),
            self.publication(workspace: MidasUsageSyncWorkspace(), device: self.second),
            schema,
            self.publication(workspace: workspace, device: self.second, date: self.now.addingTimeInterval(301)),
        ]
        for publication in invalid {
            try JSONEncoder().encode(publication).write(to: self.file(folder, self.second))
            let result = try await self.exchange(folder, workspace, nil)
            #expect(result.publications.count == 1)
            #expect(result.rejectedFiles == 1)
        }
    }

    @Test func corruptWorkspaceIsPreservedAndNeverReinitialized() async throws {
        let folder = try self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("workspace.json")
        let corrupt = Data("{broken}".utf8)
        try corrupt.write(to: file)
        await #expect(throws: (any Error).self) { try await MidasUsageSyncFolder.workspace(at: folder) }
        #expect(try Data(contentsOf: file) == corrupt)
    }

    @Test func removedWorkspaceStopsExchangeInsteadOfReinitializing() async throws {
        let folder = try self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = try await MidasUsageSyncFolder.workspace(at: folder)
        let file = folder.appendingPathComponent("workspace.json")
        try FileManager.default.removeItem(at: file)
        await #expect(throws: MidasUsageSyncError.folderUnavailable) {
            try await self.exchange(folder, workspace, self.publication(workspace: workspace, device: self.first))
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("devices").path))
    }

    @Test func futureWorkspaceSchemaIsRejectedWithoutReplacement() async throws {
        let folder = try self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = MidasUsageSyncWorkspace(schemaVersion: 2)
        let file = folder.appendingPathComponent("workspace.json")
        let data = try JSONEncoder().encode(workspace)
        try data.write(to: file)
        await #expect(throws: MidasUsageSyncError.unsupportedSchema) {
            try await MidasUsageSyncFolder.workspace(at: folder)
        }
        #expect(try Data(contentsOf: file) == data)
    }

    @Test func exchangedWorkspaceMustMatchAllMetadata() async throws {
        let folder = try self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = try await MidasUsageSyncFolder.workspace(at: folder)
        let changed = MidasUsageSyncWorkspace(
            id: workspace.id,
            identitySalt: String(repeating: "b", count: 64),
            createdAt: workspace.createdAt)
        await #expect(throws: MidasUsageSyncError.wrongWorkspace) { try await self.exchange(folder, changed, nil) }
    }

    @Test func conflictWorkspaceCopyStopsExchangeWithoutOverwritingMetadata() async throws {
        let folder = try self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = try await MidasUsageSyncFolder.workspace(at: folder)
        let original = try Data(contentsOf: folder.appendingPathComponent("workspace.json"))
        try JSONEncoder().encode(MidasUsageSyncWorkspace())
            .write(to: folder.appendingPathComponent("workspace (conflicted copy).json"))
        await #expect(throws: MidasUsageSyncError.wrongWorkspace) { try await self.exchange(folder, workspace, nil) }
        #expect(try Data(contentsOf: folder.appendingPathComponent("workspace.json")) == original)
    }

    @Test func workspacePlaceholderIsUnavailableRatherThanCreatingANewWorkspace() async throws {
        let folder = try self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("placeholder".utf8).write(to: folder.appendingPathComponent(".workspace.json.icloud"))
        await #expect(throws: MidasUsageSyncError.folderUnavailable) {
            try await MidasUsageSyncFolder.workspace(at: folder)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("workspace.json").path))
    }

    @Test func devicePlaceholderIsCountedAsUnavailableWithoutRejectingIt() async throws {
        let folder = try self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = try await MidasUsageSyncFolder.workspace(at: folder)
        _ = try await self.exchange(folder, workspace, self.publication(workspace: workspace, device: self.first))
        try Data("placeholder".utf8)
            .write(to: folder.appendingPathComponent("devices/." + self.second.uuidString + ".json.icloud"))
        let result = try await self.exchange(folder, workspace, nil)
        #expect(result.publications.count == 1)
        #expect(result.unavailableFiles == 1)
        #expect(result.rejectedFiles == 0)
    }

    @Test func failedPublicationPreservesPeerAndRejectsOwnSymlink() async throws {
        let folder = try self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = try await MidasUsageSyncFolder.workspace(at: folder)
        let peer = self.publication(workspace: workspace, device: self.second)
        _ = try await self.exchange(folder, workspace, peer)
        let outside = folder.appendingPathComponent("private.txt")
        let data = Data("Do not change".utf8)
        try data.write(to: outside)
        try FileManager.default.createSymbolicLink(at: self.file(folder, self.first), withDestinationURL: outside)
        let result = try await self.exchange(
            folder,
            workspace,
            self.publication(workspace: workspace, device: self.first))
        #expect(!result.publicationSucceeded)
        #expect(result.publications == [peer])
        #expect(result.rejectedFiles == 1)
        #expect(try Data(contentsOf: outside) == data)
    }

    @Test func workspaceAndDevicesSymlinksAreRejected() async throws {
        let folder = try self.folder()
        let external = try self.folder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: external)
        }
        let workspace = try await MidasUsageSyncFolder.workspace(at: folder)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("devices"),
            withDestinationURL: external)
        await #expect(throws: MidasUsageSyncError.unsafeFile) { try await self.exchange(folder, workspace, nil) }
        let link = external.appendingPathComponent("chosen-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        await #expect(throws: MidasUsageSyncError.unsafeFile) { try await MidasUsageSyncFolder.workspace(at: link) }
    }

    @Test func danglingWorkspaceSymlinkIsNeverReplaced() async throws {
        let folder = try self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("workspace.json")
        try FileManager.default.createSymbolicLink(
            at: file,
            withDestinationURL: folder.appendingPathComponent("missing"))
        await #expect(throws: MidasUsageSyncError.unsafeFile) { try await MidasUsageSyncFolder.workspace(at: folder) }
        #expect(try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    @Test func tooManyDeviceFilesFailExplicitlyAndForeignFilesArePreserved() async throws {
        let folder = try self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = try await MidasUsageSyncFolder.workspace(at: folder)
        _ = try await self.exchange(folder, workspace, nil)
        let notes = folder.appendingPathComponent("devices/notes.txt")
        try Data("Keep me".utf8).write(to: notes)
        for _ in 0...MidasUsageSyncFolder.maximumDevices {
            try Data("{}".utf8).write(to: self.file(folder, UUID()))
        }
        await #expect(throws: MidasUsageSyncError.limitExceeded) { try await self.exchange(folder, workspace, nil) }
        #expect(try String(contentsOf: notes, encoding: .utf8) == "Keep me")
    }

    @Test func pipePeerIsRejectedWithoutBlockingTheExchange() async throws {
        let folder = try self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = try await MidasUsageSyncFolder.workspace(at: folder)
        _ = try await self.exchange(folder, workspace, nil)
        #expect(Darwin.mkfifo(self.file(folder, self.first).path, 0o600) == 0)
        let result = try await self.exchange(folder, workspace, nil)
        #expect(result.publications.isEmpty)
        #expect(result.rejectedFiles == 1)
    }

    @Test func publicationFilesHavePrivatePermissions() async throws {
        let folder = try self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = try await MidasUsageSyncFolder.workspace(at: folder)
        _ = try await self.exchange(folder, workspace, self.publication(workspace: workspace, device: self.first))
        for file in [folder.appendingPathComponent("workspace.json"), self.file(folder, self.first)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }

    @Test func missingFolderIsUnavailable() async throws {
        let folder = try self.temporaryDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        await #expect(throws: MidasUsageSyncError.folderUnavailable) {
            try await MidasUsageSyncFolder.workspace(at: folder)
        }
    }

    @Test func cancelledOperationDoesNotCreateWorkspaceOrReturnSuccess() async throws {
        let folder = try self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MidasUsageSyncFolder.workspace(at: folder)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("workspace.json").path))
    }

    private func folder() throws -> URL {
        let folder = try self.temporaryDirectory()
            .appendingPathComponent("midas-usage-sync-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private func temporaryDirectory() throws -> URL {
        // Foundation deliberately abbreviates /private/var back to the /var symlink on macOS.
        guard let path = Darwin.realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw POSIXError(.ENOENT)
        }
        defer { Darwin.free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    private func file(_ folder: URL, _ device: UUID) -> URL {
        folder.appendingPathComponent("devices").appendingPathComponent(device.uuidString + ".json")
    }

    private func publication(
        workspace: MidasUsageSyncWorkspace,
        device: UUID,
        tokens: Int = 100,
        date: Date? = nil) -> MidasUsageSyncPublication
    {
        .init(
            workspaceID: workspace.id,
            deviceID: device,
            deviceName: "Synthetic Mac",
            publishedAt: date ?? self.now,
            events: [.init(
                id: String(repeating: device == self.first ? "a" : "b", count: 64),
                provider: .codex,
                day: "2026-09-12",
                observedAt: self.now,
                values: .init(tokens: tokens, costUSD: Double(tokens) / 100))])
    }

    private func exchange(
        _ folder: URL,
        _ workspace: MidasUsageSyncWorkspace,
        _ local: MidasUsageSyncPublication?) async throws -> MidasUsageSyncFolder.Result
    {
        try await MidasUsageSyncFolder.exchange(
            at: folder, workspace: workspace, local: local, now: self.now, elapsedTime: { .zero })
    }

    private final class ElapsedClock: @unchecked Sendable {
        private let lock = NSLock()
        private let seconds: [Int64]
        private var index = 0

        init(_ seconds: [Int64]) {
            self.seconds = seconds
        }

        func read() -> Duration {
            self.lock.lock()
            defer { self.lock.unlock() }
            let value = self.seconds[min(self.index, self.seconds.count - 1)]
            self.index += 1
            return .seconds(value)
        }
    }
}
