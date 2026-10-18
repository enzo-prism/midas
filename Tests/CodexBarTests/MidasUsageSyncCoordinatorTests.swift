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

    @Test func slowOutboxPersistenceRunsOffMainActorAndDisconnectPreventsPublication() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try fixture.sharedFolder()
        let gate = MidasUsageSyncWriteGate()
        defer { gate.release() }
        let coordinator = fixture.coordinator(cacheWriter: { data, url in
            #expect(!Thread.isMainThread)
            try gate.write(data, to: url)
        })
        try await coordinator.connect(folder: folder)
        self.collect(on: coordinator, event: "pending-on-disk", tokens: 123)
        let sync = Task { await coordinator.syncNow() }
        await gate.waitUntilBlocked()

        // The UI executor remains responsive while fsync is pending on the worker actor.
        #expect(coordinator.isSyncing)
        coordinator.disconnect()
        gate.release()
        await sync.value

        #expect(!coordinator.isEnabled)
        #expect(coordinator.snapshots.isEmpty)
        #expect(coordinator.status.hasPrefix("Disconnected."))
        #expect(coordinator.lastPublishedAt == nil)
        let devicesFolder = folder.appendingPathComponent("devices")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: devicesFolder.path)) ?? []
        #expect(files.isEmpty)
        let cache = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.cache)) as? [String: Any])
        #expect(cache["pendingLocal"] is [String: Any])
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

    @Test func unchangedAccountNotificationRetainsTheConnectionAndReceivedHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try fixture.sharedFolder()
        let coordinator = fixture.coordinator(identity: .init(
            deviceBinding: "mini",
            cloudAccountFingerprint: "account-a"))
        self.collect(on: coordinator, event: "mini", tokens: 100)
        try await coordinator.connect(folder: folder)
        await coordinator.syncNow()
        let bookmark = try #require(fixture.defaults.data(forKey: "midasUsageSyncFolderBookmark"))
        let cache = try Data(contentsOf: fixture.cache)

        coordinator.accountChanged()

        #expect(coordinator.isEnabled)
        #expect(coordinator.folderURL == folder)
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 100)
        #expect(coordinator.issue == nil)
        #expect(fixture.defaults.data(forKey: "midasUsageSyncFolderBookmark") == bookmark)
        #expect(try Data(contentsOf: fixture.cache) == cache)
    }

    @Test(arguments: ["identity-unavailable", "no-icloud-account"])
    func unavailableIdentityPausesCollectionAndRecoversWithoutReconnecting(unavailableIdentity: String) async throws {
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
        var collectionCount = 0
        var event = "original"
        var tokens = 100
        coordinator.makeLocalUsage = { workspace, now in
            collectionCount += 1
            return Self.usage(workspace: workspace, now: now, event: event, tokens: tokens)
        }
        try await coordinator.connect(folder: folder)
        await coordinator.syncNow()
        let bookmark = try #require(fixture.defaults.data(forKey: "midasUsageSyncFolderBookmark"))
        let ownID = try #require(coordinator.devices.first(where: \.isThisMac)?.id)
        let ownFile = folder.appendingPathComponent("devices/" + ownID.uuidString + ".json")
        let original = try Data(contentsOf: ownFile)
        let originalCache = try Data(contentsOf: fixture.cache)

        identity.cloudAccountFingerprint = unavailableIdentity
        await coordinator.syncNow()

        #expect(coordinator.isEnabled)
        #expect(coordinator.folderURL == folder)
        #expect(coordinator.snapshots.isEmpty)
        #expect(coordinator.devices.isEmpty)
        #expect(collectionCount == 1)
        #expect(!coordinator.isSyncing)
        #expect(fixture.defaults.data(forKey: "midasUsageSyncFolderBookmark") == bookmark)
        #expect(try Data(contentsOf: ownFile) == original)
        #expect(try Data(contentsOf: fixture.cache) == originalCache)

        identity.cloudAccountFingerprint = "account-a"
        event = "after-recovery"
        tokens = 200
        await coordinator.syncNow()

        #expect(coordinator.isEnabled)
        #expect(coordinator.folderURL == folder)
        #expect(collectionCount == 2)
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 300)
        #expect(coordinator.issue == nil)
        #expect(fixture.defaults.data(forKey: "midasUsageSyncFolderBookmark") == bookmark)
    }

    @Test func unavailableAccountNotificationCancelsAnExchangeBeforeItWritesAndPreservesTheOutbox() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try fixture.sharedFolder()
        var identity = MidasUsageSyncEnvironmentIdentity(deviceBinding: "mini", cloudAccountFingerprint: "account-a")
        let gate = Gate()
        let coordinator = MidasUsageSyncCoordinator(
            defaults: fixture.defaults,
            persistenceURL: fixture.cache,
            automaticallySyncs: false,
            environmentIdentity: { identity },
            exchangePublication: { folder, workspace, publication, now in
                await gate.suspend()
                try Task.checkCancellation()
                return try await MidasUsageSyncFolder.exchange(
                    at: folder, workspace: workspace, local: publication, now: now)
            },
            currentTime: { Self.now })
        self.collect(on: coordinator, event: "waiting-request", tokens: 100)
        try await coordinator.connect(folder: folder)
        let bookmark = try #require(fixture.defaults.data(forKey: "midasUsageSyncFolderBookmark"))
        let operation = Task { await coordinator.syncNow() }
        await gate.waitUntilBlocked()

        identity.cloudAccountFingerprint = "identity-unavailable"
        coordinator.accountChanged()
        await gate.release()
        await operation.value

        #expect(coordinator.isEnabled)
        #expect(coordinator.folderURL == folder)
        #expect(coordinator.snapshots.isEmpty)
        #expect(coordinator.devices.isEmpty)
        #expect(!coordinator.isSyncing)
        #expect(coordinator.lastPublishedAt == nil)
        #expect(fixture.defaults.data(forKey: "midasUsageSyncFolderBookmark") == bookmark)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("devices").path))
        let cache = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.cache)) as? [String: Any])
        #expect(cache["pendingLocal"] is [String: Any])

        let recovered = fixture.coordinator(restore: true, identity: .init(
            deviceBinding: "mini",
            cloudAccountFingerprint: "account-a"))
        self.collect(on: recovered, event: nil, tokens: 0)
        await recovered.syncNow()

        #expect(recovered.lastPublishedAt == Self.now)
        #expect(recovered.snapshots[.codex]?.sessionTokens == 100)
        #expect(recovered.issue == nil)
    }

    @Test func unavailableIdentityAtRestartKeepsTheBookmarkAndRestoresWhenTheSameAccountReturns() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try fixture.sharedFolder()
        let original = fixture.coordinator(identity: .init(deviceBinding: "mini", cloudAccountFingerprint: "account-a"))
        self.collect(on: original, event: "original", tokens: 100)
        try await original.connect(folder: folder)
        await original.syncNow()
        let bookmark = try #require(fixture.defaults.data(forKey: "midasUsageSyncFolderBookmark"))
        let originalCache = try Data(contentsOf: fixture.cache)
        var identity = MidasUsageSyncEnvironmentIdentity(
            deviceBinding: "mini",
            cloudAccountFingerprint: "identity-unavailable")
        let restarted = MidasUsageSyncCoordinator(
            defaults: fixture.defaults,
            persistenceURL: fixture.cache,
            automaticallySyncs: false,
            environmentIdentity: { identity },
            restoresConnection: true,
            currentTime: { Self.now })
        var collectionCount = 0
        restarted.makeLocalUsage = { workspace, now in
            collectionCount += 1
            return Self.usage(workspace: workspace, now: now, event: "after-restart", tokens: 200)
        }
        await restarted.syncNow()

        #expect(restarted.isEnabled)
        #expect(restarted.folderURL == nil)
        #expect(collectionCount == 0)
        #expect(fixture.defaults.data(forKey: "midasUsageSyncFolderBookmark") == bookmark)
        #expect(try Data(contentsOf: fixture.cache) == originalCache)

        identity.cloudAccountFingerprint = "account-a"
        await restarted.syncNow()

        #expect(restarted.isEnabled)
        #expect(restarted.folderURL == folder)
        #expect(collectionCount == 1)
        #expect(restarted.snapshots[.codex]?.sessionTokens == 300)
        #expect(restarted.issue == nil)
        #expect(restarted.devices.count == 1)
    }

    @Test func confirmedAccountChangeNotificationClearsTheConnectionBeforeFurtherCollection() async throws {
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
        var collectionCount = 0
        coordinator.makeLocalUsage = { workspace, now in
            collectionCount += 1
            return Self.usage(workspace: workspace, now: now, event: "mini", tokens: 100)
        }
        try await coordinator.connect(folder: folder)
        await coordinator.syncNow()
        let ownID = try #require(coordinator.devices.first(where: \.isThisMac)?.id)
        let ownFile = folder.appendingPathComponent("devices/" + ownID.uuidString + ".json")
        let original = try Data(contentsOf: ownFile)

        identity.cloudAccountFingerprint = "account-b"
        coordinator.accountChanged()
        await coordinator.syncNow()

        #expect(!coordinator.isEnabled)
        #expect(coordinator.folderURL == nil)
        #expect(coordinator.snapshots.isEmpty)
        #expect(coordinator.devices.isEmpty)
        #expect(coordinator.issue?.contains("iCloud account changed") == true)
        #expect(fixture.defaults.data(forKey: "midasUsageSyncFolderBookmark") == nil)
        #expect(collectionCount == 1)
        #expect(try Data(contentsOf: ownFile) == original)
    }

    @Test func equivalentIdentityTokensKeepOneFingerprintDespiteDifferentArchiveBytes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = MidasUsageSyncSyntheticIdentityToken(account: "account-a", archiveRevision: "first-encoding")
        let equivalent = MidasUsageSyncSyntheticIdentityToken(account: "account-a", archiveRevision: "other-encoding")
        let firstArchive = try NSKeyedArchiver.archivedData(withRootObject: first, requiringSecureCoding: false)
        let otherArchive = try NSKeyedArchiver.archivedData(withRootObject: equivalent, requiringSecureCoding: false)
        #expect(first.isEqual(equivalent))
        #expect(firstArchive != otherArchive)
        let fingerprint = MidasUsageSyncEnvironmentIdentity.cloudAccountFingerprint(
            token: first,
            defaults: fixture.defaults)

        #expect(MidasUsageSyncEnvironmentIdentity.cloudAccountFingerprint(
            token: equivalent,
            defaults: fixture.defaults) == fingerprint)
        #expect(MidasUsageSyncEnvironmentIdentity.cloudAccountFingerprint(
            token: nil,
            defaults: fixture.defaults) == "identity-unavailable")
        #expect(fixture.defaults.string(forKey: "midasUsageSyncIdentityFingerprint") == fingerprint)
        #expect(MidasUsageSyncEnvironmentIdentity.cloudAccountFingerprint(
            token: equivalent,
            defaults: fixture.defaults) == fingerprint)

        let different = MidasUsageSyncSyntheticIdentityToken(account: "account-b", archiveRevision: "first-encoding")
        #expect(MidasUsageSyncEnvironmentIdentity.cloudAccountFingerprint(
            token: different,
            defaults: fixture.defaults) != fingerprint)
    }

    @Test func legacyAccountFingerprintWithoutAnArchivedTokenRequiresReconnection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try fixture.sharedFolder()
        let legacyFingerprint = String(repeating: "a", count: 64)
        let original = fixture.coordinator(identity: .init(
            deviceBinding: "mini",
            cloudAccountFingerprint: legacyFingerprint))
        self.collect(on: original, event: "original", tokens: 100)
        try await original.connect(folder: folder)
        await original.syncNow()
        let originalCache = try Data(contentsOf: fixture.cache)
        #expect(fixture.defaults.data(forKey: "midasUsageSyncIdentityToken") == nil)
        let currentFingerprint = MidasUsageSyncEnvironmentIdentity.cloudAccountFingerprint(
            token: MidasUsageSyncSyntheticIdentityToken(account: "account-a", archiveRevision: "new-format"),
            defaults: fixture.defaults)
        let restarted = fixture.coordinator(restore: true, identity: .init(
            deviceBinding: "mini",
            cloudAccountFingerprint: currentFingerprint))
        var collectionCount = 0
        restarted.makeLocalUsage = { workspace, now in
            collectionCount += 1
            return Self.usage(workspace: workspace, now: now, event: "new-request", tokens: 200)
        }
        await restarted.syncNow()

        #expect(currentFingerprint != legacyFingerprint)
        #expect(!restarted.isEnabled)
        #expect(restarted.folderURL == nil)
        #expect(restarted.snapshots.isEmpty)
        #expect(restarted.issue?.contains("shared folder again") == true)
        #expect(fixture.defaults.data(forKey: "midasUsageSyncFolderBookmark") == nil)
        #expect(collectionCount == 0)
        #expect(try Data(contentsOf: fixture.cache) == originalCache)
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
            cacheWriter: (@Sendable (Data, URL) throws -> Void)? = nil,
            loader: @escaping @Sendable (URL) async throws -> MidasUsageSyncWorkspace = {
                try await MidasUsageSyncFolder.workspace(at: $0)
            },
            exchange: @escaping @Sendable (
                URL, MidasUsageSyncWorkspace, MidasUsageSyncPublication, Date) async throws -> MidasUsageSyncFolder
                .Result = {
                    try await MidasUsageSyncFolder.exchange(at: $0, workspace: $1, local: $2, now: $3)
                }) -> MidasUsageSyncCoordinator
        {
            if let cacheWriter {
                return MidasUsageSyncCoordinator(
                    defaults: self.defaults,
                    persistenceURL: cache ?? self.cache,
                    automaticallySyncs: false,
                    environmentIdentity: { identity },
                    restoresConnection: restore,
                    workspaceLoader: loader,
                    exchangePublication: exchange,
                    currentTime: currentTime,
                    cacheWriter: cacheWriter)
            }
            return MidasUsageSyncCoordinator(
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

extension MidasUsageSyncCoordinatorTests {
    @Test func chunkedCacheEncodingPreservesSchemaTwoMetadataAndTheOfflineOutbox() async throws {
        let first = try Fixture()
        let second = try Fixture()
        defer { first.cleanup(); second.cleanup() }
        let identity = MidasUsageSyncEnvironmentIdentity(
            deviceBinding: "synthetic-mini", cloudAccountFingerprint: "synthetic-account")
        let folder = try first.sharedFolder()
        let mini = first.coordinator(identity: identity)
        let notebook = second.coordinator(identity: .init(
            deviceBinding: "synthetic-notebook", cloudAccountFingerprint: "synthetic-account"))
        self.collect(on: mini, event: "mini", tokens: 100)
        self.collect(on: notebook, event: "notebook", tokens: 200)
        try await mini.connect(folder: folder)
        try await notebook.connect(folder: folder)
        await mini.syncNow()
        await notebook.syncNow()
        await mini.syncNow()
        let before = try MidasUsageSyncCodec.decodeEnvelope(Data(contentsOf: first.cache))
        let originalMetadata = try JSONDecoder().decode(MidasUsageSyncCacheMetadata.self, from: before.metadata)
        #expect(originalMetadata.schemaVersion == 2)
        #expect(originalMetadata.localDeviceID.uuidString == first.defaults.string(forKey: "midasUsageSyncDeviceID"))
        #expect(originalMetadata.deviceBinding == identity.deviceBinding)
        #expect(originalMetadata.accountFingerprint == identity.cloudAccountFingerprint)
        #expect(originalMetadata.lastPublishedAt == Self.now)
        #expect(originalMetadata.lastReceivedAt == Self.now)

        let offline = first.coordinator(restore: true, identity: identity, exchange: { _, _, _, _ in
            throw MidasUsageSyncError.folderUnavailable
        })
        self.collect(on: offline, event: "pending", tokens: 50)
        await offline.syncNow()
        let saved = try MidasUsageSyncCodec.decodeEnvelope(Data(contentsOf: first.cache))
        let savedMetadata = try JSONDecoder().decode(MidasUsageSyncCacheMetadata.self, from: saved.metadata)
        #expect(savedMetadata == originalMetadata)
        #expect(saved.publications == before.publications)
        let pending = try #require(saved.pendingLocal)
        #expect(pending.workspaceID == originalMetadata.workspace.id)
        #expect(pending.deviceID == originalMetadata.localDeviceID)
        #expect(pending.events.reduce(0) { $0 + ($1.values.tokens ?? 0) } == 150)

        let restarted = first.coordinator(restore: true, identity: identity)
        #expect(restarted.snapshots[.codex]?.sessionTokens == 300)
        #expect(restarted.lastPublishedAt == originalMetadata.lastPublishedAt)
        #expect(restarted.lastReceivedAt == originalMetadata.lastReceivedAt)
        self.collect(on: restarted, event: nil, tokens: 0)
        await restarted.syncNow()
        #expect(restarted.snapshots[.codex]?.sessionTokens == 350)
    }

    @Test func chunkedCacheEncodingPreservesNilMetadataAndEmptyHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try fixture.sharedFolder()
        let coordinator = fixture.coordinator(exchange: { _, _, _, _ in
            throw MidasUsageSyncError.folderUnavailable
        })
        try await coordinator.connect(folder: folder)
        self.collect(on: coordinator, event: nil, tokens: 0)
        await coordinator.syncNow()
        let data = try Data(contentsOf: fixture.cache)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["deviceBinding"] == nil)
        #expect(object["lastPublishedAt"] == nil)
        #expect(object["lastReceivedAt"] == nil)
        let saved = try MidasUsageSyncCodec.decodeEnvelope(data)
        #expect(saved.publications.isEmpty)
        let pending = try #require(saved.pendingLocal)
        #expect(pending.events.isEmpty)
        #expect(pending.accountDays.isEmpty)
        let metadata = try JSONDecoder().decode(MidasUsageSyncCacheMetadata.self, from: saved.metadata)
        #expect(metadata.schemaVersion == 2)
        #expect(metadata.deviceBinding == nil)
        #expect(metadata.lastPublishedAt == nil)
        #expect(metadata.lastReceivedAt == nil)
        #expect(metadata.workspace.id == pending.workspaceID)

        let restarted = fixture.coordinator(restore: true)
        #expect(restarted.isEnabled)
        #expect(restarted.snapshots.isEmpty)
        self.collect(on: restarted, event: nil, tokens: 0)
        await restarted.syncNow()
        let acknowledgedData = try Data(contentsOf: fixture.cache)
        let acknowledgedObject = try #require(
            JSONSerialization.jsonObject(with: acknowledgedData) as? [String: Any])
        #expect(acknowledgedObject["pendingLocal"] == nil)
        let acknowledged = try MidasUsageSyncCodec.decodeEnvelope(acknowledgedData)
        #expect(acknowledged.pendingLocal == nil)
        #expect(acknowledged.publications.count == 1)
        #expect(acknowledged.publications.first?.events.isEmpty == true)
        #expect(acknowledged.publications.first?.accountDays.isEmpty == true)
    }

    @Test func explicitLegacyReconnectionPreservesRolledOffHistoryAndRebindsTheCache() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try fixture.sharedFolder()
        let original = fixture.coordinator(identity: .init(
            deviceBinding: "mini",
            cloudAccountFingerprint: String(repeating: "a", count: 64)))
        self.collect(on: original, event: "rolled-off-request", tokens: 100)
        try await original.connect(folder: folder)
        await original.syncNow()
        let deviceID = try #require(original.devices.first(where: \.isThisMac)?.id)
        let publicationFile = folder.appendingPathComponent("devices/" + deviceID.uuidString + ".json")
        let identity = MidasUsageSyncEnvironmentIdentity(
            deviceBinding: "mini",
            cloudAccountFingerprint: "icloud-account-v2:" + UUID().uuidString)
        let updated = fixture.coordinator(restore: true, identity: identity)
        #expect(!updated.isEnabled)
        #expect(updated.snapshots.isEmpty)

        self.collect(on: updated, event: nil, tokens: 0)
        try await updated.connect(folder: folder)
        #expect(updated.snapshots[.codex]?.sessionTokens == 100)
        await updated.syncNow()

        #expect(updated.snapshots[.codex]?.sessionTokens == 100)
        let publication = try JSONDecoder().decode(
            MidasUsageSyncPublication.self,
            from: Data(contentsOf: publicationFile))
        #expect(publication.events.map(\.values.tokens) == [100])
        let cache = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.cache)) as? [String: Any])
        #expect(cache["accountFingerprint"] as? String == identity.cloudAccountFingerprint)

        let restarted = fixture.coordinator(restore: true, identity: identity)
        #expect(restarted.isEnabled)
        #expect(restarted.folderURL == folder)
        #expect(restarted.snapshots[.codex]?.sessionTokens == 100)
        self.collect(on: restarted, event: nil, tokens: 0)
        await restarted.syncNow()
        #expect(restarted.snapshots[.codex]?.sessionTokens == 100)
    }

    @Test func explicitLegacyReconnectionDoesNotImportACacheFromADifferentWorkspaceSalt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let originalFolder = try fixture.sharedFolder("original")
        let foreignFolder = try fixture.sharedFolder("foreign")
        let original = fixture.coordinator(identity: .init(
            deviceBinding: "mini",
            cloudAccountFingerprint: String(repeating: "a", count: 64)))
        self.collect(on: original, event: "original-request", tokens: 100)
        try await original.connect(folder: originalFolder)
        await original.syncNow()
        let deviceID = try #require(original.devices.first(where: \.isThisMac)?.id)
        let originalFile = originalFolder.appendingPathComponent("devices/" + deviceID.uuidString + ".json")
        let originalData = try Data(contentsOf: originalFile)
        let workspace = try JSONDecoder().decode(
            MidasUsageSyncWorkspace.self,
            from: Data(contentsOf: originalFolder.appendingPathComponent("workspace.json")))
        let foreignWorkspace = MidasUsageSyncWorkspace(id: workspace.id, createdAt: workspace.createdAt)
        #expect(foreignWorkspace != workspace)
        try JSONEncoder().encode(foreignWorkspace).write(to: foreignFolder.appendingPathComponent("workspace.json"))
        let updated = fixture.coordinator(restore: true, identity: .init(
            deviceBinding: "mini",
            cloudAccountFingerprint: "icloud-account-v2:" + UUID().uuidString))

        self.collect(on: updated, event: nil, tokens: 0)
        try await updated.connect(folder: foreignFolder)
        await updated.syncNow()

        #expect(updated.isEnabled)
        #expect(updated.folderURL == foreignFolder)
        #expect(updated.snapshots.isEmpty)
        #expect(updated.devices.count == 1)
        #expect(updated.devices.first?.eventCount == 0)
        #expect(try Data(contentsOf: originalFile) == originalData)
        let foreignFile = foreignFolder.appendingPathComponent("devices/" + deviceID.uuidString + ".json")
        let foreignPublication = try JSONDecoder().decode(
            MidasUsageSyncPublication.self,
            from: Data(contentsOf: foreignFile))
        #expect(foreignPublication.events.isEmpty)
    }
}

