import AppKit
import CodexBarCore
import CryptoKit
import Darwin
import Foundation
import IOKit
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
}

struct MidasUsageSyncLocalUsage: Sendable {
    var events: [MidasUsageSyncEvent] = []
    var accountDays: [MidasUsageSyncAccountDay] = []
    var excludedRecords = 0
}

/// These opaque values stay in local preferences/cache. They never enter a shared publication.
struct MidasUsageSyncEnvironmentIdentity: Sendable, Equatable {
    var deviceBinding: String?
    var cloudAccountFingerprint: String

    init(deviceBinding: String? = nil, cloudAccountFingerprint: String = "no-icloud-account") {
        self.deviceBinding = deviceBinding
        self.cloudAccountFingerprint = cloudAccountFingerprint
    }

    static func live() -> Self {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        var binding: String?
        if service != 0 {
            defer { IOObjectRelease(service) }
            if let identifier = IORegistryEntryCreateCFProperty(
                service,
                "IOPlatformUUID" as CFString,
                kCFAllocatorDefault,
                0)?.takeRetainedValue() as? String
            {
                binding = self.fingerprint(Data(("Midas local device v1:" + identifier).utf8))
            }
        }
        guard let token = FileManager.default.ubiquityIdentityToken else {
            return Self(deviceBinding: binding, cloudAccountFingerprint: "identity-unavailable")
        }
        return Self(
            deviceBinding: binding,
            cloudAccountFingerprint: self.cloudAccountFingerprint(token: token, defaults: .standard))
    }

    /// Apple defines account-token identity with isEqual, not the bytes of its archive.
    /// Keep a local stable label so caches do not depend on serialization order.
    static func cloudAccountFingerprint(
        token: (any NSCoding & NSObjectProtocol)?,
        defaults: UserDefaults) -> String
    {
        guard let token else { return "identity-unavailable" }
        if let data = defaults.data(forKey: "midasUsageSyncIdentityToken"),
           let decoder = try? NSKeyedUnarchiver(forReadingFrom: data)
        {
            decoder.requiresSecureCoding = false
            decoder.decodingFailurePolicy = .setErrorAndReturn
            let previous = decoder.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
            decoder.finishDecoding()
            if let previous, token.isEqual(previous),
               let fingerprint = defaults.string(forKey: "midasUsageSyncIdentityFingerprint")
            {
                return fingerprint
            }
        }
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false) else {
            return "identity-unavailable"
        }
        let fingerprint = "icloud-account-v2:" + UUID().uuidString
        defaults.set(data, forKey: "midasUsageSyncIdentityToken")
        defaults.set(fingerprint, forKey: "midasUsageSyncIdentityFingerprint")
        return fingerprint
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Owns explicit opt-in, an offline outbox and the received numeric view. Provider authentication stays elsewhere.
@MainActor
@Observable
final class MidasUsageSyncCoordinator {
    var isEnabled: Bool {
        didSet {
            self.defaults.set(self.isEnabled, forKey: "midasUsageSyncEnabled")
            if self.isEnabled { self.scheduleSync() } else { self.pause() }
        }
    }

    var includesSyncedUsage: Bool {
        didSet { self.defaults.set(self.includesSyncedUsage, forKey: "midasUsageSyncIncludeTotals") }
    }

