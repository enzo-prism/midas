import AppKit
import CodexBarCore
import CryptoKit
import Darwin
import Foundation
import IOKit
import Observation

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

    var folderURL: URL?
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

    private struct Cache: Codable {
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
        currentTime: @escaping @MainActor () -> Date = { Date() })
    {
        self.defaults = defaults
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
        let identity = identityProvider()
        self.deviceBinding = identity.deviceBinding
        self.persistenceURL = persistenceURL ?? (automaticallySyncs ? Self.defaultPersistenceURL : nil)
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
                    message: "This Mac’s sync identity is unavailable. Choose the folder again to reconnect.")
        } else if copiedIdentity, self.isEnabled {
            self
                .invalidateConnection(
                    message: "This sync connection was copied from another Mac. Choose the folder again.")
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
                } catch { self?.issue = Self.message(error) }
            }
        }
    }

    /// Also the test seam: callers must explicitly supply their isolated folder.
    func connect(folder: URL) async throws {
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
        self.workspace = nil
        self.received = []
        self.pendingLocal = nil
        self.snapshots = [:]
        self.devices = []
        self.lastPublishedAt = nil
        self.lastReceivedAt = nil
        self.defaults.removeObject(forKey: "midasUsageSyncFolderBookmark")
        self.defaults.removeObject(forKey: "midasUsageSyncWorkspaceID")
        self.defaults.removeObject(forKey: "midasUsageSyncAccountFingerprint")
        self.accountFingerprint = nil
        self.status = "Disconnected. Shared history remains in the folder."
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
        if self.folderURL == nil { self.restoreConnection() }
        guard let folder = self.folderURL, let workspace = self.workspace else {
            if self.issue == nil { self.status = "Choose a shared folder to connect this Mac." }
            return
        }
        guard let makeLocalUsage = self.makeLocalUsage else { return }
        self.isSyncing = true
        self.status = "Updating shared usage…"
        let generation = self.generation
        defer { if self.generation == generation { self.isSyncing = false } }
        let collectionStartedAt = self.currentTime()
        do {
            let local = try await makeLocalUsage(workspace, collectionStartedAt)
            try Task.checkCancellation()
            guard self.generation == generation, self.isEnabled, self.identityStillMatches() else { return }
            // A first yearly scan can outlast provider refreshes. Publish against completion time.
            let now = self.currentTime()
            let previous = self.pendingLocal ?? self.received.first { $0.deviceID == self.deviceID }
            // A repeated or slightly corrected wall clock must not let peers prefer an older local revision.
            let publishedAt = previous.map { max(now, $0.publishedAt.addingTimeInterval(0.001)) } ?? now
            let fresh = MidasUsageSyncPublication(
                workspaceID: workspace.id,
                deviceID: self.deviceID,
                deviceName: Self.safeDeviceName(self.deviceName),
                publishedAt: publishedAt,
                events: local.events,
                accountDays: local.accountDays,
                excludedRecords: local.excludedRecords)
            let publication = MidasUsageSyncLedger.retainingLocalHistory(previous: previous, fresh: fresh)
            try publication.validate(workspaceID: workspace.id, now: now)
            self.pendingLocal = publication
            do {
                try self.persistCache()
            } catch {
                self.issue = "This Mac could not preserve its offline sync history. No usage was shared."
                self.status = "Waiting to save this Mac’s usage locally. Showing last received usage."
                return
            }
            let result = try await self.exchangePublication(folder, workspace, publication, now)
            try Task.checkCancellation()
            guard self.generation == generation, self.isEnabled, self.workspace == workspace,
                  self.identityStillMatches() else { return }
            let receivedAt = self.currentTime()
            var candidates = self.received + result.publications
            if result.publicationSucceeded { candidates.append(publication) }
            let ledger = try MidasUsageSyncLedger(publications: candidates, workspaceID: workspace.id, now: receivedAt)
            let oldRemote = self.received.filter { $0.deviceID != self.deviceID }
            let newRemote = ledger.publications.filter { $0.deviceID != self.deviceID }
            if newRemote != oldRemote, !newRemote.isEmpty { self.lastReceivedAt = receivedAt }
            self.received = ledger.publications
            self.snapshots = ledger.snapshots
            self.devices = ledger.publications.map { value in
                MidasUsageSyncDeviceStatus(
                    id: value.deviceID,
                    name: value.deviceName,
                    lastSeenAt: value.publishedAt,
                    isThisMac: value.deviceID == self.deviceID,
                    eventCount: value.events.count + value.accountDays.count)
            }
            if result.publicationSucceeded {
                self.lastPublishedAt = receivedAt
                self.pendingLocal = nil
            }
            self.issue = Self.coverageIssue(result: result, ledger: ledger)
            if !result.publicationSucceeded {
                self.status = "Shared usage received. This Mac’s changes are waiting to save."
            } else if newRemote.isEmpty {
                self.status = "Saved on this Mac. Waiting for another Mac’s usage."
            } else {
                self.status = "Shared usage from \(ledger.publications.count) Macs."
            }
            do {
                try self.persistCache()
            } catch {
                self.pendingLocal = publication
                self.issue = "Usage was saved to the folder, but this Mac could not preserve its offline history."
            }
        } catch {
            guard self.generation == generation else { return }
            if case MidasUsageSyncError.wrongWorkspace = error {
                self.invalidateConnection(message: Self.message(error))
                return
            }
            if error is CancellationError { return }
            self.issue = Self.message(error)
            self.status = "Sync unavailable. Showing last received usage."
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
        if self.folderURL == nil { self.restoreConnection() }
        self.scheduleSync()
    }

    private func invalidateConnection(message: String) {
        self.disconnect()
        self.issue = message
        self.status = "Sync disconnected. Choose the shared folder again."
    }

    private func identityStillMatches() -> Bool {
        let current = self.environmentIdentity()
        guard current.deviceBinding == self.deviceBinding else {
            self
                .invalidateConnection(
                    message: "This Mac’s sync identity changed. Choose the folder again to reconnect.")
            return false
        }
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
        guard self.isEnabled, let data = self.defaults.data(forKey: "midasUsageSyncFolderBookmark"),
              let expectedID = self.defaults.string(forKey: "midasUsageSyncWorkspaceID").flatMap(UUID.init(uuidString:))
        else { return }
        guard self.identityStillMatches(),
              let fingerprint = self.defaults.string(forKey: "midasUsageSyncAccountFingerprint") else { return }
        self.accountFingerprint = fingerprint
        guard let cache = self.readCache(), cache.workspace.id == expectedID,
              cache.localDeviceID == self.deviceID, cache.deviceBinding == self.deviceBinding,
              cache.accountFingerprint == fingerprint
        else {
            self.issue = "Choose your shared folder again to restore this connection."
            return
        }
        self.workspace = cache.workspace
        self.restoreCache(expected: cache.workspace)
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
        guard let cache = self.readCache(), cache.workspace == expected,
              cache.localDeviceID == self.deviceID, cache.deviceBinding == self.deviceBinding,
              cache.accountFingerprint == self.accountFingerprint || acceptsExplicitReconnection,
              let ledger = try? MidasUsageSyncLedger(
                  publications: cache.publications,
                  workspaceID: expected.id,
                  now: self.currentTime())
        else { return }
        if let pending = cache.pendingLocal {
            guard pending.deviceID == self.deviceID,
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
                isThisMac: $0.deviceID == self.deviceID,
                eventCount: $0.events.count + $0.accountDays.count)
        }
    }

    private func readCache() -> Cache? {
        guard let url = self.persistenceURL,
              let data = try? LocalPersistence.read(url), let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.schemaVersion == 2, (try? cache.workspace.validate()) != nil,
              cache.accountFingerprint.utf8.count <= 128, (cache.deviceBinding?.utf8.count ?? 0) <= 128
        else { return nil }
        return cache
    }

    private func persistCache() throws {
        guard let url = self.persistenceURL, let workspace, let accountFingerprint else {
            throw MidasUsageSyncError.folderUnavailable
        }
        let cache = Cache(
            localDeviceID: self.deviceID,
            deviceBinding: self.deviceBinding,
            accountFingerprint: accountFingerprint,
            workspace: workspace,
            publications: self.received,
            pendingLocal: self.pendingLocal,
            lastPublishedAt: self.lastPublishedAt,
            lastReceivedAt: self.lastReceivedAt)
        try LocalPersistence.write(JSONEncoder().encode(cache), to: url)
    }

    private static var defaultPersistenceURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(MidasIdentity.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("usage-sync", isDirectory: true)
            .appendingPathComponent("state.json")
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

    private static func message(_ error: Error) -> String {
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
