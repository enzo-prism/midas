import AppKit
import CodexBarCore
import CryptoKit
import Darwin
import Foundation
import Network
import Observation

enum MidasUsageSyncTransport: String, CaseIterable, Identifiable {
    case folder
    case tailscaleHub

    var id: String {
        self.rawValue
    }

    var title: String {
        switch self {
        case .folder: "Shared folder"
        case .tailscaleHub: "Tailscale hub"
        }
    }
}

struct MidasUsageSyncDeviceStatus: Identifiable, Equatable {
    let id: UUID
    let name: String
    let lastSeenAt: Date
    let isThisMac: Bool
    let eventCount: Int
    var lastContactAt: Date?
    var hasAppliedLatest: Bool?
}

struct MidasUsageSyncLocalUsage: Sendable {
    var events: [MidasUsageSyncEvent] = []
    var accountDays: [MidasUsageSyncAccountDay] = []
    var excludedRecords = 0
}

/// Owns explicit opt-in, an offline outbox and the received numeric view. Provider authentication stays elsewhere.
@MainActor
@Observable
final class MidasUsageSyncCoordinator {
    var isEnabled: Bool {
        didSet {
            self.defaults.set(
                self.isEnabled,
                forKey: "midasUsageSyncEnabled")
            if self.isEnabled { self.scheduleSync() } else {
                self.connectionAttemptID = nil
                self.pause()
            }
        }
    }

    var includesSyncedUsage: Bool {
        didSet { self.defaults.set(
            self.includesSyncedUsage,
            forKey: "midasUsageSyncIncludeTotals") }
    }

    var deviceName: String {
        didSet { self.defaults.set(
            self.deviceName,
            forKey: "midasUsageSyncDeviceName") }
    }

    private(set) var transport: MidasUsageSyncTransport
    var folderURL: URL?
    var hubEndpoint: URL? {
        self.hubConnection?.endpoint
    }

    var hasConnection: Bool {
        switch self.transport {
        case .folder: self.folderURL != nil
        case .tailscaleHub: self.hubConnection != nil
        }
    }

    var status = "Sync is off."
    /// Transport/storage failures are independent from incomplete source coverage.
    var issue: String?
    var coverageIssue: String?
    var phase: MidasUsageSyncPhase = .idle
    var lastCheckedAt: Date?
    var lastCollectedAt: Date?
    var lastAppliedAt: Date?
    var nextRetryAt: Date?
    var hubSyncState: MidasUsageHubSyncState?
    var peerReceipts: [MidasUsageHubPeerReceipt] = []
    var hasPendingUpload: Bool {
        self.pendingLocal != nil || self.outboxRequiresRepair
    }

    var outboxRequiresRepair: Bool {
        self.transport == .tailscaleHub && self.criticalOutboxNeedsRepair
    }

    var isSyncing = false
    var lastPublishedAt: Date?
    var lastReceivedAt: Date?
    var devices: [MidasUsageSyncDeviceStatus] = []
    var snapshots: [UsageProvider: CostUsageTokenSnapshot] = [:]
    @ObservationIgnored var makeLocalUsage: ((MidasUsageSyncWorkspace, Date) async throws -> MidasUsageSyncLocalUsage)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let persistenceURL: URL?
    @ObservationIgnored private let automaticallySyncs: Bool
    @ObservationIgnored private let deviceID: UUID
    @ObservationIgnored private let environmentIdentity: @MainActor () -> MidasUsageSyncEnvironmentIdentity
    @ObservationIgnored private let workspaceLoader: @Sendable (URL) async throws -> MidasUsageSyncWorkspace
    @ObservationIgnored private let exchangePublication: @Sendable (
        URL, MidasUsageSyncWorkspace, MidasUsageSyncPublication, Date) async throws -> MidasUsageSyncFolder.Result
    @ObservationIgnored private let hubConnectionURL: URL
    @ObservationIgnored private let hubWorkspaceLoader: @Sendable (
        MidasUsageHubConnection) async throws -> MidasUsageSyncWorkspace
    @ObservationIgnored private let hubExchange: @Sendable (
        MidasUsageHubConnection, MidasUsageSyncWorkspace, MidasUsageSyncPublication?,
        Date) async throws -> MidasUsageHubExchange
    private var hubConnection: MidasUsageHubConnection?
    /// The identity this Mac publishes under; its day rollups are keyed to it.
    var syncStatusNow: Date {
        self.currentTime()
    }

    var isReplacingConnection: Bool {
        self.connectionDrainID != nil
    }

    var syncDeviceID: UUID {
        self.hubConnection?.deviceID ?? self.deviceID
    }

    private var cacheURL: URL? {
        guard let persistenceURL = self.persistenceURL else { return nil }
        return self.transport == .folder ? persistenceURL : persistenceURL
            .deletingLastPathComponent().appendingPathComponent("hub-state.json")
    }

    @ObservationIgnored private let currentTime: @MainActor () -> Date
    @ObservationIgnored private let deviceBinding: String?
    @ObservationIgnored private var accountFingerprint: String?
    @ObservationIgnored private var workspace: MidasUsageSyncWorkspace?
    @ObservationIgnored private var received: [MidasUsageSyncPublication] = []
    @ObservationIgnored private var pendingLocal: MidasUsageSyncPublication?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var activeSync: Task<Void, Never>?
    @ObservationIgnored private var activeSyncID: UUID?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var accountObservation: MidasSyncAccountObservation?
    @ObservationIgnored private let worker: Worker
    @ObservationIgnored private let hubAcknowledge: @Sendable (
        MidasUsageHubConnection, MidasUsageSyncWorkspace, MidasUsageHubSyncState) async throws -> [
        MidasUsageHubPeerReceipt
    ]
    @ObservationIgnored private var recoveryObservation: MidasSyncRecoveryObservation?
    @ObservationIgnored private var dirtyWhileSyncing = false
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var recoveringPeerCache = false
    @ObservationIgnored private var stagedTransport: MidasUsageSyncTransport?
    @ObservationIgnored private var connectionAttemptID: UUID?
    @ObservationIgnored private var connectionDrainID: UUID?
    @ObservationIgnored private var connectionDrainingSync: Task<Void, Never>?
    @ObservationIgnored private var criticalOutboxNeedsRepair = false
    var selectedTransport: MidasUsageSyncTransport {
        self.stagedTransport ?? self.transport
    }