    var deviceName: String {
        didSet { self.defaults.set(self.deviceName, forKey: "midasUsageSyncDeviceName") }
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
    var issue: String?
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
    private var syncDeviceID: UUID {
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
                try await MidasUsageSyncFolder.exchange(at: $0, workspace: $1, local: $2, now: $3)
            },
        hubConnectionURL: URL? = nil,
        hubWorkspaceLoader: @escaping @Sendable (
            MidasUsageHubConnection) async throws -> MidasUsageSyncWorkspace = {
            try await MidasUsageHubClient.workspace(connection: $0)
        },
        hubExchange: @escaping @Sendable (
            MidasUsageHubConnection, MidasUsageSyncWorkspace, MidasUsageSyncPublication?,
            Date) async throws -> MidasUsageHubExchange = {
            try await MidasUsageHubClient.exchange(connection: $0, workspace: $1, local: $2, now: $3)
        },
        currentTime: @escaping @MainActor () -> Date = { Date() },
        cacheWriter: @escaping @Sendable (Data, URL) throws -> Void = { try LocalPersistence.write($0, to: $1) })
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
        defaults.set(self.deviceID.uuidString, forKey: "midasUsageSyncDeviceID")
        if let binding = identity.deviceBinding { defaults.set(binding, forKey: "midasUsageSyncDeviceBinding") }
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
                await self?.syncNow()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    func scheduleSync() {
        guard self.automaticallySyncs, self.isEnabled, self.operation == nil else { return }
        let operationID = UUID()
        self.operationID = operationID
        self.operation = Task { [weak self] in
            defer {
                if self?.operationID == operationID {
                    self?.operation = nil
                    self?.operationID = nil
                }
            }
            await self?.syncNow()
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Connect Midas usage"
        panel.message = "Choose the same private folder on both Macs to share usage counts, costs, and device names."
        panel.prompt = "Connect"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            Task { @MainActor [weak self] in
                do { try await self?.connect(folder: folder) } catch is CancellationError {
                    return
                } catch { self?.issue = self?.message(error) }
            }
        }
    }

    func selectTransport(_ selected: MidasUsageSyncTransport) {
        guard selected != self.transport else { return }
        self.isEnabled = false
        self.pause()
        self.clearReceivedView()
        self.folderURL = nil
        self.hubConnection = nil
        self.workspace = nil
        self.accountFingerprint = nil
        self.transport = selected
        self.defaults.set(selected.rawValue, forKey: "midasUsageSyncTransport")
        self.status = selected == .folder ? "Choose a shared folder." : "Import this device’s hub connection file."
        self.issue = nil
    }

    func chooseHubConnection() {
        let panel = NSOpenPanel()
        panel.title = "Connect to your Tailscale hub"
        panel.message = "Choose the private Midas connection file created for this Mac."
        panel.prompt = "Connect"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let file = panel.url else { return }
            Task { @MainActor [weak self] in
                do { try await self?.connect(hubConnectionFile: file) } catch is CancellationError {
                    return
                } catch { self?.issue = self?.message(error) }
            }
        }
    }

    func connect(hubConnectionFile file: URL) async throws {
        let connection = try MidasUsageHubConnectionFile.load(at: file)
        try await self.connect(hub: connection)
    }

    /// Import is explicit. The private credential is stored only in a protected local file.
    func connect(hub connection: MidasUsageHubConnection) async throws {
        self.selectTransport(.tailscaleHub)
        self.isEnabled = false
        self.pause()
        let generation = self.generation
        let identity = self.environmentIdentity()
        guard identity.deviceBinding == self.deviceBinding,
              !self.automaticallySyncs || identity.deviceBinding != nil
        else {
            throw MidasUsageSyncError.folderUnavailable
        }
        try connection.validate()
        let selected = try await self.hubWorkspaceLoader(connection)
        try selected.validate()
        try Task.checkCancellation()
        guard self.generation == generation,
              self.environmentIdentity().deviceBinding == identity.deviceBinding else { throw CancellationError() }
        guard connection.workspaceID == nil || connection.workspaceID == selected.id else {
            throw MidasUsageSyncError.wrongWorkspace
        }
        if let previous = self.readCache(), previous.workspace.id == selected.id, previous.workspace != selected {
            throw MidasUsageSyncError.wrongWorkspace
        }
        let pinned = MidasUsageHubConnection(
            endpoint: connection.endpoint,
            deviceID: connection.deviceID,
            deviceName: connection.deviceName,
            credential: connection.credential,
            workspaceID: selected.id)
        try LocalPersistence.write(JSONEncoder().encode(pinned), to: self.hubConnectionURL)
        self.hubConnection = pinned
        self.workspace = selected
        self.folderURL = nil
        self.deviceName = connection.deviceName
        self.accountFingerprint = Self.hubFingerprint(pinned)
        self.clearReceivedView()
        self.restoreCache(expected: selected, acceptsExplicitReconnection: true)
        self.issue = nil
        self.isEnabled = true
        self.status = "Connected to your Tailscale hub. Waiting for usage."
        // Keep the pinned workspace available when the hub is offline after a restart.
        try await self.persistCache()
        try Task.checkCancellation()
        guard self.generation == generation, self.isEnabled else { throw CancellationError() }
        if self.automaticallySyncs { await self.syncNow() }
    }

