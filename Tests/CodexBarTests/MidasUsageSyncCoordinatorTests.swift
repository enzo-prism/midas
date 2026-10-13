import CodexBarCore
import Darwin
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MidasUsageSyncCoordinatorTests {
    private static let now = Date(timeIntervalSince1970: 1_789_171_200)

    @Test func twoCoordinatorsConvergeAndRestoreTheReceivedViewAfterRestart() async throws {
        let first = try Fixture()
        let second = try Fixture()
        defer { first.cleanup(); second.cleanup() }
        let folder = try first.sharedFolder()
        let mini = first.coordinator()
        let notebook = second.coordinator()
        self.collect(on: mini, event: "mini", tokens: 100)
        self.collect(on: notebook, event: "notebook", tokens: 200)
        try await mini.connect(folder: folder)
        try await notebook.connect(folder: folder)
        await mini.syncNow()
        await notebook.syncNow()
        await mini.syncNow()
        #expect(mini.snapshots[.codex]?.sessionTokens == 300)
        #expect(notebook.snapshots[.codex]?.sessionTokens == 300)
        #expect(mini.devices.count == 2)
        let restarted = first.coordinator(restore: true)
        #expect(restarted.isEnabled)
        #expect(restarted.folderURL == folder)
        #expect(restarted.snapshots[.codex]?.sessionTokens == 300)
        #expect(restarted.devices.filter(\.isThisMac).count == 1)
    }

    @Test func repeatedClockStillPublishesNewerHistoryAndBothDevicesConverge() async throws {
        let first = try Fixture()
        let second = try Fixture()
        defer { first.cleanup(); second.cleanup() }
        let folder = try first.sharedFolder()
        let mini = first.coordinator()
        let notebook = second.coordinator()
        self.collect(on: mini, event: "mini-original", tokens: 100)
        self.collect(on: notebook, event: "notebook", tokens: 200)
        try await mini.connect(folder: folder)
        try await notebook.connect(folder: folder)
        await mini.syncNow()
        await notebook.syncNow()
        await mini.syncNow()
        let oldSeenAt = try #require(mini.devices.first(where: \.isThisMac)?.lastSeenAt)
        self.collect(on: mini, event: "mini-new", tokens: 50)
        await mini.syncNow()
        await notebook.syncNow()
        #expect(mini.snapshots[.codex]?.sessionTokens == 350)
        #expect(notebook.snapshots[.codex]?.sessionTokens == 350)
        #expect(try #require(mini.devices.first(where: \.isThisMac)?.lastSeenAt) > oldSeenAt)
    }

    @Test func longInitialScanPublishesAgainstCompletionTime() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try fixture.sharedFolder()
        let clock = Clock(now: Self.now)
        let coordinator = fixture.coordinator(currentTime: { clock.now })
        try await coordinator.connect(folder: folder)
        coordinator.makeLocalUsage = { workspace, startedAt in
            #expect(startedAt == Self.now)
            clock.now = Self.now.addingTimeInterval(601)
            return MidasUsageSyncLocalUsage(accountDays: [.init(
                accountScope: workspace.opaqueID(provider: .cursor, components: ["synthetic-account"]),
                provider: .cursor,
                day: MidasUsageSyncPublication.day(clock.now),
                observedAt: clock.now,
                values: .init(tokens: 100, costUSD: 1))])
        }
        await coordinator.syncNow()
        #expect(coordinator.lastPublishedAt == clock.now)
        #expect(coordinator.snapshots[.cursor]?.sessionCostUSD == 1)
        #expect(coordinator.devices.first(where: \.isThisMac)?.lastSeenAt == clock.now)
    }

    @Test func peerPublicationAfterLongFolderWaitRemainsAvailable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try fixture.sharedFolder()
        let clock = Clock(now: Self.now)
        let coordinator = fixture.coordinator(currentTime: { clock.now }, exchange: { folder, workspace, local, now in
            let result = try await MidasUsageSyncFolder.exchange(
                at: folder,
                workspace: workspace,
                local: local,
                now: now)
            let peer = await MainActor.run {
                clock.now = Self.now.addingTimeInterval(601)
                return MidasUsageSyncPublication(
                    workspaceID: workspace.id,
                    deviceID: UUID(),
                    deviceName: "Notebook",
                    publishedAt: clock.now,
                    events: Self.usage(workspace: workspace, now: clock.now, event: "peer", tokens: 200).events)
            }
            return MidasUsageSyncFolder.Result(
                workspace: workspace,
                publications: result.publications + [peer],
                publicationSucceeded: result.publicationSucceeded,
                unavailableFiles: 0,
                rejectedFiles: 0)
        })
        try await coordinator.connect(folder: folder)
        self.collect(on: coordinator, event: "mini", tokens: 100)
        await coordinator.syncNow()
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 300)
        #expect(coordinator.lastReceivedAt == clock.now)
        #expect(coordinator.lastPublishedAt == clock.now)
    }

    @Test func offlineOutboxSurvivesRestartAndRetriesWithoutLosingRolledOffUsage() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try fixture.sharedFolder()
        let coordinator = fixture.coordinator(exchange: { _, _, _, _ in
            throw MidasUsageSyncError.folderUnavailable
        })
        try await coordinator.connect(folder: folder)
        self.collect(on: coordinator, event: "offline-request", tokens: 123)
        await coordinator.syncNow()
        #expect(coordinator.lastPublishedAt == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.cache.path))
        let restarted = fixture.coordinator(restore: true)
        self.collect(on: restarted, event: nil, tokens: 0)
        await restarted.syncNow()
        #expect(restarted.lastPublishedAt == Self.now)
        #expect(restarted.snapshots[.codex]?.sessionTokens == 123)
        #expect(restarted.devices.count == 1)
    }

    @Test func movedFolderPreservesReceivedUsageAndRequiresExplicitReconnection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try fixture.sharedFolder()
        let moved = fixture.directory.appendingPathComponent("moved-folder")
        let coordinator = fixture.coordinator()
        self.collect(on: coordinator, event: "mini", tokens: 100)
        try await coordinator.connect(folder: folder)
        await coordinator.syncNow()
        try FileManager.default.moveItem(at: folder, to: moved)
        let restarted = fixture.coordinator(restore: true)
        #expect(restarted.folderURL == nil)
        #expect(restarted.snapshots[.codex]?.sessionTokens == 100)
        #expect(restarted.issue?.contains("Choose your shared folder again") == true)
        self.collect(on: restarted, event: "new-request", tokens: 200)
        await restarted.syncNow()
        #expect(restarted.snapshots[.codex]?.sessionTokens == 100)
        try await restarted.connect(folder: moved)
        await restarted.syncNow()
        #expect(restarted.snapshots[.codex]?.sessionTokens == 300)
        #expect(restarted.devices.count == 1)
    }

    @Test func failedOutboxPersistenceBlocksPublicationAndPreservesReceivedUsage() async throws {
        let first = try Fixture()
        let second = try Fixture()
        defer { first.cleanup(); second.cleanup() }
        let folder = try first.sharedFolder()
        let mini = first.coordinator()
        let notebook = second.coordinator()
        self.collect(on: mini, event: "mini", tokens: 100)
        self.collect(on: notebook, event: "notebook", tokens: 200)
        try await mini.connect(folder: folder)
        try await notebook.connect(folder: folder)
        await mini.syncNow()
        await notebook.syncNow()
        await mini.syncNow()
        let ownID = try #require(mini.devices.first(where: \.isThisMac)?.id)
        let ownFile = folder.appendingPathComponent("devices/" + ownID.uuidString + ".json")
        let original = try Data(contentsOf: ownFile)
        try FileManager.default.removeItem(at: first.cache)
        try FileManager.default.createDirectory(at: first.cache, withIntermediateDirectories: false)
        self.collect(on: mini, event: "new-unsaved-request", tokens: 1000)
        await mini.syncNow()
        #expect(try Data(contentsOf: ownFile) == original)
        #expect(mini.snapshots[.codex]?.sessionTokens == 300)
        #expect(mini.issue?.contains("No usage was shared") == true)
        #expect(!mini.isSyncing)
    }

    @Test func replacingWorkspaceClearsTheViewAndReportsDisconnection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try fixture.sharedFolder()
        let coordinator = fixture.coordinator()
        self.collect(on: coordinator, event: "mini", tokens: 100)
        try await coordinator.connect(folder: folder)
        await coordinator.syncNow()
        #expect(coordinator.snapshots[.codex] != nil)
        try JSONEncoder().encode(MidasUsageSyncWorkspace())
            .write(to: folder.appendingPathComponent("workspace.json"), options: .atomic)
        await coordinator.syncNow()
        #expect(!coordinator.isEnabled)
        #expect(coordinator.folderURL == nil)
        #expect(coordinator.snapshots.isEmpty)
        #expect(coordinator.devices.isEmpty)
        #expect(coordinator.status.contains("disconnected"))
        #expect(!coordinator.status.contains("Showing last received"))
    }

    @Test func disconnectDuringCollectionPreventsPublicationAndStaleViewUpdates() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try fixture.sharedFolder()
        let coordinator = fixture.coordinator()
        let gate = Gate()
        coordinator.makeLocalUsage = { workspace, now in
            await gate.suspend()
            return Self.usage(workspace: workspace, now: now, event: "late", tokens: 100)
        }
        try await coordinator.connect(folder: folder)
        let operation = Task { await coordinator.syncNow() }
        await gate.waitUntilBlocked()
        coordinator.disconnect()
        await gate.release()
        await operation.value
        #expect(coordinator.snapshots.isEmpty)
        #expect(coordinator.folderURL == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("devices").path))
    }

    @Test func disconnectCancelsAManualExchangeBeforeItWritesTheSharedFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try fixture.sharedFolder()
        let gate = Gate()
        let coordinator = fixture.coordinator(exchange: { folder, workspace, publication, now in
            await gate.suspend()
            try Task.checkCancellation()
            return try await MidasUsageSyncFolder.exchange(
                at: folder, workspace: workspace, local: publication, now: now)
        })
        self.collect(on: coordinator, event: "mini", tokens: 100)
        try await coordinator.connect(folder: folder)
        let operation = Task { await coordinator.syncNow() }
        await gate.waitUntilBlocked()
        coordinator.disconnect()
        await gate.release()
        await operation.value
        #expect(coordinator.snapshots.isEmpty)
        #expect(coordinator.lastPublishedAt == nil)
        #expect(coordinator.status.contains("Disconnected"))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("devices").path))
    }

    @Test func accountChangeDuringCollectionPreventsPublicationBeforeFolderAccess() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try fixture.sharedFolder()
        var identity = MidasUsageSyncEnvironmentIdentity(deviceBinding: "mini", cloudAccountFingerprint: "account-a")
        let coordinator = MidasUsageSyncCoordinator(
            defaults: fixture.defaults,
            persistenceURL: fixture.cache,
            automaticallySyncs: false,
            environmentIdentity: { identity },
            currentTime: { Self.now })
        let gate = Gate()
        coordinator.makeLocalUsage = { workspace, now in
            await gate.suspend()
            return Self.usage(workspace: workspace, now: now, event: "mini", tokens: 100)
        }
        try await coordinator.connect(folder: folder)
        let operation = Task { await coordinator.syncNow() }
        await gate.waitUntilBlocked()
        identity.cloudAccountFingerprint = "account-b"
        await gate.release()
        await operation.value
        #expect(!coordinator.isEnabled)
        #expect(coordinator.snapshots.isEmpty)
        #expect(coordinator.issue?.contains("iCloud account changed") == true)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("devices").path))
    }

    @Test func latestConnectWinsWhenEarlierFolderLoadFinishesLast() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let earlier = try fixture.sharedFolder("earlier")
        let latest = try fixture.sharedFolder("latest")
        let gate = Gate()
        let coordinator = fixture.coordinator(loader: { folder in
            if folder.lastPathComponent == "earlier" { await gate.suspend() }
            return try await MidasUsageSyncFolder.workspace(at: folder)
        })
        let operation = Task { try await coordinator.connect(folder: earlier) }
        await gate.waitUntilBlocked()
        try await coordinator.connect(folder: latest)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(coordinator.folderURL == latest)
        #expect(coordinator.isEnabled)
    }

    @Test func accountChangeWhileClosedPausesAndClearsBeforeAnyCollection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try fixture.sharedFolder()
        let original = fixture.coordinator(identity: .init(deviceBinding: "mini", cloudAccountFingerprint: "account-a"))
        self.collect(on: original, event: "mini", tokens: 100)
        try await original.connect(folder: folder)
        await original.syncNow()
        let restarted = fixture.coordinator(
            restore: true,
            identity: .init(
                deviceBinding: "mini",
                cloudAccountFingerprint: "account-b"))
        #expect(!restarted.isEnabled)
        #expect(restarted.folderURL == nil)
        #expect(restarted.snapshots.isEmpty)
        #expect(restarted.issue?.contains("iCloud account changed") == true)
    }

    @Test func copiedPreferencesCreateANewDeviceAndNeverRestoreTheOtherMacsOutbox() async throws {
        let first = try Fixture()
        let second = try Fixture()
        defer { first.cleanup(); second.cleanup() }
        let folder = try first.sharedFolder()
        let mini = first.coordinator(identity: .init(deviceBinding: "mini", cloudAccountFingerprint: "account"))
        self.collect(on: mini, event: "mini", tokens: 100)
        try await mini.connect(folder: folder)
        await mini.syncNow()
        let oldID = first.defaults.string(forKey: "midasUsageSyncDeviceID")
        second.defaults.setPersistentDomain(
            first.defaults.persistentDomain(forName: first.suite) ?? [:],
            forName: second.suite)
        try FileManager.default.copyItem(at: first.cache, to: second.cache)
        let notebook = second.coordinator(
            restore: true,
            identity: .init(
                deviceBinding: "notebook",
                cloudAccountFingerprint: "account"))
        #expect(second.defaults.string(forKey: "midasUsageSyncDeviceID") != oldID)
        #expect(!notebook.isEnabled)
        #expect(notebook.snapshots.isEmpty)
        self.collect(on: notebook, event: "notebook", tokens: 200)
        try await notebook.connect(folder: folder)
        await notebook.syncNow()
        #expect(notebook.snapshots[.codex]?.sessionTokens == 300)
        #expect(notebook.devices.count == 2)
    }

    @Test func foreignPendingPublicationIsNotRestoredOrRepublished() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try fixture.sharedFolder()
        let coordinator = fixture.coordinator(exchange: { _, _, _, _ in
            throw MidasUsageSyncError.folderUnavailable
        })
        self.collect(on: coordinator, event: "foreign-outbox", tokens: 900)
        try await coordinator.connect(folder: folder)
        await coordinator.syncNow()
        var cache = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.cache)) as? [String: Any])
        var pending = try #require(cache["pendingLocal"] as? [String: Any])
        pending["deviceID"] = UUID().uuidString
        cache["pendingLocal"] = pending
        try JSONSerialization.data(withJSONObject: cache).write(to: fixture.cache, options: .atomic)
        let restarted = fixture.coordinator(restore: true)
        self.collect(on: restarted, event: "own-request", tokens: 100)
        await restarted.syncNow()
        #expect(restarted.snapshots[.codex]?.sessionTokens == 100)
        #expect(restarted.devices.count == 1)
    }

    @Test func unicodeDeviceNameStaysWithinThePublicationByteLimit() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try fixture.sharedFolder()
        let coordinator = fixture.coordinator()
        coordinator.deviceName = String(repeating: "界", count: 80) + "\n"
        self.collect(on: coordinator, event: "mini", tokens: 100)
        try await coordinator.connect(folder: folder)
        await coordinator.syncNow()
        let name = try #require(coordinator.devices.first?.name)
        #expect(name.utf8.count <= 80)
        #expect(!name.contains("\n"))
        #expect(coordinator.lastPublishedAt == Self.now)
    }

    @Test func symlinkCacheAndAncestorNeverOverwriteTheirTargets() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try fixture.sharedFolder()
        let target = fixture.directory.appendingPathComponent("preserved.txt")
        let data = Data("Preserve synthetic contents".utf8)
        try data.write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.cache, withDestinationURL: target)
        let coordinator = fixture.coordinator()
        self.collect(on: coordinator, event: "mini", tokens: 100)
        try await coordinator.connect(folder: folder)
        await coordinator.syncNow()
        #expect(try Data(contentsOf: target) == data)
        #expect(coordinator.lastPublishedAt == nil)
        let link = fixture.directory.appendingPathComponent("linked-parent")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.directory)
        let sibling = fixture.coordinator(cache: link.appendingPathComponent("escaped.json"))
        self.collect(on: sibling, event: "mini", tokens: 100)
        try await sibling.connect(folder: folder)
        await sibling.syncNow()
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("escaped.json").path))
        #expect(sibling.lastPublishedAt == nil)
    }

    private func collect(on coordinator: MidasUsageSyncCoordinator, event: String?, tokens: Int) {
        coordinator.makeLocalUsage = { workspace, now in
            Self.usage(workspace: workspace, now: now, event: event, tokens: tokens)
        }
    }

    private static func usage(
        workspace: MidasUsageSyncWorkspace, now: Date, event: String?, tokens: Int) -> MidasUsageSyncLocalUsage
    {
        guard let event else { return MidasUsageSyncLocalUsage() }
        return MidasUsageSyncLocalUsage(events: [.init(
            id: workspace.opaqueID(provider: .codex, components: ["synthetic", event]),
            provider: .codex,
            day: MidasUsageSyncPublication.day(now),
            observedAt: now,
            values: .init(tokens: tokens, costUSD: 1))])
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let cache: URL
        let suite: String
        let defaults: UserDefaults

        init() throws {
            self.suite = "MidasUsageSyncCoordinatorTests-" + UUID().uuidString
            self.defaults = try #require(UserDefaults(suiteName: self.suite))
            guard let path = Darwin.realpath(FileManager.default.temporaryDirectory.path, nil) else {
                throw POSIXError(.ENOENT)
            }
            defer { Darwin.free(path) }
            self.directory = URL(fileURLWithPath: String(cString: path), isDirectory: true)
                .appendingPathComponent(self.suite, isDirectory: true)
            self.cache = self.directory.appendingPathComponent("state.json")
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: false)
        }

        func sharedFolder(_ name: String = "shared") throws -> URL {
            let folder = self.directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            return folder
        }

        func coordinator(
            restore: Bool = false,
            identity: MidasUsageSyncEnvironmentIdentity = .init(),
            cache: URL? = nil,
            currentTime: @escaping @MainActor () -> Date = { MidasUsageSyncCoordinatorTests.now },
            loader: @escaping @Sendable (URL) async throws -> MidasUsageSyncWorkspace = {
                try await MidasUsageSyncFolder.workspace(at: $0)
            },
            exchange: @escaping @Sendable (
                URL, MidasUsageSyncWorkspace, MidasUsageSyncPublication, Date) async throws -> MidasUsageSyncFolder
                .Result = {
                    try await MidasUsageSyncFolder.exchange(at: $0, workspace: $1, local: $2, now: $3)
                }) -> MidasUsageSyncCoordinator
        {
            MidasUsageSyncCoordinator(
                defaults: self.defaults,
                persistenceURL: cache ?? self.cache,
                automaticallySyncs: false,
                environmentIdentity: { identity },
                restoresConnection: restore,
                workspaceLoader: loader,
                exchangePublication: exchange,
                currentTime: currentTime)
        }

        private static var now: Date {
            MidasUsageSyncCoordinatorTests.now
        }

        func cleanup() {
            self.defaults.removePersistentDomain(forName: self.suite)
            try? FileManager.default.removeItem(at: self.directory)
        }
    }

    @MainActor
    private final class Clock {
        var now: Date

        init(now: Date) {
            self.now = now
        }
    }

    private actor Gate {
        private var blocked = false
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private var observer: CheckedContinuation<Void, Never>?

        func suspend() async {
            self.blocked = true
            self.observer?.resume()
            self.observer = nil
            await withCheckedContinuation { self.releaseContinuation = $0 }
        }

        func waitUntilBlocked() async {
            if self.blocked { return }
            await withCheckedContinuation { self.observer = $0 }
        }

        func release() {
            self.releaseContinuation?.resume()
            self.releaseContinuation = nil
        }
    }
}