    init(
        defaults: UserDefaults = .standard,
        persistenceURL: URL? = nil,
        automaticallySyncs: Bool = true,
        environmentIdentity: (@MainActor () -> MidasUsageSyncEnvironmentIdentity)? = nil,
        restoresConnection: Bool? = nil,
        workspaceLoader: @escaping @Sendable (URL) async throws -> MidasUsageSyncWorkspace = {
            try await MidasUsageSyncFolder.workspace(at: $0)
        },
        exchangePublication: @escaping @Sendable (
            URL, MidasUsageSyncWorkspace, MidasUsageSyncPublication, Date) async throws -> MidasUsageSyncFolder
            .Result = {
                try await MidasUsageSyncFolder.exchange(
                    at: $0,
                    workspace: $1,
                    local: $2,
                    now: $3)
            },
        hubConnectionURL: URL? = nil,
        hubWorkspaceLoader: @escaping @Sendable (
            MidasUsageHubConnection) async throws -> MidasUsageSyncWorkspace = {
            try await MidasUsageHubClient.workspace(connection: $0)
        },
        hubExchange: @escaping @Sendable (
            MidasUsageHubConnection, MidasUsageSyncWorkspace, MidasUsageSyncPublication?,
            Date) async throws -> MidasUsageHubExchange = {
            try await MidasUsageHubClient.exchange(
                connection: $0,
                workspace: $1,
                local: $2,
                now: $3)
        },
        hubAcknowledge: @escaping @Sendable (
            MidasUsageHubConnection, MidasUsageSyncWorkspace, MidasUsageHubSyncState) async throws -> [
            MidasUsageHubPeerReceipt
        ] = {
            try await MidasUsageHubClient.acknowledgeApplied(
                connection: $0,
                workspace: $1,
                state: $2)
        },
        currentTime: @escaping @MainActor () -> Date = { Date() },
        cacheWriter: @escaping @Sendable (Data, URL) throws -> Void = { try LocalPersistence.write(
            $0,
            to: $1) })
    {
        self.defaults = defaults
        self.worker = Worker(write: cacheWriter)
        self.automaticallySyncs = automaticallySyncs
        let identityProvider: @MainActor () -> MidasUsageSyncEnvironmentIdentity = if let environmentIdentity {
            environmentIdentity
        } else if automaticallySyncs {
            { MidasUsageSyncEnvironmentIdentity.live() }
        } else {
            { MidasUsageSyncEnvironmentIdentity() }
        }
        self.environmentIdentity = identityProvider
        self.workspaceLoader = workspaceLoader
        self.exchangePublication = exchangePublication
        self.currentTime = currentTime
        self.hubWorkspaceLoader = hubWorkspaceLoader
        self.hubExchange = hubExchange
        self.hubAcknowledge = hubAcknowledge
        let identity = identityProvider()
        self.deviceBinding = identity.deviceBinding
        self.persistenceURL = persistenceURL ?? (automaticallySyncs ? Self.defaultPersistenceURL : nil)
        self.hubConnectionURL = hubConnectionURL ?? (persistenceURL ?? Self.defaultPersistenceURL)
            .deletingLastPathComponent().appendingPathComponent("hub-connection.json")
        self.transport = defaults.string(forKey: "midasUsageSyncTransport")
            .flatMap(MidasUsageSyncTransport.init(rawValue:)) ?? .folder
        self.isEnabled = defaults.bool(forKey: "midasUsageSyncEnabled")
        self.includesSyncedUsage = defaults.object(forKey: "midasUsageSyncIncludeTotals") as? Bool ?? true
        self.deviceName = defaults.string(forKey: "midasUsageSyncDeviceName") ?? "Mac"
        let previousID = defaults.string(forKey: "midasUsageSyncDeviceID").flatMap(UUID.init(uuidString:))
        let previousBinding = defaults.string(forKey: "midasUsageSyncDeviceBinding")
        let copiedIdentity = identity.deviceBinding.map { previousID != nil && previousBinding != $0 } ?? false
        self.deviceID = copiedIdentity ? UUID() : previousID ?? UUID()
        defaults.set(
            self.deviceID.uuidString,
            forKey: "midasUsageSyncDeviceID")
        if let binding = identity.deviceBinding { defaults.set(
            binding,
            forKey: "midasUsageSyncDeviceBinding") }
        // Test fixtures never resolve a live bookmark or read an app-support cache by default.
        if automaticallySyncs, identity.deviceBinding == nil {
            self
                .invalidateConnection(
                    message: self.transport == .folder
                        ? "This Mac’s sync identity is unavailable. Choose the folder again to reconnect."
                        : "This Mac’s sync identity is unavailable. Import its connection file again to reconnect.")
        } else if copiedIdentity, self.isEnabled {
            self
                .invalidateConnection(
                    message: self.transport == .folder
                        ? "This sync connection was copied from another Mac. Choose the folder again."
                        : "This sync connection was copied from another Mac. Import this Mac’s connection file.")
        } else if restoresConnection ?? automaticallySyncs {
            self.restoreConnection()
        }
        if automaticallySyncs {
            self.accountObservation = MidasSyncAccountObservation { [weak self] in
                Task { @MainActor [weak self] in self?.accountChanged() }
            }
            self.recoveryObservation = MidasSyncRecoveryObservation { [weak self] in
                Task { @MainActor [weak self] in self?.connectivityRecovered() }
            }
        }
    }

    deinit {
        self.operation?.cancel()
        self.activeSync?.cancel()
        self.poller?.cancel()
    }

    func start() {
        guard self.automaticallySyncs, self.poller == nil else { return }
        self.poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.nextRetryAt.map({ $0 <= self.currentTime() }) ?? true {
                    await self.syncNow(forceCollection: false)
                }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }

    func scheduleSync() {
        guard self.automaticallySyncs, self.isEnabled, !self.isReplacingConnection else { return }
        if self.activeSync != nil || self.operation != nil {
            self.dirtyWhileSyncing = true
            return
        }
        guard self.nextRetryAt.map({ $0 <= self.currentTime() }) ?? true else { return }
        let operationID = UUID()
        self.operationID = operationID
        self.operation = Task { [weak self] in
            defer {
                if self?.operationID == operationID {
                    self?.operation = nil
                    self?.operationID = nil
                }
            }
            await self?.syncNow(forceCollection: false)
            if self?.dirtyWhileSyncing == true {
                self?.dirtyWhileSyncing = false
                self?.operation = nil
                self?.operationID = nil
                self?.scheduleSync()
            }
        }
    }

    func selectTransport(_ selected: MidasUsageSyncTransport) {
        guard selected != self.selectedTransport else { return }
        if self.hasConnection {
            // A picker change is only a staged intent. Keep the working connection until
            // the replacement has authenticated and its workspace has been checked.
            self.stagedTransport = selected == self.transport ? nil : selected
            return
        }
        self.transport = selected
        self.stagedTransport = nil
        self.defaults.set(
            selected.rawValue,
            forKey: "midasUsageSyncTransport")
        self.status = selected == .folder ? "Choose a shared folder." : "Connect your Tailscale hub."
        self.issue = nil
    }

    func connect(hubConnectionFile file: URL) async throws {
        let connection = try MidasUsageHubConnectionFile.load(at: file)
        try await self.connect(hub: connection)
    }

    private func clearReceivedView() {
        self.received = []
        self.pendingLocal = nil
        self.snapshots = [:]
        self.devices = []
        self.lastPublishedAt = nil
        self.lastReceivedAt = nil
        self.lastCheckedAt = nil
        self.lastAppliedAt = nil
        self.lastCollectedAt = nil
        self.coverageIssue = nil
        self.hubSyncState = nil
        self.peerReceipts = []
    }