    private func clearReceivedView() {
        self.received = []
        self.pendingLocal = nil
        self.snapshots = [:]
        self.devices = []
        self.lastPublishedAt = nil
        self.lastReceivedAt = nil
    }

    /// Also the test seam: callers must explicitly supply their isolated folder.
    func connect(folder: URL) async throws {
        self.selectTransport(.folder)
        self.isEnabled = false
        self.pause()
        let generation = self.generation
        let identity = self.environmentIdentity()
        guard identity.deviceBinding == self.deviceBinding,
              !self.automaticallySyncs || identity.deviceBinding != nil,
              identity.cloudAccountFingerprint != "identity-unavailable"
        else { throw MidasUsageSyncError.folderUnavailable }
        let selected = try await self.workspaceLoader(folder)
        try Task.checkCancellation()
        guard self.generation == generation, self.environmentIdentity() == identity else { throw CancellationError() }
        let bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        self.workspace = selected
        self.folderURL = folder
        self.defaults.set(bookmark, forKey: "midasUsageSyncFolderBookmark")
        self.defaults.set(selected.id.uuidString, forKey: "midasUsageSyncWorkspaceID")
        self.accountFingerprint = identity.cloudAccountFingerprint
        self.defaults.set(identity.cloudAccountFingerprint, forKey: "midasUsageSyncAccountFingerprint")
        self.received = []
        self.pendingLocal = nil
        self.snapshots = [:]
        self.devices = []
        self.lastPublishedAt = nil
        self.lastReceivedAt = nil
        self.restoreCache(expected: selected, acceptsExplicitReconnection: true)
        self.issue = nil
        self.isEnabled = true
        self.status = "Connected. Waiting for usage."
        if self.automaticallySyncs { await self.syncNow() }
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

    func syncNow() async {
        guard self.isEnabled, self.activeSync == nil, !Task.isCancelled else { return }
        let syncID = UUID()
        self.activeSyncID = syncID
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performSync()
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
    }

    private func performSync() async {
        guard self.isEnabled, !self.isSyncing, !Task.isCancelled else { return }
        guard self.identityStillMatches() else { return }
        if !self.hasConnection { self.restoreConnection() }
        guard await self.prepareHubWorkspaceIfNeeded() else { return }
        guard self.hasConnection, let workspace = self.workspace else {
            if self.issue == nil {
                self.status = self.transport == .folder
                    ? "Choose a shared folder to connect this Mac."
                    : "Import this device’s hub connection file."
            }
            return
        }
        guard let makeLocalUsage = self.makeLocalUsage else { return }
        self.isSyncing = true
        let generation = self.generation
        defer { if self.generation == generation { self.isSyncing = false } }
        guard await self.receiveInitialHubUsage(workspace: workspace, generation: generation) else { return }
        self.status = "Updating shared usage…"
        let collectionStartedAt = self.currentTime()
        do {
            let local = try await makeLocalUsage(workspace, collectionStartedAt)
            try Task.checkCancellation()
            guard self.generation == generation, self.isEnabled, self.identityStillMatches() else { return }
            // A first yearly scan can outlast provider refreshes. Publish against completion time.
            let now = self.currentTime()
            let previous = self.pendingLocal ?? self.received.first { $0.deviceID == self.syncDeviceID }
            // A repeated or slightly corrected wall clock must not let peers prefer an older local revision.
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
                previous: previous, fresh: fresh, workspaceID: workspace.id, now: now)
            try Task.checkCancellation()
            guard self.generation == generation, self.isEnabled, self.identityStillMatches() else { return }
            self.pendingLocal = publication
            do {
                try await self.persistCache()
                try Task.checkCancellation()
                guard self.generation == generation, self.isEnabled, self.identityStillMatches() else { return }
            } catch {
                guard self.generation == generation, !(error is CancellationError) else { return }
                self.issue = "This Mac could not preserve its offline sync history. No usage was shared."
                self.status = "Waiting to save this Mac’s usage locally. Showing last received usage."
                return
            }
            let result = try await self.exchangeUsage(workspace: workspace, publication: publication, now: now)
            guard result.workspace == workspace else { throw MidasUsageSyncError.wrongWorkspace }
            try Task.checkCancellation()
            guard self.generation == generation, self.isEnabled, self.workspace == workspace,
                  self.identityStillMatches() else { return }
            try await self.recordExchange(
                result, publication: publication, workspace: workspace, generation: generation)
        } catch {
            guard self.generation == generation else { return }
            if case MidasUsageSyncError.wrongWorkspace = error {
                self.invalidateConnection(message: self.message(error))
                return
            }
            if error is CancellationError { return }
            self.issue = self.message(error)
            self.status = "Sync unavailable. Showing last received usage."
        }
    }

