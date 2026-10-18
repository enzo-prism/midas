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
        self.collect(on: coordinator, event: "mini", tokens: 100)
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
        let restarted = fixture.coordinator(restore: true, identity: identity)
        #expect(restarted.isEnabled)
        #expect(restarted.hasConnection)
        #expect(restarted.snapshots[.codex]?.sessionTokens == 100)
    }

    @Test func offlineOutboxAndReceivedHistorySurviveRestartThenConverge() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let peer = self.publication(workspace: fixture.workspace, deviceID: UUID(), event: "spark", tokens: 200)
        await fixture.hub.setPublications([peer])
        let coordinator = fixture.coordinator()
        try await coordinator.connect(hub: fixture.connection)
        self.collect(on: coordinator, event: "first", tokens: 100)
        await coordinator.syncNow()
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 300)

        await fixture.hub.setFailure(.unavailable)
        self.collect(on: coordinator, event: "offline", tokens: 50)
        await coordinator.syncNow()
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 300)
        #expect(coordinator.status.contains("last received"))
        let restarted = fixture.coordinator(restore: true)
        #expect(restarted.hasConnection)
        #expect(restarted.snapshots[.codex]?.sessionTokens == 300)
        #expect(restarted.devices.count == 2)
        self.collect(on: restarted, event: nil, tokens: 0)
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
        self.collect(on: coordinator, event: "saved", tokens: 100)
        await coordinator.syncNow()
        await fixture.hub.setFailure(.unauthorized)
        await coordinator.syncNow()

        #expect(coordinator.snapshots[.codex]?.sessionTokens == 100)
        #expect(coordinator.issue?.contains("access was rejected") == true)
        #expect(coordinator.isEnabled)
        #expect(!(coordinator.issue ?? "").contains(fixture.connection.credential))
        let preferences = String(describing: fixture.defaults.dictionaryRepresentation())
        #expect(!preferences.contains(fixture.connection.credential))
        let cache = try #require(String(bytes: Data(contentsOf: fixture.hubCache), encoding: .utf8))
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
        self.collect(on: coordinator, event: "saved", tokens: 100)
        await coordinator.syncNow()
        let previousCache = try Data(contentsOf: fixture.hubCache)
        await fixture.hub.replaceWorkspace(MidasUsageSyncWorkspace(id: fixture.workspace.id, createdAt: Self.now))
        await coordinator.syncNow()

        #expect(!coordinator.isEnabled)
        #expect(!coordinator.hasConnection)
        #expect(coordinator.snapshots.isEmpty)
        #expect(coordinator.issue?.contains("workspace changed") == true)
        // The last received ledger is not replaced by the untrusted response.
        struct SavedLedger: Decodable { let publications: [MidasUsageSyncPublication] }
        let cache = try JSONDecoder().decode(SavedLedger.self, from: Data(contentsOf: fixture.hubCache))
        let previous = try JSONDecoder().decode(SavedLedger.self, from: previousCache)
        #expect(cache.publications == previous.publications)
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
        self.collect(on: coordinator, event: "saved", tokens: 100)
        await coordinator.syncNow()
        let replacement = MidasUsageHubConnection(
            endpoint: fixture.connection.endpoint,
            deviceID: fixture.connection.deviceID,
            deviceName: fixture.connection.deviceName,
            credential: String(repeating: "b", count: 48),
            workspaceID: fixture.workspace.id)
        try await coordinator.connect(hub: replacement)
        #expect(try MidasUsageHubConnectionFile.load(at: fixture.connectionFile) == replacement)
        self.collect(on: coordinator, event: nil, tokens: 0)
        await coordinator.syncNow()
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 100)
    }

    @Test func switchingTransportsRetainsSeparateOfflineOutboxes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = fixture.directory.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let coordinator = fixture.coordinator()
        try await coordinator.connect(folder: folder)
        self.collect(on: coordinator, event: "folder", tokens: 10)
        await coordinator.syncNow()
        try await coordinator.connect(hub: fixture.connection)
        self.collect(on: coordinator, event: "hub", tokens: 100)
        await coordinator.syncNow()
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 100)
        try await coordinator.connect(folder: folder)
        self.collect(on: coordinator, event: nil, tokens: 0)
        await coordinator.syncNow()
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 10)
    }

    @Test func changingTransportRejectsALateHubResponse() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let gate = Gate()
        let hub = fixture.hub
        let coordinator = fixture.coordinator(exchange: { connection, workspace, local, now in
            await gate.suspend()
            return try await hub.exchange(connection: connection, workspace: workspace, local: local, now: now)
        })
        try await coordinator.connect(hub: fixture.connection)
        self.collect(on: coordinator, event: "late", tokens: 100)
        let sync = Task { await coordinator.syncNow() }
        await gate.waitUntilBlocked()
        coordinator.selectTransport(.folder)
        await gate.release()
        await sync.value
        #expect(coordinator.transport == .folder)
        #expect(coordinator.snapshots.isEmpty)
        #expect(!coordinator.isSyncing)
        #expect(!coordinator.isEnabled)
    }

    @Test func connectionFileImportCopiesTheEnrollmentToPrivateLocalStorage() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let imported = fixture.directory.appendingPathComponent("enrollment.json")
        try MidasUsageHubConnectionFile.save(fixture.connection, to: imported)
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
            restore: true, identity: Identity(cloudAccountFingerprint: "identity-unavailable"))
        self.collect(on: coordinator, event: "installed", tokens: 100)
        #expect(coordinator.hasConnection)
        #expect(!FileManager.default.fileExists(atPath: fixture.hubCache.path))
        await coordinator.syncNow()
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 100)
        #expect(coordinator.lastPublishedAt == Self.now)
        #expect(coordinator.issue == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.hubCache.path))
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
        self.collect(on: coordinator, event: "retry", tokens: 50)
        await coordinator.syncNow()
        #expect(coordinator.snapshots[.codex]?.sessionTokens == 50)
        #expect(coordinator.issue == nil)
    }

    @Test func installedConnectionNeverBootstrapsOverACorruptOrMismatchedCache() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.installConnection()
        let corrupt = Data("invalid saved ledger".utf8)
        try corrupt.write(to: fixture.hubCache)
        let coordinator = fixture.coordinator(restore: true)
        await coordinator.syncNow()
        #expect(!coordinator.hasConnection)
        #expect(coordinator.issue?.contains("could not be validated") == true)
        #expect(try Data(contentsOf: fixture.hubCache) == corrupt)
        let firstRequests = await fixture.hub.workspaceRequests
        #expect(firstRequests == 0)

        try FileManager.default.removeItem(at: fixture.hubCache)
        try await coordinator.connect(hub: fixture.connection)
        let saved = try #require(JSONSerialization
            .jsonObject(with: Data(contentsOf: fixture.hubCache)) as? [String: Any])
        var mismatched = saved
        mismatched["accountFingerprint"] = "another enrollment"
        let encoded = try JSONSerialization.data(withJSONObject: mismatched)
        try encoded.write(to: fixture.hubCache)
        let requestsBeforeRestore = await fixture.hub.workspaceRequests
        let restarted = fixture.coordinator(restore: true)
        await restarted.syncNow()
        #expect(!restarted.hasConnection)
        #expect(try Data(contentsOf: fixture.hubCache) == encoded)
        let requestsAfterRestore = await fixture.hub.workspaceRequests
        #expect(requestsAfterRestore == requestsBeforeRestore)
    }

    private func collect(on coordinator: MidasUsageSyncCoordinator, event: String?, tokens: Int) {
        coordinator.makeLocalUsage = { workspace, now in
            guard let event else { return MidasUsageSyncLocalUsage() }
            return MidasUsageSyncLocalUsage(events: [Self.event(
                workspace: workspace, name: event, tokens: tokens, now: now)])
        }
    }

    private static func event(
        workspace: MidasUsageSyncWorkspace, name: String, tokens: Int, now: Date) -> MidasUsageSyncEvent
    {
        MidasUsageSyncEvent(
            id: workspace.opaqueID(provider: .codex, components: ["synthetic", name]),
            provider: .codex,
            day: MidasUsageSyncPublication.day(now),
            observedAt: now,
            values: .init(tokens: tokens, costUSD: 1))
    }

    private func publication(
        workspace: MidasUsageSyncWorkspace, deviceID: UUID, event: String, tokens: Int) -> MidasUsageSyncPublication
    {
        MidasUsageSyncPublication(
            workspaceID: workspace.id,
            deviceID: deviceID,
            deviceName: "Spark",
            publishedAt: Self.now,
            events: [Self.event(workspace: workspace, name: event, tokens: tokens, now: Self.now)])
    }

    @MainActor
    private final class Identity {
        var value: MidasUsageSyncEnvironmentIdentity

        init(cloudAccountFingerprint: String = "no-icloud-account") {
            self.value = .init(deviceBinding: "synthetic-mini", cloudAccountFingerprint: cloudAccountFingerprint)
        }
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let cache: URL
        let hubCache: URL
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
            self.directory = URL(fileURLWithPath: String(cString: path), isDirectory: true)
                .appendingPathComponent(self.suite, isDirectory: true)
            try FileManager.default.createDirectory(
                at: self.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            self.cache = self.directory.appendingPathComponent("state.json")
            self.hubCache = self.directory.appendingPathComponent("hub-state.json")
            self.connectionFile = self.directory.appendingPathComponent("hub-connection.json")
            self.workspace = MidasUsageSyncWorkspace(createdAt: MidasHubCoordinatorTests.now)
            self.connection = MidasUsageHubConnection(
                endpoint: URL(string: "https://mini.synthetic.ts.net")!,
                deviceID: UUID(),
                deviceName: "Mac mini",
                credential: String(repeating: "a", count: 48),
                workspaceID: self.workspace.id)
            self.hub = Hub(workspace: self.workspace)
        }

        func coordinator(
            restore: Bool = false,
            identity: Identity = Identity(),
            exchange: (@Sendable (
                MidasUsageHubConnection, MidasUsageSyncWorkspace, MidasUsageSyncPublication,
                Date) async throws -> MidasUsageHubExchange)? = nil) -> MidasUsageSyncCoordinator
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
                    try await hub.exchange(connection: connection, workspace: workspace, local: local, now: now)
                },
                currentTime: { MidasHubCoordinatorTests.now })
        }

        func installConnection() throws {
            try MidasUsageHubConnectionFile.save(self.connection, to: self.connectionFile)
            self.defaults.set(MidasUsageSyncTransport.tailscaleHub.rawValue, forKey: "midasUsageSyncTransport")
            self.defaults.set(true, forKey: "midasUsageSyncEnabled")
        }

        func cleanup() {
            self.defaults.removePersistentDomain(forName: self.suite)
            try? FileManager.default.removeItem(at: self.directory)
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

    private actor Hub {
        var workspace: MidasUsageSyncWorkspace
        private var publications: [MidasUsageSyncPublication] = []
        private var failure: MidasUsageHubError?
        private(set) var workspaceRequests = 0

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
            local: MidasUsageSyncPublication,
            now: Date) throws -> MidasUsageHubExchange
        {
            if let failure { throw failure }
            try local.validate(workspaceID: workspace.id, now: now)
            #expect(local.deviceID == connection.deviceID)
            #expect(local.deviceName == connection.deviceName)
            self.publications.removeAll { $0.deviceID == local.deviceID }
            self.publications.append(local)
            return MidasUsageHubExchange(
                workspace: self.workspace,
                publications: self.publications,
                publicationSucceeded: true,
                unavailableFiles: 0,
                rejectedFiles: 0)
        }
    }
}