    /// Also the test seam: callers must explicitly supply their isolated folder.
    func connect(folder: URL) async throws {
        let attemptID = UUID()
        self.connectionAttemptID = attemptID
        let identity = self.environmentIdentity()
        guard identity.deviceBinding == self.deviceBinding,
              !self.automaticallySyncs || identity.deviceBinding != nil,
              identity.cloudAccountFingerprint != "identity-unavailable"
        else { throw MidasUsageSyncError.folderUnavailable }
        let selected = try await self.workspaceLoader(folder)
        try selected.validate()
        try Task.checkCancellation()
        guard self.connectionAttemptID == attemptID, self.environmentIdentity() == identity else {
            throw CancellationError()
        }
        let bookmark = try folder.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        self.connectionDrainID = attemptID
        defer { self.finishConnectionDrain(attemptID: attemptID) }
        let oldSync = self.connectionDrainingSync ?? self.activeSync
        self.connectionDrainingSync = oldSync
        self.pause()
        await oldSync?.value
        guard self.connectionAttemptID == attemptID, self.environmentIdentity() == identity else {
            throw CancellationError()
        }
        self.transport = .folder
        self.stagedTransport = nil
        self.defaults.set(
            self.transport.rawValue,
            forKey: "midasUsageSyncTransport")
        self.workspace = selected
        self.folderURL = folder
        self.hubConnection = nil
        self.defaults.set(
            bookmark,
            forKey: "midasUsageSyncFolderBookmark")
        self.defaults.set(
            selected.id.uuidString,
            forKey: "midasUsageSyncWorkspaceID")
        self.accountFingerprint = identity.cloudAccountFingerprint
        self.defaults.set(
            identity.cloudAccountFingerprint,
            forKey: "midasUsageSyncAccountFingerprint")
        self.clearReceivedView()
        self.restoreCache(
            expected: selected,
            acceptsExplicitReconnection: true)
        self.restoreOutbox(
            expected: selected,
            acceptsExplicitReconnection: true)
        self.issue = nil
        self.isEnabled = true
        self.status = "Connected. Waiting for usage."
        // The replacement defer resumes automatic work after releasing the writer gate.
    }

    func disconnect() {
        self.isEnabled = false
        self.folderURL = nil
        self.hubConnection = nil
        self.workspace = nil
        self.received = []
        self.pendingLocal = nil
        self.snapshots = [:]
        self.devices = []
        self.lastPublishedAt = nil
        self.lastReceivedAt = nil
        if self.transport == .folder {
            self.defaults.removeObject(forKey: "midasUsageSyncFolderBookmark")
            self.defaults.removeObject(forKey: "midasUsageSyncWorkspaceID")
            self.defaults.removeObject(forKey: "midasUsageSyncAccountFingerprint")
        }
        self.accountFingerprint = nil
        self.status = self.transport == .folder
            ? "Disconnected. Shared history remains in the folder."
            : "Disconnected. Usage already received by the hub is retained there."
        self.issue = nil
    }

