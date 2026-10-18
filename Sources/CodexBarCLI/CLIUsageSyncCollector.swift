import CodexBarCore
import Foundation

/// Value-only transport seam keeps offline and replay checks independent of live provider accounts.
struct MidasUsageCollectorTransport: Sendable {
    struct Exchange: Sendable {
        let workspace: MidasUsageSyncWorkspace
        let publications: [MidasUsageSyncPublication]
        let publicationSucceeded: Bool
        let unavailableFiles: Int
        let rejectedFiles: Int
    }

    var workspace: @Sendable (MidasUsageHubConnection) async throws -> MidasUsageSyncWorkspace
    var exchange: @Sendable (
        MidasUsageHubConnection, MidasUsageSyncWorkspace, MidasUsageSyncPublication, Date) async throws -> Exchange

    static let live = Self(
        workspace: { try await MidasUsageHubClient.workspace(connection: $0) },
        exchange: { connection, workspace, local, now in
            let result = try await MidasUsageHubClient.exchange(
                connection: connection, workspace: workspace, local: local, now: now)
            return Exchange(
                workspace: result.workspace,
                publications: result.publications,
                publicationSucceeded: result.publicationSucceeded,
                unavailableFiles: result.unavailableFiles,
                rejectedFiles: result.rejectedFiles)
        })
}

struct MidasUsageCollector: Sendable {
    struct Options: Sendable {
        let stateRoot: URL
        var providers: [UsageProvider] = [.codex, .claude, .meta]
        var export = MidasUsageSyncExporter.Options()
    }

    struct Status: Encodable, Sendable {
        let state: String
        let collectedAt: Date
        let lastSuccessfulExchangeAt: Date?
        let publicationSucceeded: Bool
        let localRecords: Int
        let mergedRecords: Int
        let devices: Int
        let excludedRecords: Int
        let unavailableFiles: Int
        let rejectedFiles: Int
        let coverage = "Supported local numeric logs only. Missing and unsupported sources remain unknown."
    }

    struct Received: Codable, Sendable {
        let workspace: MidasUsageSyncWorkspace
        let publications: [MidasUsageSyncPublication]
        let lastSuccessfulExchangeAt: Date?
    }

    enum CollectorError: Error {
        case invalidProviders
        case changedWorkspace
        case changedDevice
        case workspaceUnavailable
    }

    let options: Options
    var transport: MidasUsageCollectorTransport = .live

