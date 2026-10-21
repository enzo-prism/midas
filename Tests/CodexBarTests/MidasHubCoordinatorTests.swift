import CodexBarCore
import Darwin
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MidasHubCoordinatorTests {
    private static let now = Date(timeIntervalSince1970: 1_789_171_200)

    @Test func hubDoesNotRequireICloudAndUsesTheEnrolledDeviceIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let identity = Identity(cloudAccountFingerprint: "identity-unavailable")
        let coordinator = fixture.coordinator(identity: identity)
        try await coordinator.connect(hub: fixture.connection)
        coordinator.deviceName = "An unapproved rename"
        self.collect(
            on: coordinator,
            event: "mini",
            tokens: 100)
        await coordinator.syncNow()

        #expect(coordinator.isEnabled)
        #expect(coordinator.transport == .tailscaleHub)
        #expect(coordinator.folderURL == nil)
        #expect(coordinator.hasConnection)
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 100)
        #expect(coordinator.devices.first?.id == fixture.connection.deviceID)
        #expect(coordinator.devices.first?.name == fixture.connection.deviceName)
        #expect(coordinator.devices.first?.isThisMac == true)
        #expect(coordinator.issue == nil)

        identity.value.cloudAccountFingerprint = "a-different-account"
        coordinator.accountChanged()
        await coordinator.syncNow()
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 100)
        #expect(coordinator.isEnabled)
        identity.value.cloudAccountFingerprint = "identity-unavailable"
        let restarted = fixture.coordinator(
            restore: true,
            identity: identity)
        #expect(restarted.isEnabled)
        #expect(restarted.hasConnection)
        #expect(restarted.snapshots[.codex]?.sessionTokens == 100)
    }

    @Test func offlineOutboxAndReceivedHistorySurviveRestartThenConverge() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let peer = self.publication(
            workspace: fixture.workspace,
            deviceID: UUID(),
            event: "spark",
            tokens: 200)
        await fixture.hub.setPublications([peer])
        let coordinator = fixture.coordinator()
        try await coordinator.connect(hub: fixture.connection)
        self.collect(
            on: coordinator,
            event: "first",
            tokens: 100)
        await coordinator.syncNow()
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 300)

        await fixture.hub.setFailure(.unavailable)
        self.collect(
            on: coordinator,
            event: "offline",
            tokens: 50)
        await coordinator.syncNow()
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 300)
        #expect(coordinator.hasPendingUpload)
        #expect(coordinator.issue != nil)
        let restarted = fixture.coordinator(restore: true)
        #expect(restarted.hasConnection)
        #expect(restarted.snapshots[.codex]?.sessionTokens == 300)
        #expect(restarted.devices.count == 2)
        self.collect(
            on: restarted,
            event: nil,
            tokens: 0)
        await restarted.syncNow()
        #expect(restarted.snapshots[.codex]?.sessionTokens == 300)

        await fixture.hub.setFailure(nil)
        await restarted.syncNow()
        #expect(restarted.snapshots[.codex]?.sessionTokens == 350)
        #expect(restarted.lastPublishedAt == Self.now)
        await restarted.syncNow()
        #expect(restarted.snapshots[.codex]?.sessionTokens == 350)
        #expect(restarted.issue == nil)
    }

    @Test func revokedCredentialRetainsCachedTotalsWithoutRevealingTheCredential() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        try await coordinator.connect(hub: fixture.connection)
        self.collect(
            on: coordinator,
            event: "saved",
            tokens: 100)
        await coordinator.syncNow()
        await fixture.hub.setFailure(.unauthorized)
        await coordinator.syncNow()

        #expect(coordinator.snapshots[.codex]?.sessionTokens == 100)
        #expect(coordinator.issue?.contains("access was rejected") == true)
        #expect(coordinator.isEnabled)
        #expect(!(coordinator.issue ?? "").contains(fixture.connection.credential))
        let preferences = String(describing: fixture.defaults.dictionaryRepresentation())
        #expect(!preferences.contains(fixture.connection.credential))
        let cache = try #require(String(
            bytes: Data(contentsOf: fixture.checkpoint),
            encoding: .utf8))
        #expect(!cache.contains(fixture.connection.credential))
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.connectionFile.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let restoredConnection = try MidasUsageHubConnectionFile.load(at: fixture.connectionFile)
        #expect(restoredConnection.deviceID == fixture.connection.deviceID)
    }

    @Test func changedWorkspaceIsRejectedBeforeItCanReplaceCombinedTotals() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        try await coordinator.connect(hub: fixture.connection)
        self.collect(
            on: coordinator,
            event: "saved",
            tokens: 100)
        await coordinator.syncNow()
        let previousCache = try Data(contentsOf: fixture.checkpoint)
        await fixture.hub.replaceWorkspace(MidasUsageSyncWorkspace(
            id: fixture.workspace.id,
            createdAt: Self.now))
        await coordinator.syncNow()

        #expect(!coordinator.isEnabled)
        #expect(!coordinator.hasConnection)
        #expect(coordinator.snapshots.isEmpty)
        #expect(coordinator.issue?.contains("workspace changed") == true)
        // The last received ledger is not replaced by the untrusted response.
        #expect(try Data(contentsOf: fixture.checkpoint) == previousCache)
        let restarted = fixture.coordinator()
        await #expect(throws: MidasUsageSyncError.wrongWorkspace) {
            try await restarted.connect(hub: fixture.connection)
        }
        #expect(!restarted.isEnabled)
    }

    @Test func mismatchedEnrollmentWorkspaceDoesNotCreateAPrivateConnection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let connection = MidasUsageHubConnection(
            endpoint: fixture.connection.endpoint,
            deviceID: fixture.connection.deviceID,
            deviceName: fixture.connection.deviceName,
            credential: fixture.connection.credential,
            workspaceID: UUID())
        let coordinator = fixture.coordinator()
        await #expect(throws: MidasUsageSyncError.wrongWorkspace) { try await coordinator.connect(hub: connection) }
        #expect(!coordinator.hasConnection)
        #expect(!FileManager.default.fileExists(atPath: fixture.connectionFile.path))
    }

    @Test func importingAReplacementCredentialKeepsTheSameLedgerAndProtectedFile() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        try await coordinator.connect(hub: fixture.connection)
        self.collect(
            on: coordinator,
            event: "saved",
            tokens: 100)
        await coordinator.syncNow()
        let replacement = MidasUsageHubConnection(
            endpoint: fixture.connection.endpoint,
            deviceID: fixture.connection.deviceID,
            deviceName: fixture.connection.deviceName,
            credential: String(
                repeating: "b",
                count: 48),
            workspaceID: fixture.workspace.id)
        try await coordinator.connect(hub: replacement)
        #expect(try MidasUsageHubConnectionFile.load(at: fixture.connectionFile) == replacement)
        self.collect(
            on: coordinator,
            event: nil,
            tokens: 0)
        await coordinator.syncNow()
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 100)
    }

    @Test func switchingTransportsRetainsSeparateOfflineOutboxes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = fixture.directory.appendingPathComponent(
            "shared",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: false)
        let coordinator = fixture.coordinator()
        try await coordinator.connect(folder: folder)
        self.collect(
            on: coordinator,
            event: "folder",
            tokens: 10)
        await coordinator.syncNow()
        try await coordinator.connect(hub: fixture.connection)
        self.collect(
            on: coordinator,
            event: "hub",
            tokens: 100)
        await coordinator.syncNow()
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 100)
        try await coordinator.connect(folder: folder)
        self.collect(
            on: coordinator,
            event: nil,
            tokens: 0)
        await coordinator.syncNow()
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 10)
    }

    @Test func changingTransportPreservesTheWorkingConnectionUntilReplacement() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let gate = Gate()
        let hub = fixture.hub
        let coordinator = fixture.coordinator(exchange: { connection, workspace, local, now in
            await gate.suspend()
            return try await hub.exchange(
                connection: connection,
                workspace: workspace,
                local: local,
                now: now)
        })
        try await coordinator.connect(hub: fixture.connection)
        self.collect(
            on: coordinator,
            event: "late",
            tokens: 100)
        let sync = Task { await coordinator.syncNow() }
        await gate.waitUntilBlocked()
        coordinator.selectTransport(.folder)
        await gate.release()
        await sync.value
        #expect(coordinator.transport == .tailscaleHub)
        #expect(coordinator.selectedTransport == .folder)
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 100)
        #expect(!coordinator.isSyncing)
        #expect(coordinator.isEnabled)
    }

    @Test func replacementDrainBlocksNewChecksUntilThePreviousWriterFinishes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        try await coordinator.connect(hub: fixture.connection)
        let gate = Gate()
        var collections = 0
        coordinator.makeLocalUsage = { workspace, now in
            collections += 1
            await gate.suspend()
            return MidasUsageSyncLocalUsage(events: [Self.event(
                workspace: workspace,
                name: "retained",
                tokens: 100,
                now: now)])
        }
        let oldSync = Task { await coordinator.syncNow() }
        await gate.waitUntilBlocked()
        let replacement = Task { try await coordinator.connect(hub: fixture.connection) }
        for _ in 0..<1000 {
            if coordinator.isReplacingConnection { break }
            await Task.yield()
        }
        #expect(coordinator.isReplacingConnection)
        let readsBefore = await fixture.hub.readRequests
        await coordinator.syncNow()
        #expect(await fixture.hub.readRequests == readsBefore)
        #expect(collections == 1)
        await gate.release()
        await oldSync.value
        try await replacement.value
        #expect(!coordinator.isReplacingConnection)
        #expect(coordinator.hasConnection)
        await coordinator.syncNow()
        #expect(collections == 2)
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 100)
    }

    @Test func connectionFileImportCopiesTheEnrollmentToPrivateLocalStorage() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let imported = fixture.directory.appendingPathComponent("enrollment.json")
        try MidasUsageHubConnectionFile.save(
            fixture.connection,
            to: imported)
        let coordinator = fixture.coordinator()
        try await coordinator.connect(hubConnectionFile: imported)
        #expect(coordinator.hasConnection)
        #expect(try MidasUsageHubConnectionFile.load(at: imported) ==
            MidasUsageHubConnectionFile.load(at: fixture.connectionFile))
        let restored = fixture.coordinator(restore: true)
        #expect(restored.hubEndpoint == fixture.connection.endpoint)
        #expect(restored.hasConnection)
    }

    @Test func installedConnectionBootstrapsWithoutACacheOrICloud() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.installConnection()
        let coordinator = fixture.coordinator(
            restore: true,
            identity: Identity(cloudAccountFingerprint: "identity-unavailable"))
        self.collect(
            on: coordinator,
            event: "installed",
            tokens: 100)
        #expect(coordinator.hasConnection)
        #expect(!FileManager.default.fileExists(atPath: fixture.hubCache.path))
        await coordinator.syncNow()
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 100)
        #expect(coordinator.lastPublishedAt == Self.now)
        #expect(coordinator.issue == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.checkpoint.path))
        let restarted = fixture.coordinator(restore: true)
        #expect(restarted.snapshots[.codex]?.sessionTokens == 100)
    }

    @Test func installedConnectionWaitsOfflineThenBootstrapsOnRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.installConnection()
        await fixture.hub.setFailure(.unavailable)
        let coordinator = fixture.coordinator(restore: true)
        var collections = 0
        coordinator.makeLocalUsage = { _, _ in collections += 1; return MidasUsageSyncLocalUsage() }
        await coordinator.syncNow()
        #expect(coordinator.isEnabled)
        #expect(coordinator.hasConnection)
        #expect(collections == 0)
        #expect(coordinator.snapshots.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.hubCache.path))
        #expect(coordinator.status.contains("retry automatically"))
        await fixture.hub.setFailure(nil)
        self.collect(
            on: coordinator,
            event: "retry",
            tokens: 50)
        await coordinator.syncNow()
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 50)
        #expect(coordinator.issue == nil)
    }

    @Test func corruptPeerCacheRebuildsWithoutReenrollmentAndKeepsOriginalBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.installConnection()
        let corrupt = Data("invalid saved ledger".utf8)
        try corrupt.write(to: fixture.hubCache)
        let coordinator = fixture.coordinator(restore: true)
        await coordinator.syncNow()
        #expect(coordinator.hasConnection)
        #expect(coordinator.issue == nil)
        #expect(try Data(contentsOf: fixture.hubCache) == corrupt)
        #expect(FileManager.default.fileExists(atPath: fixture.checkpoint.path))
        let saved = try #require(JSONSerialization
            .jsonObject(with: Data(contentsOf: fixture.checkpoint)) as? [String: Any])
        var mismatched = saved
        mismatched["accountFingerprint"] = "another enrollment"
        let encoded = try JSONSerialization.data(withJSONObject: mismatched)
        try encoded.write(to: fixture.checkpoint)
        let requestsBeforeRestore = await fixture.hub.workspaceRequests
        let restarted = fixture.coordinator(restore: true)
        await restarted.syncNow()
        #expect(!restarted.hasConnection)
        #expect(try Data(contentsOf: fixture.checkpoint) == encoded)
        let requestsAfterRestore = await fixture.hub.workspaceRequests
        #expect(requestsAfterRestore == requestsBeforeRestore)
    }

    @Test func unchangedHealthyCheckAdvancesFreshnessWithoutRewritingCheckpoint() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        try await coordinator.connect(hub: fixture.connection)
        self.collect(
            on: coordinator,
            event: "stable",
            tokens: 100)
        await coordinator.syncNow()
        let checkpoint = try Data(contentsOf: fixture.checkpoint)
        let before = try FileManager.default
            .attributesOfItem(atPath: fixture.checkpoint.path)[.modificationDate] as? Date
        coordinator.makeLocalUsage = nil
        await coordinator.syncNow()
        #expect(coordinator.lastCheckedAt == Self.now)
        #expect(try Data(contentsOf: fixture.checkpoint) == checkpoint)
        let after = try FileManager.default
            .attributesOfItem(atPath: fixture.checkpoint.path)[.modificationDate] as? Date
        #expect(before == after)
    }

    @Test func failedCheckpointCannotAcknowledgeAnUnchangedRetryUntilItIsDurable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let writes = CacheWriteControl()
        let receipts = ReceiptCounter()
        let hub = fixture.hub
        let coordinator = fixture.coordinator(
            exchange: { connection, workspace, local, now in
                let result = try await hub.exchange(
                    connection: connection,
                    workspace: workspace,
                    local: local,
                    now: now)
                return MidasUsageHubExchange(
                    workspace: result.workspace,
                    publications: result.publications,
                    publicationSucceeded: result.publicationSucceeded,
                    unavailableFiles: 0,
                    rejectedFiles: 0,
                    syncState: MidasUsageHubSyncState(
                        checkedAt: now,
                        appliedRevisions: [connection.deviceID
                            .uuidString: result.publications.count]))
            },
            acknowledge: { _, _, _ in await receipts.record(); return [] },
            cacheWriter: { data, url in
                try writes.write(
                    data,
                    to: url)
            })
        try await coordinator.connect(hub: fixture.connection)
        self.collect(
            on: coordinator,
            event: "local",
            tokens: 100)
        await coordinator.syncNow()
        coordinator.makeLocalUsage = nil
        let before = await receipts.count
        await fixture.hub.setPublications([self.publication(
            workspace: fixture.workspace,
            deviceID: UUID(),
            event: "new-peer",
            tokens: 400)])
        writes.setFailure(true)
        await coordinator.syncNow()
        #expect(await receipts.count == before)
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 100)
        writes.setFailure(false)
        await coordinator.syncNow()
        #expect(await receipts.count == before + 1)
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 500)
        let restarted = fixture.coordinator(restore: true)
        #expect(restarted.snapshots[.codex]?.sessionTokens == 500)
    }

    @Test func firstSyncReceivesExistingTotalsBeforeTheSlowLocalScan() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let peer = self.publication(
            workspace: fixture.workspace,
            deviceID: UUID(),
            event: "peer",
            tokens: 200)
        await fixture.hub.setPublications([peer])
        let coordinator = fixture.coordinator()
        try await coordinator.connect(hub: fixture.connection)
        let gate = Gate()
        coordinator.makeLocalUsage = { workspace, now in
            await gate.suspend()
            return MidasUsageSyncLocalUsage(events: [Self.event(
                workspace: workspace,
                name: "mini",
                tokens: 100,
                now: now)])
        }
        let sync = Task { await coordinator.syncNow() }
        await gate.waitUntilBlocked()
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 200)
        #expect(coordinator.lastPublishedAt == nil)
        #expect(coordinator.lastReceivedAt == Self.now)
        #expect(coordinator.devices.count == 1)
        await gate.release()
        await sync.value
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 300)
        #expect(coordinator.lastPublishedAt == Self.now)
        self.collect(
            on: coordinator,
            event: nil,
            tokens: 0)
        await coordinator.syncNow()
        let reads = await fixture.hub.readRequests
        #expect(reads == 2)
    }

    @Test func readOnlyAcknowledgementIsRejectedWhileLocalCollectionContinues() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let peer = self.publication(
            workspace: fixture.workspace,
            deviceID: UUID(),
            event: "peer",
            tokens: 900)
        let hub = fixture.hub
        let coordinator = fixture.coordinator(exchange: { connection, workspace, local, now in
            if local == nil {
                return MidasUsageHubExchange(
                    workspace: workspace,
                    publications: [peer],
                    publicationSucceeded: true,
                    unavailableFiles: 0,
                    rejectedFiles: 0)
            }
            return try await hub.exchange(
                connection: connection,
                workspace: workspace,
                local: local,
                now: now)
        })
        try await coordinator.connect(hub: fixture.connection)
        self.collect(
            on: coordinator,
            event: "mini",
            tokens: 100)
        await coordinator.syncNow()
        #expect(coordinator.snapshots.isEmpty)
        #expect(coordinator.devices.isEmpty)
        #expect(coordinator.lastReceivedAt == nil)
        #expect(coordinator.lastPublishedAt == nil)
        #expect(coordinator.hasPendingUpload)
    }

    @Test func failedColdReadNeverAcknowledgesOrDiscardsTheOfflineOutbox() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        try await coordinator.connect(hub: fixture.connection)
        await fixture.hub.setFailure(.unavailable)
        self.collect(
            on: coordinator,
            event: "offline",
            tokens: 100)
        await coordinator.syncNow()
        struct SavedOutbox: Decodable { let revision: String; let pending: Bool }
        let outboxURL = fixture.directory.appendingPathComponent("hub-outbox.json")
        let before = try JSONDecoder().decode(SavedOutbox.self, from: Data(contentsOf: outboxURL))
        #expect(before.pending)
        let store = try MidasUsageCanonicalStore(root: fixture.directory.appendingPathComponent("hub-outbox-records"))
        let pending = try store.load(
            workspaceID: fixture.workspace.id,
            deviceID: fixture.connection.deviceID,
            revision: before.revision,
            now: Self.now)
        #expect(pending?.events.count == 1)
        let restarted = fixture.coordinator(restore: true)
        restarted.makeLocalUsage = { _, _ in throw CancellationError() }
        await restarted.syncNow()
        let after = try JSONDecoder().decode(SavedOutbox.self, from: Data(contentsOf: outboxURL))
        #expect(after.revision == before.revision)
        #expect(after.pending)
        #expect(restarted.lastPublishedAt == nil)
        #expect(restarted.snapshots.isEmpty)
    }

    private func collect(
        on coordinator: MidasUsageSyncCoordinator,
        event: String?,
        tokens: Int)
    {
        coordinator.makeLocalUsage = { workspace, now in
            guard let event else { return MidasUsageSyncLocalUsage() }
            return MidasUsageSyncLocalUsage(events: [Self.event(
                workspace: workspace,
                name: event,
                tokens: tokens,
                now: now)])
        }
    }

    private static func event(
        workspace: MidasUsageSyncWorkspace,
        name: String,
        tokens: Int,
        now: Date) -> MidasUsageSyncEvent
    {
        MidasUsageSyncEvent(
            id: workspace.opaqueID(
                provider: .codex,
                components: ["synthetic", name]),
            provider: .codex,
            day: MidasUsageSyncPublication.day(now),
            observedAt: now,
            values: .init(
                tokens: tokens,
                costUSD: 1))
    }

    private func publication(
        workspace: MidasUsageSyncWorkspace,
        deviceID: UUID,
        event: String,
        tokens: Int) -> MidasUsageSyncPublication
    {
        MidasUsageSyncPublication(
            workspaceID: workspace.id,
            deviceID: deviceID,
            deviceName: "Spark",
            publishedAt: Self.now,
            events: [Self.event(
                workspace: workspace,
                name: event,
                tokens: tokens,
                now: Self.now)])
    }

    @MainActor
    private final class Identity {
        var value: MidasUsageSyncEnvironmentIdentity

        init(cloudAccountFingerprint: String = "no-icloud-account") {
            self.value = .init(
                deviceBinding: "synthetic-mini",
                cloudAccountFingerprint: cloudAccountFingerprint)
        }
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let cache: URL
        let hubCache: URL
        var checkpoint: URL {
            self.directory.appendingPathComponent("hub-checkpoint-v2.json")
        }

        let connectionFile: URL
        let suite: String
        let defaults: UserDefaults
        let workspace: MidasUsageSyncWorkspace
        let connection: MidasUsageHubConnection
        let hub: Hub

        init() throws {
            self.suite = "MidasHubCoordinatorTests-" + UUID().uuidString
            self.defaults = try #require(UserDefaults(suiteName: self.suite))
            guard let path = Darwin.realpath(FileManager.default.temporaryDirectory.path, nil) else {
                throw POSIXError(.ENOENT)
            }
            defer { Darwin.free(path) }
            self.directory = URL(
                fileURLWithPath: String(cString: path),
                isDirectory: true)
                .appendingPathComponent(
                    self.suite,
                    isDirectory: true)
            try FileManager.default.createDirectory(
                at: self.directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            self.cache = self.directory.appendingPathComponent("state.json")
            self.hubCache = self.directory.appendingPathComponent("hub-state.json")
            self.connectionFile = self.directory.appendingPathComponent("hub-connection.json")
            self.workspace = MidasUsageSyncWorkspace(createdAt: MidasHubCoordinatorTests.now)
            self.connection = MidasUsageHubConnection(
                endpoint: URL(string: "https://mini.synthetic.ts.net")!,
                deviceID: UUID(),
                deviceName: "Mac mini",
                credential: String(
                    repeating: "a",
                    count: 48),
                workspaceID: self.workspace.id)
            self.hub = Hub(workspace: self.workspace)
        }

        func coordinator(
            restore: Bool = false,
            identity: Identity = Identity(),
            exchange: (@Sendable (
                MidasUsageHubConnection, MidasUsageSyncWorkspace, MidasUsageSyncPublication?,
                Date) async throws -> MidasUsageHubExchange)? = nil,
            acknowledge: @escaping @Sendable (
                MidasUsageHubConnection,
                MidasUsageSyncWorkspace,
                MidasUsageHubSyncState) async throws
                -> [MidasUsageHubPeerReceipt] = { _, _, _ in [] },
            cacheWriter: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1) })
            -> MidasUsageSyncCoordinator
        {
            let hub = self.hub
            return MidasUsageSyncCoordinator(
                defaults: self.defaults,
                persistenceURL: self.cache,
                automaticallySyncs: false,
                environmentIdentity: { identity.value },
                restoresConnection: restore,
                hubConnectionURL: self.connectionFile,
                hubWorkspaceLoader: { _ in try await hub.loadWorkspace() },
                hubExchange: exchange ?? { connection, workspace, local, now in
                    try await hub.exchange(
                        connection: connection,
                        workspace: workspace,
                        local: local,
                        now: now)
                },
                hubAcknowledge: acknowledge,
                currentTime: { MidasHubCoordinatorTests.now },
                cacheWriter: cacheWriter)
        }

        func installConnection() throws {
            try MidasUsageHubConnectionFile.save(
                self.connection,
                to: self.connectionFile)
            self.defaults.set(
                MidasUsageSyncTransport.tailscaleHub.rawValue,
                forKey: "midasUsageSyncTransport")
            self.defaults.set(
                true,
                forKey: "midasUsageSyncEnabled")
        }

        func cleanup() {
            self.defaults.removePersistentDomain(forName: self.suite)
            try? FileManager.default.removeItem(at: self.directory)
        }
    }

    private final class CacheWriteControl: @unchecked Sendable {
        private let lock = NSLock()
        private var failing = false
        func setFailure(_ failing: Bool) {
            self.lock.withLock { self.failing = failing }
        }

        func write(_ data: Data, to url: URL) throws {
            try self.lock.withLock {
                if self.failing { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: url)
            }
        }
    }

    private actor ReceiptCounter {
        private(set) var count = 0
        func record() {
            self.count += 1
        }
    }

    private actor Gate {
        private var blocked = false
        private var released = false
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private var observer: CheckedContinuation<Void, Never>?

        func suspend() async {
            if self.released { return }
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
            self.released = true
            self.releaseContinuation?.resume()
            self.releaseContinuation = nil
        }
    }

    private actor Hub {
        var workspace: MidasUsageSyncWorkspace
        private var publications: [MidasUsageSyncPublication] = []
        private var failure: MidasUsageHubError?
        private(set) var workspaceRequests = 0
        private(set) var readRequests = 0

        func loadWorkspace() throws -> MidasUsageSyncWorkspace {
            self.workspaceRequests += 1
            if let failure { throw failure }
            return self.workspace
        }

        init(workspace: MidasUsageSyncWorkspace) {
            self.workspace = workspace
        }

        func setFailure(_ failure: MidasUsageHubError?) {
            self.failure = failure
        }

        func replaceWorkspace(_ workspace: MidasUsageSyncWorkspace) {
            self.workspace = workspace
        }

        func setPublications(_ publications: [MidasUsageSyncPublication]) {
            self.publications = publications
        }

        func exchange(
            connection: MidasUsageHubConnection,
            workspace: MidasUsageSyncWorkspace,
            local: MidasUsageSyncPublication?,
            now: Date) throws -> MidasUsageHubExchange
        {
            if let failure { throw failure }
            if let local {
                try local.validate(
                    workspaceID: workspace.id,
                    now: now)
                #expect(local.deviceID == connection.deviceID)
                #expect(local.deviceName == connection.deviceName)
                self.publications.removeAll { $0.deviceID == local.deviceID }
                self.publications.append(local)
            } else {
                self.readRequests += 1
            }
            return MidasUsageHubExchange(
                workspace: self.workspace,
                publications: self.publications,
                publicationSucceeded: local != nil,
                unavailableFiles: 0,
                rejectedFiles: 0)
        }
    }
}