    func syncNow(forceCollection: Bool = true) async {
        guard self.isEnabled, !Task.isCancelled, !self.isReplacingConnection else { return }
        guard self.activeSync == nil else {
            self.dirtyWhileSyncing = true
            return
        }
        // A manual retry is immediate; automatic scheduling respects nextRetryAt.
        self.nextRetryAt = nil
        let syncID = UUID()
        self.activeSyncID = syncID
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performSync(forceCollection: forceCollection)
        }
        self.activeSync = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if self.activeSyncID == syncID {
            self.activeSync = nil
            self.activeSyncID = nil
        }
        // The sync export re-scans the local session corpus; return its freed pages
        // instead of waiting for the next token-refresh relief pass.
        MemoryPressureRelief.releaseFreeMallocPages()
        if self.dirtyWhileSyncing, self.automaticallySyncs, self.isEnabled, self.operation == nil {
            self.dirtyWhileSyncing = false
            self.scheduleSync()
        }
    }

    private func performSync(forceCollection: Bool) async {
        guard self.isEnabled, !self.isSyncing, !Task.isCancelled else { return }
        guard self.identityStillMatches() else { return }
        if !self.hasConnection { self.restoreConnection() }
        guard await self.prepareHubWorkspaceIfNeeded() else { return }
        guard self.hasConnection, let workspace = self.workspace else {
            if self.issue == nil {
                self.status = self.transport == .folder ? "Choose a shared folder to connect this Mac."
                    : "Connect your Tailscale hub."
            }
            return
        }
        self.isSyncing = true
        let generation = self.generation
        defer {
            if self.generation == generation {
                self.isSyncing = false
                self.phase = .idle
            }
        }
        // Every hub cycle checks peers before local collection. This also reconciles a
        // restored nonempty local cache against this device's authoritative hub head.
        let receivedSuccessfully = await self.receiveHubUsage(
            workspace: workspace,
            generation: generation)
        guard self.generation == generation, self.isEnabled else { return }
        guard !self.outboxRequiresRepair else {
            self.issue = "This Mac’s saved upload queue needs repair. Its original files are preserved."
            self.status = "Received usage is available. Local sharing is paused to protect unpublished history."
            return
        }
        if self.transport == .tailscaleHub, receivedSuccessfully, let pending = self.pendingLocal,
           let hubHead = self.received.first(where: { $0.deviceID == self.syncDeviceID })
        {
            do {
                let fresh = MidasUsageSyncPublication(
                    workspaceID: workspace.id,
                    deviceID: self.syncDeviceID,
                    deviceName: self.hubConnection?.deviceName ?? pending.deviceName,
                    publishedAt: max(
                        self.currentTime(),
                        hubHead.publishedAt.addingTimeInterval(0.001)),
                    events: pending.events,
                    accountDays: pending.accountDays,
                    excludedRecords: pending.excludedRecords)
                self.pendingLocal = try await self.worker.retain(
                    previous: hubHead,
                    fresh: fresh,
                    workspaceID: workspace.id,
                    now: self.currentTime(),
                    canonical: true)
                try await self.persistOutbox()
            } catch {
                self.recordFailure(error)
                return
            }
        }
        if let pending = self.pendingLocal, self.transport != .tailscaleHub || receivedSuccessfully {
            do {
                self.phase = .uploading
                self.status = "Uploading changes saved on this Mac…"
                let outcome = try await self.exchangeUsage(
                    workspace: workspace,
                    publication: pending,
                    now: self.currentTime())
                try await self.recordExchange(
                    outcome.result,
                    publication: pending,
                    workspace: workspace,
                    generation: generation,
                    hubState: outcome.state)
            } catch {
                guard self.generation == generation, !(error is CancellationError) else { return }
                self.recordFailure(error)
                // A failed retry must not discard the outbox or stop fresh local capture.
            }
        }
        guard let makeLocalUsage = self.makeLocalUsage,
              forceCollection || self.lastCollectedAt.map({ self.currentTime().timeIntervalSince($0) >= 60 }) ?? true
        else { return }
        await self.collectAndPublish(
            workspace: workspace,
            generation: generation,
            receivedSuccessfully: receivedSuccessfully,
            makeLocalUsage: makeLocalUsage)
    }

    private func collectAndPublish(
        workspace: MidasUsageSyncWorkspace,
        generation: UUID,
        receivedSuccessfully: Bool,
        makeLocalUsage: (MidasUsageSyncWorkspace, Date) async throws -> MidasUsageSyncLocalUsage) async
    {
        self.phase = .collecting
        self.status = "Collecting recent usage…"
        let collectionStartedAt = self.currentTime()
        let local: MidasUsageSyncLocalUsage
        do {
            local = try await makeLocalUsage(workspace, collectionStartedAt)
        } catch {
            guard self.generation == generation, !(error is CancellationError) else { return }
            self.issue = "Local usage collection could not finish. Saved changes and received history are retained."
            self.status = "Showing received usage. Local collection will retry."
            return
        }
        do {
            try Task.checkCancellation()
            guard self.generation == generation, self.isEnabled, self.identityStillMatches() else { return }
            self.lastCollectedAt = self.currentTime()
            let now = self.currentTime()
            let previous = self.pendingLocal ?? self.received.first { $0.deviceID == self.syncDeviceID }
            let publishedAt = previous.map { max(now, $0.publishedAt.addingTimeInterval(0.001)) } ?? now
            let fresh = MidasUsageSyncPublication(
                workspaceID: workspace.id,
                deviceID: self.syncDeviceID,
                deviceName: self.hubConnection?.deviceName ?? Self.safeDeviceName(self.deviceName),
                publishedAt: publishedAt,
                events: local.events,
                accountDays: local.accountDays,
                excludedRecords: local.excludedRecords)
            let publication = try await self.worker.retain(
                previous: previous,
                fresh: fresh,
                workspaceID: workspace.id,
                now: now,
                canonical: self.transport == .tailscaleHub)
            try Task.checkCancellation()
            guard self.generation == generation, self.isEnabled, self.identityStillMatches() else { return }
            if let previous, self.pendingLocal == nil,
               previous.events == publication.events, previous.accountDays == publication.accountDays,
               previous.excludedRecords == publication.excludedRecords, previous.deviceName == publication.deviceName
            {
                return
            }
            self.pendingLocal = publication
            self.phase = .saving
            do {
                try await self.persistOutbox()
                try Task.checkCancellation()
                guard self.generation == generation, self.isEnabled, self.identityStillMatches() else { return }
            } catch {
                guard self.generation == generation, !(error is CancellationError) else { return }
                self.issue = "This Mac could not preserve its offline sync history. No usage was shared."
                self.status = "Waiting to save this Mac’s usage locally. Showing last received usage."
                return
            }
            // Failed refreshes cannot overwrite richer hub state. The durable outbox
            // remains available to retry after a successful independent receive.
            guard self.transport != .tailscaleHub || receivedSuccessfully else {
                self.status = "Changes saved on this Mac. Waiting to reach the hub."
                return
            }
            self.phase = .uploading
            self.status = "Uploading saved changes…"
            let outcome = try await self.exchangeUsage(
                workspace: workspace,
                publication: publication,
                now: now)
            try Task.checkCancellation()
            guard self.generation == generation, self.isEnabled, self.workspace == workspace,
                  self.identityStillMatches() else { return }
            try await self.recordExchange(
                outcome.result,
                publication: publication,
                workspace: workspace,
                generation: generation,
                hubState: outcome.state)
        } catch {
            guard self.generation == generation else { return }
            if case MidasUsageSyncError.wrongWorkspace = error {
                self.invalidateConnection(message: self.message(error))
                return
            }
            if error is CancellationError { return }
            self.recordFailure(error)
        }
    }

    private func recordFailure(_ error: Error) {
        self.consecutiveFailures = min(self.consecutiveFailures + 1, 6)
        let delay = min(300.0, 15 * pow(2, Double(self.consecutiveFailures - 1)))
        self.nextRetryAt = self.currentTime().addingTimeInterval(delay + Double.random(in: 0...3))
        self.issue = self.message(error)
        self.status = "Showing last received usage. Sync will retry automatically."
    }

    private func exchangeUsage(
        workspace: MidasUsageSyncWorkspace,
        publication: MidasUsageSyncPublication,
        now: Date) async throws -> (
        result: MidasUsageSyncFolder.Result,
        state: MidasUsageHubSyncState?)
    {
        switch self.transport {
        case .folder:
            guard let folder = self.folderURL else { throw MidasUsageSyncError.folderUnavailable }
            return try await (self.exchangePublication(folder, workspace, publication, now), nil)
        case .tailscaleHub:
            guard let connection = self.hubConnection else { throw MidasUsageSyncError.folderUnavailable }
            let exchange = try await self.hubExchange(connection, workspace, publication, now)
            return (MidasUsageSyncFolder.Result(
                workspace: exchange.workspace,
                publications: exchange.publications,
                publicationSucceeded: exchange.publicationSucceeded,
                unavailableFiles: exchange.unavailableFiles,
                rejectedFiles: exchange.rejectedFiles), exchange.syncState)
        }
    }

    /// Receiving is independent of collection, including for a restored nonempty cache.
    private func receiveHubUsage(
        workspace: MidasUsageSyncWorkspace,
        generation: UUID) async -> Bool
    {
        guard self.transport == .tailscaleHub,
              let connection = self.hubConnection else { return true }
        self.phase = .checking
        self.status = "Checking shared usage…"
        do {
            let result = try await self.hubExchange(connection, workspace, nil, self.currentTime())
            try Task.checkCancellation()
            guard self.generation == generation, self.isEnabled, self.workspace == workspace,
                  self.hubConnection == connection, self.identityStillMatches() else { return false }
            guard result.workspace == workspace else { throw MidasUsageSyncError.wrongWorkspace }
            guard !result.publicationSucceeded else { throw MidasUsageHubError.invalidResponse }
            try await self.recordExchange(
                MidasUsageSyncFolder.Result(
                    workspace: result.workspace,
                    publications: result.publications,
                    publicationSucceeded: false,
                    unavailableFiles: result.unavailableFiles,
                    rejectedFiles: result.rejectedFiles),
                publication: nil,
                workspace: workspace,
                generation: generation,
                hubState: result.syncState)
            return true
        } catch {
            guard self.generation == generation, self.isEnabled else { return false }
            if error is CancellationError { return false }
            if case MidasUsageSyncError.wrongWorkspace = error {
                self.invalidateConnection(message: self.message(error))
                return false
            }
            // The outbox and source collection survive a failed check. Publishing
            // waits for reconciliation so restored local state cannot erase hub data.
            self.recordFailure(error)
            return false
        }
    }

    private func recordExchange(
        _ result: MidasUsageSyncFolder.Result,
        publication: MidasUsageSyncPublication?,
        workspace: MidasUsageSyncWorkspace,
        generation: UUID,
        hubState: MidasUsageHubSyncState? = nil) async throws
    {
        let checkedAt = self.currentTime()
        guard result.workspace == workspace else { throw MidasUsageSyncError.wrongWorkspace }
        self.phase = .applying
        if publication == nil, result.publications == self.received, result.rejectedFiles == 0,
           result.unavailableFiles == 0, self.lastAppliedAt != nil
        {
            self.lastCheckedAt = checkedAt
            self.hubSyncState = hubState ?? self.hubSyncState
            if let hubState, let connection = self.hubConnection {
                self.peerReceipts = try await self.hubAcknowledge(connection, workspace, hubState)
            }
            self.issue = nil
            self.consecutiveFailures = 0
            self.nextRetryAt = nil
            self.status = self.peerDeliverySummary ?? "This Mac is up to date. Shared usage is saved locally."
            try await self.persistSyncReceipt()
            return
        }
        var candidates: [MidasUsageSyncPublication]
        if hubState != nil {
            candidates = try await self.worker.reconcile(previous: self.received, heads: result.publications)
        } else {
            candidates = self.received + result.publications
            if let publication, result.publicationSucceeded { candidates.append(publication) }
        }
        let ledger = try await self.worker.ledger(
            publications: candidates,
            workspaceID: workspace.id,
            now: checkedAt,
            canonical: self.transport == .tailscaleHub)
        try Task.checkCancellation()
        guard self.generation == generation, self.isEnabled, self.workspace == workspace,
              self.identityStillMatches() else { throw CancellationError() }
        var recoveredPending: MidasUsageSyncPublication?
        if hubState != nil, publication == nil, !self.criticalOutboxNeedsRepair,
           let retained = ledger.publications.first(where: { $0.deviceID == self.syncDeviceID }),
           result.publications.first(where: { $0.deviceID == self.syncDeviceID })?.events != retained.events ||
           result.publications.first(where: { $0.deviceID == self.syncDeviceID })?.accountDays != retained.accountDays
        {
            recoveredPending = try await self.worker.retain(
                previous: self.pendingLocal,
                fresh: retained,
                workspaceID: workspace.id,
                now: checkedAt,
                canonical: true)
        }
        try Task.checkCancellation()
        guard self.generation == generation, self.isEnabled else { throw CancellationError() }
        let oldRemote = self.received.filter { $0.deviceID != self.syncDeviceID }
        let newRemote = ledger.publications.filter { $0.deviceID != self.syncDeviceID }
        let previousReceived = self.received
        let previousSnapshots = self.snapshots
        let previousDevices = self.devices
        let previousHubState = self.hubSyncState
        let previousReceivedAt = self.lastReceivedAt
        let previousCheckedAt = self.lastCheckedAt
        let previousCoverageIssue = self.coverageIssue
        let previousPending = self.pendingLocal
        let previousPublished = self.lastPublishedAt
        let previousApplied = self.lastAppliedAt
        self.received = ledger.publications
        self.snapshots = ledger.snapshots
        if let recoveredPending { self.pendingLocal = recoveredPending }
        self.devices = ledger.publications.map { value in
            MidasUsageSyncDeviceStatus(
                id: value.deviceID,
                name: value.deviceName,
                lastSeenAt: value.publishedAt,
                isThisMac: value.deviceID == self.syncDeviceID,
                eventCount: value.events.count + value.accountDays.count)
        }
        if publication != nil, result.publicationSucceeded {
            self.lastPublishedAt = checkedAt
            self.pendingLocal = nil
        }
        self.lastCheckedAt = checkedAt
        if newRemote != oldRemote, !newRemote.isEmpty { self.lastReceivedAt = checkedAt }
        self.coverageIssue = Self.coverageIssue(
            result: result,
            ledger: ledger)
        self.lastAppliedAt = checkedAt
        self.hubSyncState = hubState ?? self.hubSyncState
        do {
            // The app's aggregate/cache checkpoint, not merely the transport's page
            // cache, must be durable before another device is told it was applied.
            try await self.persistCache()
            if !self.criticalOutboxNeedsRepair { try await self.persistOutbox() }
            try Task.checkCancellation()
            guard self.generation == generation, self.isEnabled else { throw CancellationError() }
        } catch {
            self.received = previousReceived
            self.snapshots = previousSnapshots
            self.devices = previousDevices
            self.hubSyncState = previousHubState
            self.lastReceivedAt = previousReceivedAt
            self.lastCheckedAt = previousCheckedAt
            self.coverageIssue = previousCoverageIssue
            self.pendingLocal = previousPending ?? publication
            self.lastPublishedAt = previousPublished
            self.lastAppliedAt = previousApplied
            self.issue = "Shared history could not be saved locally. Saved changes are retained for retry."
            throw error
        }
        self.issue = nil
        self.consecutiveFailures = 0
        self.nextRetryAt = nil
        if let hubState, let connection = self.hubConnection {
            self.peerReceipts = try await self.hubAcknowledge(connection, workspace, hubState)
            for index in self.devices.indices {
                let deviceID = self.devices[index].id
                let receipt = self.peerReceipts.first { $0.deviceID == deviceID }
                self.devices[index].lastContactAt = receipt?.checkedAt
                if let revision = hubState.acceptedLocalRevision, !self.devices[index].isThisMac {
                    self.devices[index].hasAppliedLatest =
                        (receipt?.appliedRevisions[self.syncDeviceID.uuidString] ?? -1) >= revision
                }
            }
        }
        self.status = self.peerDeliverySummary ?? (self.transport == .tailscaleHub
            ? "This Mac is up to date. Shared usage is saved locally."
            : "Usage saved here. Another Mac’s receipt is not confirmed.")
        try await self.persistSyncReceipt()
    }

    private func pause() {
        self.generation = UUID()
        self.operation?.cancel()
        self.operation = nil
        self.operationID = nil
        self.activeSync?.cancel()
        self.activeSync = nil
        self.activeSyncID = nil
        self.isSyncing = false
        self.phase = .idle
        self.dirtyWhileSyncing = false
        self.status = "Sync is paused."
    }
}