@objc(MidasUsageSyncSyntheticIdentityToken)
private final class MidasUsageSyncSyntheticIdentityToken: NSObject, NSCoding {
    let account: String
    let archiveRevision: String

    init(account: String, archiveRevision: String) {
        self.account = account
        self.archiveRevision = archiveRevision
        super.init()
    }

    required init?(coder: NSCoder) {
        guard let account = coder.decodeObject(forKey: "account") as? String,
              let archiveRevision = coder.decodeObject(forKey: "archiveRevision") as? String else { return nil }
        self.account = account
        self.archiveRevision = archiveRevision
        super.init()
    }

    func encode(with coder: NSCoder) {
        coder.encode(self.account, forKey: "account")
        coder.encode(self.archiveRevision, forKey: "archiveRevision")
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? MidasUsageSyncSyntheticIdentityToken)?.account == self.account
    }

    override var hash: Int {
        self.account.hashValue
    }
}

private final class MidasUsageSyncWriteGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked = false
    private var released = false
    private var observer: CheckedContinuation<Void, Never>?

    func write(_ data: Data, to url: URL) throws {
        self.condition.lock()
        self.blocked = true
        self.observer?.resume()
        self.observer = nil
        // A bounded wait makes a regression fail instead of hanging the test process.
        let deadline = Date().addingTimeInterval(5)
        while !self.released {
            if !self.condition.wait(until: deadline) { break }
        }
        self.condition.unlock()
        try data.write(to: url, options: .atomic)
    }

    func waitUntilBlocked() async {
        await withCheckedContinuation { continuation in
            self.condition.lock()
            if self.blocked {
                self.condition.unlock()
                continuation.resume()
            } else {
                self.observer = continuation
                self.condition.unlock()
            }
        }
    }

    func release() {
        self.condition.lock()
        self.released = true
        self.condition.broadcast()
        self.condition.unlock()
    }
}

private struct MidasUsageSyncCacheMetadata: Decodable, Equatable {
    let schemaVersion: Int
    let localDeviceID: UUID
    let deviceBinding: String?
    let accountFingerprint: String
    let workspace: MidasUsageSyncWorkspace
    let lastPublishedAt: Date?
    let lastReceivedAt: Date?
}