    static func defaultStateRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        #if os(macOS)
        home.appendingPathComponent("Library/Application Support/\(MidasIdentity.supportDirectoryName)/usage-collector")
        #else
        home.appendingPathComponent(".local/share/midas/usage-collector")
        #endif
    }

    static func parseProviders(_ value: String?) throws -> [UsageProvider] {
        guard let value else { return [.codex, .claude, .meta] }
        let names = value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let supported: [String: UsageProvider] = ["codex": .codex, "claude": .claude, "meta": .meta]
        guard !names.isEmpty, names.allSatisfy({ supported[$0] != nil }) else {
            throw CollectorError.invalidProviders
        }
        return Array(Set(names.compactMap { supported[$0] })).sorted { $0.rawValue < $1.rawValue }
    }

    func collect(connection: MidasUsageHubConnection, now: Date = Date()) async throws -> Status {
        try connection.validate()
        let store = try MidasUsageCollectorStorage(root: self.options.stateRoot)
        let cycleLock = try store.lock()
        defer { try? cycleLock.close() }
        let previous: MidasUsageSyncPublication? = try store.load("outbox.json")
        let received: Received? = try store.load("received.json", maximumBytes: 128 * 1024 * 1024)
        if let previous, previous.deviceID != connection.deviceID { throw CollectorError.changedDevice }
        let workspace = try await self.workspace(connection: connection, received: received)
        if let previous {
            try previous.validate(workspaceID: workspace.id, now: now)
        }
        let cached = received?.publications ?? []
        _ = try MidasUsageSyncLedger(publications: cached, workspaceID: workspace.id, now: now)
        // Persist the shared salt before scanning. An offline restart must generate identical event identities.
        try store.save(
            Received(
                workspace: workspace,
                publications: cached,
                lastSuccessfulExchangeAt: received?.lastSuccessfulExchangeAt),
            name: "received.json",
            maximumBytes: 128 * 1024 * 1024)
        let exported = try await MidasUsageSyncExporter.export(
            workspace: workspace, providers: self.options.providers, now: now, options: self.options.export)
        let cachedOwn = cached.first { $0.deviceID == connection.deviceID }
        let ownHistory = previous.map {
            MidasUsageSyncLedger.retainingLocalHistory(previous: cachedOwn, fresh: $0)
        } ?? cachedOwn
        let publishedAt = max(now, (ownHistory?.publishedAt ?? .distantPast).addingTimeInterval(0.001))
        let fresh = MidasUsageSyncPublication(
            workspaceID: workspace.id,
            deviceID: connection.deviceID,
            deviceName: connection.deviceName,
            publishedAt: publishedAt,
            events: exported.events,
            excludedRecords: exported.excludedRecords)
        let local = MidasUsageSyncLedger.retainingLocalHistory(previous: ownHistory, fresh: fresh)
        try local.validate(workspaceID: workspace.id, now: now)
        // A network attempt can only happen after the complete numeric outbox is durable.
        try store.save(local, name: "outbox.json")
        var publications = cached
        var publicationSucceeded = false
        var lastSuccessfulExchangeAt = received?.lastSuccessfulExchangeAt
        var unavailableFiles = 0
        var rejectedFiles = 0
        var state = "offline"
        do {
            let result = try await self.transport.exchange(connection, workspace, local, now)
            guard result.workspace == workspace else { throw CollectorError.changedWorkspace }
            let merged = try MidasUsageSyncLedger(
                publications: cached + result.publications + [local], workspaceID: workspace.id, now: now)
            publications = merged.publications
            publicationSucceeded = result.publicationSucceeded
            unavailableFiles = result.unavailableFiles
            rejectedFiles = result.rejectedFiles
            if publicationSucceeded { lastSuccessfulExchangeAt = now }
            state = publicationSucceeded ? "synced" : "pending"
            try store.save(
                Received(
                    workspace: workspace,
                    publications: publications,
                    lastSuccessfulExchangeAt: lastSuccessfulExchangeAt),
                name: "received.json",
                maximumBytes: 128 * 1024 * 1024)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The outbox and last-good received publications remain intact. Never replace totals with zero.
            publicationSucceeded = false
            state = "offline"
        }
        let ledger = try MidasUsageSyncLedger(
            publications: publications + [local], workspaceID: workspace.id, now: now)
        return Status(
            state: state,
            collectedAt: now,
            lastSuccessfulExchangeAt: lastSuccessfulExchangeAt,
            publicationSucceeded: publicationSucceeded,
            localRecords: local.events.count + local.accountDays.count,
            mergedRecords: ledger.publications.reduce(0) { $0 + $1.events.count + $1.accountDays.count },
            devices: ledger.publications.count,
            excludedRecords: ledger.excludedRecords,
            unavailableFiles: unavailableFiles,
            rejectedFiles: rejectedFiles)
    }

    private func workspace(
        connection: MidasUsageHubConnection, received: Received?) async throws -> MidasUsageSyncWorkspace
    {
        let candidate: MidasUsageSyncWorkspace
        do {
            candidate = try await self.transport.workspace(connection)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard let received else { throw CollectorError.workspaceUnavailable }
            candidate = received.workspace
        }
        try candidate.validate()
        guard connection.workspaceID == nil || connection.workspaceID == candidate.id,
              received?.workspace == nil || received?.workspace == candidate
        else { throw CollectorError.changedWorkspace }
        return candidate
    }
}