extension MidasUsageSyncCoordinator {
    /// Import is explicit. The private credential is stored only in a protected local file.
    func connect(hub connection: MidasUsageHubConnection) async throws {
        let attemptID = UUID()
        self.connectionAttemptID = attemptID
        let identity = self.environmentIdentity()
        guard identity.deviceBinding == self.deviceBinding,
              !self.automaticallySyncs || identity.deviceBinding != nil
        else { throw MidasUsageSyncError.folderUnavailable }
        try connection.validate()
        let selected = try await self.hubWorkspaceLoader(connection)
        try selected.validate()
        try Task.checkCancellation()
        guard self.connectionAttemptID == attemptID,
              self.environmentIdentity().deviceBinding == identity.deviceBinding else { throw CancellationError() }
        guard connection.workspaceID == nil || connection.workspaceID == selected.id else {
            throw MidasUsageSyncError.wrongWorkspace
        }
        let candidateCacheURL = self.persistenceURL?.deletingLastPathComponent()
            .appendingPathComponent("hub-state.json")
        if let previous = self.readCache(at: candidateCacheURL),
           previous.workspace.id == selected.id, previous.workspace != selected
        { throw MidasUsageSyncError.wrongWorkspace }
        let pinned = MidasUsageHubConnection(
            endpoint: connection.endpoint,
            deviceID: connection.deviceID,
            deviceName: connection.deviceName,
            credential: connection.credential,
            workspaceID: selected.id)
        // Drain the old writer only after replacement validation succeeds. A failed
        // replacement leaves the current connection, display and enabled choice intact.
        self.connectionDrainID = attemptID
        defer { self.finishConnectionDrain(attemptID: attemptID) }
        let oldSync = self.connectionDrainingSync ?? self.activeSync
        self.connectionDrainingSync = oldSync
        self.pause()
        await oldSync?.value
        guard self.connectionAttemptID == attemptID,
              self.environmentIdentity().deviceBinding == identity.deviceBinding else { throw CancellationError() }
        try LocalPersistence.write(
            JSONEncoder().encode(pinned),
            to: self.hubConnectionURL)
        self.transport = .tailscaleHub
        self.stagedTransport = nil
        self.defaults.set(
            self.transport.rawValue,
            forKey: "midasUsageSyncTransport")
        self.hubConnection = pinned
        self.workspace = selected
        self.folderURL = nil
        self.deviceName = connection.deviceName
        self.accountFingerprint = Self.hubFingerprint(pinned)
        self.clearReceivedView()
        self.restoreCache(
            expected: selected,
            acceptsExplicitReconnection: true)
        self.restoreOutbox(
            expected: selected,
            acceptsExplicitReconnection: true)
        self.issue = nil
        self.isEnabled = true
        self.status = "Connected to your Tailscale hub. Waiting for usage."
        try await self.persistCache()
        try Task.checkCancellation()
        // The replacement defer resumes automatic work after releasing the writer gate.
    }
}

extension MidasUsageSyncCoordinator {
    private func finishConnectionDrain(attemptID: UUID) {
        guard self.connectionDrainID == attemptID else { return }
        self.connectionDrainID = nil
        self.connectionDrainingSync = nil
        self.scheduleSync()
    }
}