    private func exchangeUsage(
        workspace: MidasUsageSyncWorkspace,
        publication: MidasUsageSyncPublication,
        now: Date) async throws -> MidasUsageSyncFolder.Result
    {
        switch self.transport {
        case .folder:
            guard let folder = self.folderURL else { throw MidasUsageSyncError.folderUnavailable }
            return try await self.exchangePublication(folder, workspace, publication, now)
        case .tailscaleHub:
            guard let connection = self.hubConnection else { throw MidasUsageSyncError.folderUnavailable }
            let exchange = try await self.hubExchange(connection, workspace, publication, now)
            return MidasUsageSyncFolder.Result(
                workspace: exchange.workspace,
                publications: exchange.publications,
                publicationSucceeded: exchange.publicationSucceeded,
                unavailableFiles: exchange.unavailableFiles,
                rejectedFiles: exchange.rejectedFiles)
        }
    }

    /// A first local scan can take minutes. Receive existing shared totals before beginning it.
    private func receiveInitialHubUsage(workspace: MidasUsageSyncWorkspace, generation: UUID) async -> Bool {
        guard self.transport == .tailscaleHub, self.received.isEmpty,
              let connection = self.hubConnection else { return true }
        self.status = "Receiving shared usage…"
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
                generation: generation)
            return true
        } catch {
            guard self.generation == generation, self.isEnabled else { return false }
            if error is CancellationError { return false }
            if case MidasUsageSyncError.wrongWorkspace = error {
                self.invalidateConnection(message: self.message(error))
                return false
            }
            // A failed read does not acknowledge or discard the offline outbox, or prevent local collection.
            self.issue = self.message(error)
            return true
        }
    }

    private func recordExchange(
        _ result: MidasUsageSyncFolder.Result,
        publication: MidasUsageSyncPublication?,
        workspace: MidasUsageSyncWorkspace,
        generation: UUID) async throws
    {
        let receivedAt = self.currentTime()
        var candidates = self.received + result.publications
        if let publication, result.publicationSucceeded { candidates.append(publication) }
        let ledger = try await self.worker.ledger(
            publications: candidates, workspaceID: workspace.id, now: receivedAt)
        try Task.checkCancellation()
        guard self.generation == generation, self.isEnabled, self.workspace == workspace,
              self.identityStillMatches() else { throw CancellationError() }
        let oldRemote = self.received.filter { $0.deviceID != self.syncDeviceID }
        let newRemote = ledger.publications.filter { $0.deviceID != self.syncDeviceID }
        if newRemote != oldRemote, !newRemote.isEmpty { self.lastReceivedAt = receivedAt }
        self.received = ledger.publications
        self.snapshots = ledger.snapshots
        self.devices = ledger.publications.map { value in
            MidasUsageSyncDeviceStatus(
                id: value.deviceID,
                name: value.deviceName,
                lastSeenAt: value.publishedAt,
                isThisMac: value.deviceID == self.syncDeviceID,
                eventCount: value.events.count + value.accountDays.count)
        }
        if publication != nil, result.publicationSucceeded {
            self.lastPublishedAt = receivedAt
            self.pendingLocal = nil
        }
        self.issue = Self.coverageIssue(result: result, ledger: ledger)
        if publication == nil {
            self.status = "Shared usage received. Preparing this Mac’s usage."
        } else if !result.publicationSucceeded {
            self.status = "Shared usage received. This Mac’s changes are waiting to save."
        } else if newRemote.isEmpty {
            self.status = self.transport == .folder
                ? "Saved on this Mac. Waiting for another Mac’s usage."
                : "Saved to your hub. Waiting for another device’s usage."
        } else {
            let deviceKind = self.transport == .folder ? "Macs" : "devices"
            self.status = "Shared usage from \(ledger.publications.count) \(deviceKind)."
        }
        do {
            try await self.persistCache()
            try Task.checkCancellation()
            guard self.generation == generation, self.isEnabled else { throw CancellationError() }
        } catch {
            guard self.generation == generation, !(error is CancellationError) else { throw CancellationError() }
            if let publication { self.pendingLocal = publication }
            self.issue = "Shared history could not be saved locally. Last received usage remains visible."
        }
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
        self.status = "Sync is paused."
    }

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
        self.restoreCache(cache, expected: cache.workspace)
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

    private func restoreCache(expected: MidasUsageSyncWorkspace, acceptsExplicitReconnection: Bool = false) {
        guard let cache = self.readCache() else { return }
        self.restoreCache(cache, expected: expected, acceptsExplicitReconnection: acceptsExplicitReconnection)
    }

    private func restoreCache(
        _ cache: Cache, expected: MidasUsageSyncWorkspace, acceptsExplicitReconnection: Bool = false)
    {
        guard cache.workspace == expected,
              cache.localDeviceID == self.syncDeviceID, cache.deviceBinding == self.deviceBinding,
              cache.accountFingerprint == self.accountFingerprint || acceptsExplicitReconnection,
              let ledger = try? autoreleasepool(invoking: {
                  try MidasUsageSyncLedger(
                      publications: cache.publications,
                      workspaceID: expected.id,
                      now: self.currentTime())
              })
        else { return }
        if let pending = cache.pendingLocal {
            guard pending.deviceID == self.syncDeviceID,
                  (try? pending.validate(workspaceID: expected.id, now: self.currentTime())) != nil else { return }
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
                    self.hubConnection = nil
                    self.issue = "The saved hub history could not be validated. Import the connection file again."
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
            self.restoreCache(cache, expected: cache.workspace)
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
        return Darwin.lstat(url.path, &metadata) != 0 && errno == ENOENT
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
            guard self.hasNoCacheFile() else {
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
            try LocalPersistence.write(JSONEncoder().encode(pinned), to: self.hubConnectionURL)
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
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(MidasIdentity.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("usage-sync", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    private func message(_ error: Error) -> String {
        if self.transport == .tailscaleHub {
            if case MidasUsageSyncError.wrongWorkspace = error {
                return "The hub’s workspace changed. Import a new connection file to reconnect."
            }
            if let hubError = error as? MidasUsageHubError {
                switch hubError {
                case .unauthorized:
                    return "This device’s hub access was rejected. Import a new connection file. " +
                        "Last received usage is retained."
                case .invalidConnection, .unsafeConnectionFile:
                    return "This connection file is invalid or is not private. Import the file created for this Mac."
                case .rejectedSnapshot:
                    return "This device’s history changed on the hub. Local changes are saved and will retry."
                case .invalidResponse, .responseTooLarge:
                    return "Usage from the hub could not be validated. Last received usage is retained."
                case .unavailable: break
                }
            }
            return "Your Tailscale hub is unavailable. Check Tailscale and that the Mac mini is awake. " +
                "Last received usage is retained and new usage will retry."
        }
        if let error = error as? MidasUsageSyncError { return error.localizedDescription }
        return "The shared folder is unavailable. Check access and retry."
    }

    private static func coverageIssue(result: MidasUsageSyncFolder.Result, ledger: MidasUsageSyncLedger) -> String? {
        if result.rejectedFiles > 0 { return "Some device files could not be validated and were excluded." }
        if result
            .unavailableFiles >
            0 { return "Some device files are still downloading. Last received history is retained." }
        if ledger.excludedRecords > 0 { return "Some activity lacked a stable identity or timestamp and was excluded." }
        return nil
    }
}

extension MidasUsageSyncCoordinator {
    private struct Cache: Codable, Sendable {
        var schemaVersion = 2
        let localDeviceID: UUID
        let deviceBinding: String?
        let accountFingerprint: String
        let workspace: MidasUsageSyncWorkspace
        let publications: [MidasUsageSyncPublication]
        let pendingLocal: MidasUsageSyncPublication?
        let lastPublishedAt: Date?
        let lastReceivedAt: Date?
    }

    /// Serializes large transient graphs and disk writes away from the UI executor.
    /// Callers check cancellation and connection generation before applying results.
    private actor Worker {
        let write: @Sendable (Data, URL) throws -> Void

        init(write: @escaping @Sendable (Data, URL) throws -> Void) {
            self.write = write
        }

        func retain(
            previous: MidasUsageSyncPublication?,
            fresh: MidasUsageSyncPublication,
            workspaceID: UUID,
            now: Date) throws -> MidasUsageSyncPublication
        {
            try Task.checkCancellation()
            return try autoreleasepool {
                let publication = MidasUsageSyncLedger.retainingLocalHistory(previous: previous, fresh: fresh)
                try publication.validate(workspaceID: workspaceID, now: now)
                return publication
            }
        }

        func ledger(
            publications: [MidasUsageSyncPublication], workspaceID: UUID, now: Date) throws -> MidasUsageSyncLedger
        {
            try Task.checkCancellation()
            return try autoreleasepool {
                try MidasUsageSyncLedger(publications: publications, workspaceID: workspaceID, now: now)
            }
        }

        func persist(_ cache: Cache, to url: URL) throws {
            try Task.checkCancellation()
            try autoreleasepool {
                let data = try JSONEncoder().encode(cache)
                try Task.checkCancellation()
                try self.write(data, url)
            }
        }
    }

    private func readCache() -> Cache? {
        autoreleasepool {
            guard let url = self.cacheURL,
                  let data = try? LocalPersistence.read(url),
                  let envelope = try? MidasUsageSyncCodec.decodeEnvelope(data),
                  let metadata = try? JSONDecoder().decode(Cache.self, from: envelope.metadata),
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
        try await self.worker.persist(cache, to: url)
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

/// Internal cache IO never follows a link, even if an ancestor is changed during a write.
private enum LocalPersistence {
    private static let maximumBytes = 128 * 1024 * 1024

    static func read(_ url: URL) throws -> Data {
        let parent = try self.directory(url.deletingLastPathComponent(), create: false)
        defer { Darwin.close(parent) }
        let descriptor = Darwin.openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw MidasUsageSyncError.folderUnavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
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
        let parent = try self.directory(url.deletingLastPathComponent(), create: true)
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
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
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

    private static func directory(_ url: URL, create: Bool) throws -> Int32 {
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

private final class MidasSyncAccountObservation: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(onChange: @escaping @Sendable () -> Void) {
        self.token = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main) { _ in onChange() }
    }

    deinit { NotificationCenter.default.removeObserver(self.token) }
}