extension MidasUsageSyncCoordinator {
    func connectivityRecovered() {
        self.nextRetryAt = nil
        self.consecutiveFailures = 0
        self.scheduleSync()
    }
}

extension MidasUsageSyncCoordinator {
    func accountChanged() {
        guard self.isEnabled, self.identityStillMatches() else { return }
        if !self.hasConnection { self.restoreConnection() }
        self.scheduleSync()
    }

    private func invalidateConnection(message: String) {
        self.disconnect()
        self.issue = message
        self.status = self.transport == .folder
            ? "Sync disconnected. Choose the shared folder again."
            : "Sync disconnected. Import this device’s connection file again."
    }

    private func identityStillMatches() -> Bool {
        let current = self.environmentIdentity()
        guard current.deviceBinding == self.deviceBinding else {
            self
                .invalidateConnection(
                    message: self.transport == .folder
                        ? "This Mac’s sync identity changed. Choose the folder again to reconnect."
                        : "This Mac’s sync identity changed. Import this Mac’s connection file to reconnect.")
            return false
        }
        // Tailscale authenticates the hub with a per-device credential, independently of iCloud.
        if self.transport == .tailscaleHub { return true }
        let expected = self.accountFingerprint ?? self.defaults.string(forKey: "midasUsageSyncAccountFingerprint")
        if current.cloudAccountFingerprint == "identity-unavailable" ||
            (current.cloudAccountFingerprint == "no-icloud-account" && expected != "no-icloud-account")
        {
            self.identityUnavailable()
            return false
        }
        guard let expected, expected == current.cloudAccountFingerprint else {
            let legacy = expected?.count == 64 && expected?.allSatisfy(\.isHexDigit) == true
            self.invalidateConnection(message: legacy
                ? "Choose your shared folder again to update this Mac’s sync connection."
                : "Your iCloud account changed. Choose the shared folder again to reconnect.")
            return false
        }
        if self.issue?.contains("identity is temporarily unavailable") == true, let workspace = self.workspace {
            self.restoreCache(expected: workspace)
            self.issue = nil
        }
        return true
    }

    private func restoreConnection() {
        if self.transport == .tailscaleHub {
            self.restoreHubConnection()
            return
        }
        guard self.isEnabled, let data = self.defaults.data(forKey: "midasUsageSyncFolderBookmark"),
              let expectedID = self.defaults.string(forKey: "midasUsageSyncWorkspaceID").flatMap(UUID.init(uuidString:))
        else { return }
        guard self.identityStillMatches(),
              let fingerprint = self.defaults.string(forKey: "midasUsageSyncAccountFingerprint") else { return }
        self.accountFingerprint = fingerprint
        guard let cache = self.readCache(), cache.workspace.id == expectedID,
              cache.localDeviceID == self.syncDeviceID, cache.deviceBinding == self.deviceBinding,
              cache.accountFingerprint == fingerprint
        else {
            self.issue = "Choose your shared folder again to restore this connection."
            return
        }
        self.workspace = cache.workspace
        self.restoreCache(
            cache,
            expected: cache.workspace)
        var stale = false
        guard let folder = try? URL(
            resolvingBookmarkData: data,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale), !stale
        else {
            self.issue = "Choose your shared folder again to restore access."
            self.status = "Sync unavailable. Showing last received usage."
            return
        }
        self.folderURL = folder
        self.issue = nil
    }

    private func identityUnavailable() {
        // Do not publish under an unverified account or discard the user's connection.
        self.pause()
        self.snapshots = [:]
        self.devices = []
        self.issue = "Your iCloud identity is temporarily unavailable. Midas will retry automatically."
        self.status = "Waiting for iCloud. Your sync connection is preserved."
    }
}

extension MidasUsageSyncCoordinator {
    private func restoreCache(
        expected: MidasUsageSyncWorkspace,
        acceptsExplicitReconnection: Bool = false)
    {
        guard let cache = self.readCache() else { return }
        self.restoreCache(
            cache,
            expected: expected,
            acceptsExplicitReconnection: acceptsExplicitReconnection)
    }

    private func restoreCache(
        _ cache: Cache,
        expected: MidasUsageSyncWorkspace,
        acceptsExplicitReconnection: Bool = false)
    {
        guard cache.workspace == expected,
              cache.localDeviceID == self.syncDeviceID, cache.deviceBinding == self.deviceBinding,
              cache.accountFingerprint == self.accountFingerprint || acceptsExplicitReconnection,
              let ledger = try? autoreleasepool(invoking: {
                  try MidasUsageSyncLedger(
                      publications: cache.publications,
                      workspaceID: expected.id,
                      now: self.currentTime(),
                      validation: self.transport == .tailscaleHub ? .canonical : .legacy)
              })
        else { return }
        if let pending = cache.pendingLocal {
            guard pending.deviceID == self.syncDeviceID,
                  (try? pending.validateCanonical(
                      workspaceID: expected.id,
                      now: self.currentTime())) != nil
            else { return }
        }
        self.received = ledger.publications
        self.snapshots = ledger.snapshots
        self.pendingLocal = cache.pendingLocal
        self.lastPublishedAt = cache.lastPublishedAt
        self.lastReceivedAt = cache.lastReceivedAt
        self.devices = ledger.publications.map {
            MidasUsageSyncDeviceStatus(
                id: $0.deviceID,
                name: $0.deviceName,
                lastSeenAt: $0.publishedAt,
                isThisMac: $0.deviceID == self.syncDeviceID,
                eventCount: $0.events.count + $0.accountDays.count)
        }
    }

    private func restoreHubConnection() {
        guard self.isEnabled, self.identityStillMatches() else { return }
        do {
            let connection = try MidasUsageHubConnectionFile.load(at: self.hubConnectionURL)
            self.hubConnection = connection
            self.accountFingerprint = Self.hubFingerprint(connection)
            guard let cache = self.readCache() else {
                if self.hasNoCacheFile() {
                    // A secure per-device file plus enabled preferences is an explicit installer opt-in.
                    // Wait for the real workspace before collecting or publishing any numeric records.
                    self.issue = nil
                    self.status = "Connecting to your Tailscale hub for the first time."
                } else {
                    self.recoveringPeerCache = true
                    if let root = self.persistenceURL?.deletingLastPathComponent(),
                       let data = try? LocalPersistence.read(root.appendingPathComponent("hub-checkpoint-v2.json"))
                    {
                        try? LocalPersistence.write(
                            data,
                            to: root.appendingPathComponent(
                                "hub-checkpoint-quarantined-" + UUID().uuidString + ".json"))
                    }
                    self.issue = "Saved peer history is being rebuilt from your hub. Local changes are preserved."
                    self.restoreOutbox(expected: nil)
                }
                return
            }
            guard cache.localDeviceID == connection.deviceID,
                  cache.deviceBinding == self.deviceBinding,
                  cache.accountFingerprint == self.accountFingerprint,
                  connection.workspaceID == cache.workspace.id
            else {
                self.hubConnection = nil
                self.issue = "Import this device’s connection file again to restore your hub connection."
                return
            }
            self.workspace = cache.workspace
            self.restoreCache(
                cache,
                expected: cache.workspace)
            self.restoreOutbox(expected: cache.workspace)
            self.issue = nil
            self.status = "Showing last received usage. Waiting to reach your Tailscale hub."
        } catch {
            self.hubConnection = nil
            self.issue = "The private hub connection file is unavailable. Import it again to reconnect."
        }
    }

    private func hasNoCacheFile() -> Bool {
        guard let url = self.cacheURL else { return false }
        var metadata = stat()
        let absent = Darwin.lstat(url.path, &metadata) != 0 && errno == ENOENT
        let checkpoint = url.deletingLastPathComponent().appendingPathComponent("hub-checkpoint-v2.json")
        return absent && Darwin.lstat(checkpoint.path, &metadata) != 0 && errno == ENOENT
    }

    private func prepareHubWorkspaceIfNeeded() async -> Bool {
        guard self.transport == .tailscaleHub, self.workspace == nil,
              let connection = self.hubConnection else { return true }
        let generation = self.generation
        self.isSyncing = true
        self.status = "Connecting to your Tailscale hub for the first time…"
        defer { if self.generation == generation { self.isSyncing = false } }
        do {
            let selected = try await self.hubWorkspaceLoader(connection)
            try selected.validate()
            try Task.checkCancellation()
            guard self.generation == generation, self.isEnabled, self.hubConnection == connection,
                  self.identityStillMatches() else { return false }
            guard connection.workspaceID == nil || connection.workspaceID == selected.id else {
                throw MidasUsageSyncError.wrongWorkspace
            }
            guard self.hasNoCacheFile() || self.recoveringPeerCache else {
                self.hubConnection = nil
                self.issue = "Saved hub history appeared during setup. Import the connection file again to reconnect."
                return false
            }
            let pinned = MidasUsageHubConnection(
                endpoint: connection.endpoint,
                deviceID: connection.deviceID,
                deviceName: connection.deviceName,
                credential: connection.credential,
                workspaceID: selected.id)
            try LocalPersistence.write(
                JSONEncoder().encode(pinned),
                to: self.hubConnectionURL)
            self.hubConnection = pinned
            self.workspace = selected
            self.accountFingerprint = Self.hubFingerprint(pinned)
            self.deviceName = pinned.deviceName
            try await self.persistCache()
            try Task.checkCancellation()
            guard self.generation == generation, self.isEnabled else { return false }
            self.issue = nil
            return true
        } catch {
            guard self.generation == generation else { return false }
            if case MidasUsageSyncError.wrongWorkspace = error {
                self.invalidateConnection(message: self.message(error))
            } else if !(error is CancellationError) {
                self.issue = self.message(error)
                self.status = "Waiting for your hub to finish first-time setup. Midas will retry automatically."
            }
            return false
        }
    }

    private static func hubFingerprint(_ connection: MidasUsageHubConnection) -> String {
        let values = [connection.endpoint.absoluteString, connection.deviceID.uuidString, connection.credential]
        let data = (try? JSONEncoder().encode(values)) ?? Data()
        return "tailscale-hub:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static var defaultPersistenceURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask)[0]
            .appendingPathComponent(
                MidasIdentity.supportDirectoryName,
                isDirectory: true)
            .appendingPathComponent(
                "usage-sync",
                isDirectory: true)
            .appendingPathComponent("state.json")
    }
}

extension MidasUsageSyncCoordinator {
    /// Serializes large transient graphs and disk writes away from the UI executor.
    /// Callers check cancellation and connection generation before applying results.
    private actor Worker {
        let write: @Sendable (Data, URL) throws -> Void

        init(write: @escaping @Sendable (Data, URL) throws -> Void) {
            self.write = write
        }

        func reconcile(previous: [MidasUsageSyncPublication], heads: [MidasUsageSyncPublication]) throws
            -> [MidasUsageSyncPublication]
        {
            var retained = Dictionary(uniqueKeysWithValues: previous.map { ($0.deviceID, $0) })
            for head in heads {
                retained[head.deviceID] = try MidasUsageSyncLedger.retainingCanonicalHistory(
                    previous: retained[head.deviceID], fresh: head)
            }
            return Array(retained.values)
        }

        func retain(
            previous: MidasUsageSyncPublication?,
            fresh: MidasUsageSyncPublication,
            workspaceID: UUID,
            now: Date,
            canonical: Bool = false) throws -> MidasUsageSyncPublication
        {
            try Task.checkCancellation()
            return try autoreleasepool {
                let publication = canonical
                    ? try MidasUsageSyncLedger.retainingCanonicalHistory(
                        previous: previous,
                        fresh: fresh)
                    : MidasUsageSyncLedger.retainingLocalHistory(
                        previous: previous,
                        fresh: fresh)
                if canonical { try publication.validateCanonical(
                    workspaceID: workspaceID,
                    now: now) } else { try publication.validate(
                    workspaceID: workspaceID,
                    now: now) }
                return publication
            }
        }

        func ledger(
            publications: [MidasUsageSyncPublication],
            workspaceID: UUID,
            now: Date,
            canonical: Bool = false) throws -> MidasUsageSyncLedger
        {
            try Task.checkCancellation()
            return try autoreleasepool {
                try MidasUsageSyncLedger(
                    publications: publications,
                    workspaceID: workspaceID,
                    now: now,
                    validation: canonical ? .canonical : .legacy)
            }
        }

        func persistPaged(
            _ cache: Cache,
            root: URL,
            now: Date) throws
        {
            let store = try MidasUsageCanonicalStore(root: root.appendingPathComponent("hub-received-records"))
            let references = try cache.publications.map {
                try PublicationReference(
                    deviceID: $0.deviceID,
                    revision: store.save(
                        $0,
                        now: now))
            }
            let checkpoint = PagedCache(
                localDeviceID: cache.localDeviceID,
                deviceBinding: cache.deviceBinding,
                accountFingerprint: cache.accountFingerprint,
                workspace: cache.workspace,
                publications: references,
                lastPublishedAt: cache.lastPublishedAt,
                lastReceivedAt: cache.lastReceivedAt)
            try Task.checkCancellation()
            try self.write(JSONEncoder().encode(checkpoint), root.appendingPathComponent("hub-checkpoint-v2.json"))
            try? store.prune(retainingRevisions: references.map(\.revision))
        }

        func persistOutbox(
            _ publication: MidasUsageSyncPublication,
            metadata: Outbox,
            root: URL,
            now: Date) throws
        {
            let store = try MidasUsageCanonicalStore(root: root.appendingPathComponent("hub-outbox-records"))
            let revision = try store.save(
                publication,
                now: now)
            let outbox = Outbox(
                localDeviceID: publication.deviceID,
                deviceBinding: metadata.deviceBinding,
                workspace: metadata.workspace,
                revision: revision,
                pending: metadata.pending)
            try Task.checkCancellation()
            try self.write(JSONEncoder().encode(outbox), root.appendingPathComponent("hub-outbox.json"))
            try? store.prune(retainingRevisions: [revision])
        }

        func persist(_ cache: Cache, to url: URL) throws {
            try Task.checkCancellation()
            try autoreleasepool {
                let metadata = try JSONEncoder().encode(Cache.Metadata(cache))
                let data = try MidasUsageSyncEncoding.encodeEnvelope(
                    metadata: metadata,
                    publications: cache.publications,
                    pendingLocal: cache.pendingLocal)
                try Task.checkCancellation()
                try self.write(data, url)
            }
        }
    }

    private func readCache(at requestedURL: URL? = nil) -> Cache? {
        let target = requestedURL ?? self.cacheURL
        if let target, target.lastPathComponent == "hub-state.json" {
            let checkpoint = target.deletingLastPathComponent().appendingPathComponent("hub-checkpoint-v2.json")
            var info = stat()
            if Darwin.lstat(checkpoint.path, &info) == 0 { return self.readPagedCache(legacyURL: target) }
        }
        return autoreleasepool {
            guard let url = target,
                  let data = try? LocalPersistence.read(url),
                  let envelope = try? MidasUsageSyncCodec.decodeEnvelope(data),
                  let metadata = try? JSONDecoder().decode(
                      Cache.self,
                      from: envelope.metadata),
                  metadata.schemaVersion == 2, (try? metadata.workspace.validate()) != nil,
                  metadata.accountFingerprint.utf8.count <= 128, (metadata.deviceBinding?.utf8.count ?? 0) <= 128
            else { return nil }
            // Keep every schema-2 identity and timestamp field while decoding the bulk
            // publication arrays in bounded batches instead of one Foundation JSON map.
            return Cache(
                schemaVersion: metadata.schemaVersion,
                localDeviceID: metadata.localDeviceID,
                deviceBinding: metadata.deviceBinding,
                accountFingerprint: metadata.accountFingerprint,
                workspace: metadata.workspace,
                publications: envelope.publications,
                pendingLocal: envelope.pendingLocal,
                lastPublishedAt: metadata.lastPublishedAt,
                lastReceivedAt: metadata.lastReceivedAt)
        }
    }

    private func persistCache() async throws {
        guard let url = self.cacheURL, let workspace, let accountFingerprint else {
            throw MidasUsageSyncError.folderUnavailable
        }
        let cache = Cache(
            localDeviceID: self.syncDeviceID,
            deviceBinding: self.deviceBinding,
            accountFingerprint: accountFingerprint,
            workspace: workspace,
            publications: self.received,
            pendingLocal: self.pendingLocal,
            lastPublishedAt: self.lastPublishedAt,
            lastReceivedAt: self.lastReceivedAt)
        if self.transport == .tailscaleHub {
            if !self.criticalOutboxNeedsRepair { try await self.persistOutbox() }
            try await self.worker.persistPaged(
                cache,
                root: url.deletingLastPathComponent(),
                now: self.currentTime())
        } else {
            try await self.worker.persist(
                cache,
                to: url)
        }
    }

    private func readPagedCache(legacyURL: URL) -> Cache? {
        let root = legacyURL.deletingLastPathComponent()
        guard let data = try? LocalPersistence.read(root.appendingPathComponent("hub-checkpoint-v2.json")),
              let value = try? JSONDecoder().decode(
                  PagedCache.self,
                  from: data), value.schemaVersion == 3,
              (try? value.workspace.validate()) != nil,
              value.publications.count <= 128,
              Set(value.publications.map(\.deviceID)).count == value.publications.count,
              let store = try? MidasUsageCanonicalStore(root: root.appendingPathComponent("hub-received-records"))
        else { return nil }
        var publications: [MidasUsageSyncPublication] = []
        for reference in value.publications {
            guard let publication = try? store.load(
                workspaceID: value.workspace.id,
                deviceID: reference.deviceID,
                revision: reference.revision,
                now: self.currentTime())
            else { return nil }
            publications.append(publication)
        }
        return Cache(
            localDeviceID: value.localDeviceID,
            deviceBinding: value.deviceBinding,
            accountFingerprint: value.accountFingerprint,
            workspace: value.workspace,
            publications: publications,
            pendingLocal: nil,
            lastPublishedAt: value.lastPublishedAt,
            lastReceivedAt: value.lastReceivedAt)
    }

    private func restoreOutbox(
        expected: MidasUsageSyncWorkspace?,
        acceptsExplicitReconnection: Bool = false)
    {
        guard self.transport == .tailscaleHub,
              let root = self.persistenceURL?.deletingLastPathComponent() else { return }
        var info = stat()
        let outboxURL = root.appendingPathComponent("hub-outbox.json")
        guard Darwin.lstat(outboxURL.path, &info) == 0 else { return }
        self.criticalOutboxNeedsRepair = true
        guard let data = try? LocalPersistence.read(outboxURL),
              let value = try? JSONDecoder().decode(
                  Outbox.self,
                  from: data), value.schemaVersion == 1,
              value.localDeviceID == self.syncDeviceID, value.deviceBinding == self.deviceBinding,
              expected == nil || expected == value.workspace,
              self.hubConnection?.workspaceID == nil || self.hubConnection?.workspaceID == value.workspace.id,
              let store = try? MidasUsageCanonicalStore(root: root.appendingPathComponent("hub-outbox-records")),
              let publication = try? store.load(
                  workspaceID: value.workspace.id,
                  deviceID: value.localDeviceID,
                  revision: value.revision,
                  now: self.currentTime()) else { return }
        self.criticalOutboxNeedsRepair = false
        self.workspace = value.workspace
        if value.pending {
            self.pendingLocal = publication
            return
        }
        if let ledger = try? MidasUsageSyncLedger(
            publications: self.received + [publication],
            workspaceID: value.workspace.id,
            now: self.currentTime(),
            validation: .canonical)
        {
            self.received = ledger.publications
            self.snapshots = ledger.snapshots
        }
    }

    private func persistOutbox() async throws {
        guard !self.outboxRequiresRepair else { throw MidasUsageSyncError.invalidRecord }
        guard self.transport == .tailscaleHub else {
            if self.pendingLocal != nil, let url = self.cacheURL, let workspace, let accountFingerprint {
                try await self.worker.persist(
                    Cache(
                        localDeviceID: self.syncDeviceID,
                        deviceBinding: self.deviceBinding,
                        accountFingerprint: accountFingerprint,
                        workspace: workspace,
                        publications: self.received,
                        pendingLocal: self.pendingLocal,
                        lastPublishedAt: self.lastPublishedAt,
                        lastReceivedAt: self.lastReceivedAt),
                    to: url)
            }
            return
        }
        guard let root = self.persistenceURL?.deletingLastPathComponent(), let workspace,
              let publication = self.pendingLocal ?? self.received.first(where: { $0.deviceID == self.syncDeviceID })
        else { return }
        try await self.worker.persistOutbox(
            publication,
            metadata: Outbox(
                localDeviceID: self.syncDeviceID,
                deviceBinding: self.deviceBinding,
                workspace: workspace,
                revision: "",
                pending: self.pendingLocal != nil),
            root: root,
            now: self.currentTime())
    }

    private func persistSyncReceipt() async throws {
        guard let root = self.persistenceURL?.deletingLastPathComponent() else { return }
        struct Receipt: Encodable {
            let schemaVersion = 1
            let syncState: MidasUsageHubSyncState?
            let lastPublishedAt: Date?
            let lastReceivedAt: Date?
            let outboxPending: Bool
            let phase: MidasUsageSyncPhase
        }
        try LocalPersistence.write(
            JSONEncoder().encode(Receipt(
                syncState: self.hubSyncState,
                lastPublishedAt: self.lastPublishedAt,
                lastReceivedAt: self.lastReceivedAt,
                outboxPending: self.hasPendingUpload,
                phase: self.phase)),
            to: root.appendingPathComponent("sync-receipt.json"))
    }

    private static func safeDeviceName(_ name: String) -> String {
        let clean = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let value = String(String.UnicodeScalarView(clean)).trimmingCharacters(in: .whitespacesAndNewlines)
        var bounded = ""
        for character in value {
            guard bounded.utf8.count + String(character).utf8.count <= 80 else { break }
            bounded.append(character)
        }
        return bounded.isEmpty ? "Mac" : bounded
    }
}
