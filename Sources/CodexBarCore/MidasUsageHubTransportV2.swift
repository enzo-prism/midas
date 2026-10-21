#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Immutable pages are written before the selected checkpoint; app receipts remain an explicit second phase.
enum MidasUsageHubTransportV2 {
    static let maximumPageBytes = 1024 * 1024
    static let maximumPublicationBytes = 512 * 1024 * 1024

    private struct Context {
        let connection: MidasUsageHubConnection
        let workspace: MidasUsageSyncWorkspace
        let now: Date
        let storage: MidasUsageHubV2Storage
    }

    static func exchange(
        connection: MidasUsageHubConnection,
        workspace: MidasUsageSyncWorkspace,
        local: MidasUsageSyncPublication?,
        now: Date,
        stateRoot: URL?) async throws -> MidasUsageHubExchange
    {
        let initialManifest = try await self.manifest(
            connection: connection,
            workspace: workspace,
            allowUnsupported: true)
        let storage = try MidasUsageHubV2Storage(
            root: stateRoot ?? MidasUsageHubV2Storage.defaultRoot(),
            workspaceID: workspace.id,
            deviceID: connection.deviceID)
        try TransportLocks.shared.acquire(storage.root.path)
        defer { TransportLocks.shared.release(storage.root.path) }
        let lock = try storage.lock()
        defer { try? lock.close() }
        var index = try storage.loadIndex(workspace: workspace, deviceID: connection.deviceID)
        for attempt in 0..<2 {
            do {
                return try await self.perform(
                    context: Context(connection: connection, workspace: workspace, now: now, storage: storage),
                    local: local,
                    index: &index,
                    initialManifest: attempt == 0 ? initialManifest : nil)
            } catch MidasUsageHubError.revisionExpired where attempt == 0 {
                continue
            } catch MidasUsageHubError.rejectedSnapshot where attempt == 0 {
                // A concurrent writer won CAS. Retain staged data and reconcile the new own head.
                continue
            }
        }
        throw MidasUsageHubError.rejectedSnapshot
    }

    private static func perform(
        context: Context,
        local: MidasUsageSyncPublication?,
        index: inout MidasUsageHubV2Storage.Index,
        initialManifest: MidasUsageHubV2Manifest?) async throws -> MidasUsageHubExchange
    {
        let connection = context.connection
        let workspace = context.workspace
        let now = context.now
        let storage = context.storage
        var manifest: MidasUsageHubV2Manifest = if let initialManifest {
            initialManifest
        } else {
            try await self.manifest(connection: connection, workspace: workspace)
        }
        let required = Set(index.heads.flatMap(\.pages).map(\.digest)
            + (index.pendingUpload?.pages.map(\.digest) ?? []) + manifest.devices.flatMap(\.pages).map(\.digest))
        try storage.prunePages(keeping: required)
        var downloaded = 0
        var uploaded = 0
        var accepted = false
        if let local {
            let own = manifest.devices.first { $0.deviceID == connection.deviceID }
            let previous = try await own.asyncMap {
                try await self.publication(
                    $0,
                    context: context,
                    downloaded: &downloaded)
            }
            var retained = try MidasUsageSyncLedger.retainingCanonicalHistory(previous: previous, fresh: local)
            if let pending = index.pendingUpload {
                let staged = try self.stagedPublication(pending, storage: storage)
                retained = try MidasUsageSyncLedger.retainingCanonicalHistory(previous: staged, fresh: retained)
            }
            guard retained.events.count + retained.accountDays.count <= manifest.limits.publicationRecords else {
                throw MidasUsageHubError.responseTooLarge
            }
            // A heartbeat does not re-encode or rewrite unchanged historical pages.
            if let previous, self.semanticEqual(previous, retained), index.pendingUpload == nil {
                index.acceptedRevision = own?.revision
                accepted = true
            } else {
                let prepared = try self.prepare(retained, maximumBytes: manifest.limits.pageBytes, storage: storage)
                let expected = own?.revision ?? 0
                let fingerprint = try self.fingerprint(header: prepared.header, pages: prepared.pages)
                if let previous, self.semanticEqual(previous, retained) {
                    index.acceptedFingerprint = fingerprint
                    index.acceptedRevision = own?.revision
                    accepted = true
                    index.pendingUpload = nil
                    index.pendingFingerprint = nil
                    try storage.saveIndex(index)
                } else {
                    let pending = index.pendingUpload
                    let upload: MidasUsageHubV2Upload
                    if let pending, pending.expectedRevision == expected, index.pendingFingerprint == fingerprint {
                        upload = pending
                    } else {
                        upload = MidasUsageHubV2Upload(
                            uploadID: UUID(),
                            expectedRevision: expected,
                            header: prepared.header,
                            pages: prepared.pages)
                        index.pendingUpload = upload
                        index.pendingFingerprint = fingerprint
                        try storage.saveIndex(index)
                    }
                    let receipt = try await self.upload(
                        upload,
                        connection: connection,
                        storage: storage,
                        count: &uploaded)
                    guard receipt.deviceID == connection.deviceID, receipt.revision > 0,
                          receipt.publicationSucceeded, MidasUsageHubV2Storage.validDigest(receipt.digest),
                          receipt.acceptedAt.timeIntervalSinceReferenceDate.isFinite
                    else { throw MidasUsageHubError.invalidResponse }
                    index.acceptedFingerprint = fingerprint
                    index.acceptedRevision = receipt.revision
                    index.pendingUpload = nil
                    index.pendingFingerprint = nil
                    try storage.saveIndex(index)
                    accepted = true
                    manifest = try await self.manifest(connection: connection, workspace: workspace)
                }
            }
        }
        var publications: [MidasUsageSyncPublication] = []
        var totalRecords = 0
        for head in manifest.devices {
            let publication = try await self.publication(
                head, context: context, downloaded: &downloaded)
            totalRecords += publication.events.count + publication.accountDays.count
            guard totalRecords <= MidasUsageSyncPublication.maximumCanonicalRecords else {
                throw MidasUsageHubError.responseTooLarge
            }
            publications.append(publication)
        }
        index.heads = manifest.devices
        try storage.saveIndex(index)
        let state = MidasUsageHubSyncState(
            hubVersion: manifest.hubVersion,
            checkedAt: manifest.checkedAt,
            appliedRevisions: Dictionary(uniqueKeysWithValues: manifest.devices.map { (
                $0.deviceID.uuidString,
                $0.revision) }),
            acceptedLocalRevision: accepted ? index.acceptedRevision : nil,
            devices: manifest.devices.map {
                MidasUsageHubDeviceRevision(
                    deviceID: $0.deviceID,
                    deviceName: $0.deviceName,
                    revision: $0.revision,
                    publishedAt: $0.header.publishedAt,
                    supportsReceipts: $0.supportsReceipts ?? false,
                    isRevoked: $0.revoked)
            },
            peers: self.peers(manifest),
            uploadedPages: uploaded,
            downloadedPages: downloaded)
        return MidasUsageHubExchange(
            workspace: workspace,
            publications: publications,
            publicationSucceeded: accepted,
            unavailableFiles: 0,
            rejectedFiles: 0,
            syncState: state)
    }

    static func acknowledge(
        connection: MidasUsageHubConnection,
        workspace: MidasUsageSyncWorkspace,
        state: MidasUsageHubSyncState,
        stateRoot: URL?) async throws -> [MidasUsageHubPeerReceipt]
    {
        guard state.protocolVersion == 2 else { throw MidasUsageHubError.incompatibleProtocol }
        let storage = try MidasUsageHubV2Storage(
            root: stateRoot ?? MidasUsageHubV2Storage.defaultRoot(),
            workspaceID: workspace.id,
            deviceID: connection.deviceID)
        try TransportLocks.shared.acquire(storage.root.path)
        defer { TransportLocks.shared.release(storage.root.path) }
        let lock = try storage.lock()
        defer { try? lock.close() }
        let index = try storage.loadIndex(workspace: workspace, deviceID: connection.deviceID)
        let selected = Dictionary(uniqueKeysWithValues: index.heads.map { ($0.deviceID.uuidString, $0.revision) })
        guard state.appliedRevisions.allSatisfy({ key, value in value > 0 && (selected[key] ?? 0) >= value }) else {
            throw MidasUsageHubError.invalidResponse
        }
        let body = try JSONEncoder().encode(["appliedRevisions": state.appliedRevisions])
        let result = try await MidasUsageHubClient.request(
            connection: connection,
            path: "v2/receipt",
            body: body,
            limit: 32768)
        let receipt = try self.decode(MidasUsageHubV2Receipt.self, result)
        guard receipt.deviceID == connection.deviceID,
              state.appliedRevisions.allSatisfy({ (receipt.appliedRevisions[$0.key] ?? 0) >= $0.value })
        else {
            throw MidasUsageHubError.invalidResponse
        }
        let manifest = try await self.manifest(connection: connection, workspace: workspace)
        let kept = Set(index.heads.flatMap(\.pages).map(\.digest) + (index.pendingUpload?.pages.map(\.digest) ?? []))
        try storage.prunePages(keeping: kept)
        return self.peers(manifest)
    }

    static func manifest(
        connection: MidasUsageHubConnection,
        workspace: MidasUsageSyncWorkspace,
        allowUnsupported: Bool = false) async throws -> MidasUsageHubV2Manifest
    {
        let data = try await MidasUsageHubClient.request(
            connection: connection,
            path: "v2/manifest",
            body: nil,
            limit: 16 * 1024 * 1024,
            notFoundError: allowUnsupported ? .unsupportedProtocol : .invalidResponse)
        let result = try self.decode(MidasUsageHubV2Manifest.self, data)
        guard result.protocolVersion == 2 else { throw MidasUsageHubError.incompatibleProtocol }
        guard result.workspace == workspace else { throw MidasUsageSyncError.wrongWorkspace }
        guard (1...self.maximumPageBytes).contains(result.limits.pageBytes),
              (1...MidasUsageSyncPublication.maximumCanonicalRecords).contains(result.limits.publicationRecords),
              (1...self.maximumPublicationBytes).contains(result.limits.publicationBytes),
              result.devices.count <= MidasUsageHubClient.maximumDevices,
              Set(result.devices.map(\.deviceID)).count == result.devices.count,
              result.receipts.count <= MidasUsageHubClient.maximumDevices,
              result.checkedAt.timeIntervalSinceReferenceDate.isFinite else { throw MidasUsageHubError.invalidResponse }
        var checkpointBytes = 0
        var checkpointRecords = 0
        for head in result.devices {
            guard head.revision > 0, head.deviceID == head.header.deviceID,
                  head.deviceName == head.header.deviceName, head.header.workspaceID == workspace.id,
                  head.header.schemaVersion == 1, MidasUsageHubV2Storage.validDigest(head.digest),
                  head.eventCount >= 0, head.accountDayCount >= 0,
                  head.eventCount <= result.limits.publicationRecords - head.accountDayCount,
                  head.pages.count <= 10000,
                  Set(head.pages.map(\.digest)).count == head.pages.count
            else { throw MidasUsageHubError.invalidResponse }
            var bytes = 0
            var events = 0
            var accounts = 0
            for page in head.pages {
                guard MidasUsageHubV2Storage.validDigest(page.digest),
                      (1...result.limits.pageBytes).contains(page.byteCount),
                      page.eventCount >= 0, page.accountDayCount >= 0,
                      page.eventCount <= result.limits.publicationRecords - page.accountDayCount
                else {
                    throw MidasUsageHubError.invalidResponse
                }
                bytes += page.byteCount
                events += page.eventCount
                accounts += page.accountDayCount
                guard bytes <= result.limits.publicationBytes,
                      events + accounts <= result.limits.publicationRecords
                else {
                    throw MidasUsageHubError.responseTooLarge
                }
            }
            guard events == head.eventCount,
                  accounts == head.accountDayCount else { throw MidasUsageHubError.invalidResponse }
            checkpointBytes += bytes
            checkpointRecords += events + accounts
            guard checkpointBytes <= 1024 * 1024 * 1024,
                  checkpointRecords <= MidasUsageSyncPublication.maximumCanonicalRecords
            else {
                throw MidasUsageHubError.responseTooLarge
            }
        }
        let revisions = Dictionary(uniqueKeysWithValues: result.devices.map { ($0.deviceID.uuidString, $0.revision) })
        guard Set(result.receipts.map(\.deviceID)).count == result.receipts.count else {
            throw MidasUsageHubError.invalidResponse
        }
        for receipt in result.receipts {
            guard receipt.checkedAt.timeIntervalSinceReferenceDate.isFinite,
                  receipt.appliedRevisions.count <= MidasUsageHubClient.maximumDevices,
                  receipt.appliedRevisions.allSatisfy({ key, value in
                      UUID(uuidString: key)?.uuidString == key && value > 0 && value <= (revisions[key] ?? 0)
                  }) else { throw MidasUsageHubError.invalidResponse }
        }
        return result
    }

    private static func publication(
        _ head: MidasUsageHubV2Head,
        context: Context,
        downloaded: inout Int) async throws -> MidasUsageSyncPublication
    {
        let connection = context.connection
        let workspace = context.workspace
        let now = context.now
        let storage = context.storage
        let cacheKey = try storage.root.path + head.deviceID.uuidString + String(head.revision)
            + head.digest + self.hash(self.encode(head.header))
        if let identities = try self.pageIdentities(head, storage: storage),
           let cached = DecodedPublications.shared.get(cacheKey + identities) { return cached }
        var events: [MidasUsageSyncEvent] = []
        var accounts: [MidasUsageSyncAccountDay] = []
        for descriptor in head.pages {
            try Task.checkCancellation()
            var data = try storage.page(descriptor.digest, maximumBytes: self.maximumPageBytes)
            if let cached = data, cached.count != descriptor.byteCount || self.hash(cached) != descriptor.digest {
                try storage.quarantinePage(descriptor.digest)
                data = nil
            }
            if data == nil {
                let fetched = try await MidasUsageHubClient.request(
                    connection: connection,
                    path: "v2/pages/\(head.deviceID.uuidString)/\(head.revision)/\(descriptor.digest)",
                    body: nil,
                    limit: descriptor.byteCount)
                guard fetched.count == descriptor.byteCount, self.hash(fetched) == descriptor.digest else {
                    throw MidasUsageHubError.invalidResponse
                }
                try storage.savePage(fetched, digest: descriptor.digest)
                downloaded += 1
                data = fetched
            }
            let page = try self.decode(MidasUsageHubV2Page.self, data!)
            guard page.schemaVersion == 1, page.events.count == descriptor.eventCount,
                  page.accountDays.count == descriptor.accountDayCount else { throw MidasUsageHubError.invalidResponse }
            events.append(contentsOf: page.events)
            accounts.append(contentsOf: page.accountDays)
        }
        let result = head.header.publication(events: events, accountDays: accounts)
        try result.validateCanonical(workspaceID: workspace.id, now: now)
        guard result.deviceID != connection.deviceID || result.deviceName == connection.deviceName else {
            throw MidasUsageHubError.invalidResponse
        }
        if let identities = try self.pageIdentities(head, storage: storage) {
            DecodedPublications.shared.put(result, key: cacheKey + identities)
        }
        return result
    }

    private static func pageIdentities(_ head: MidasUsageHubV2Head, storage: MidasUsageHubV2Storage) throws -> String? {
        var identities: [String] = []
        for page in head.pages {
            guard let identity = try storage.pageIdentity(page.digest, byteCount: page.byteCount) else { return nil }
            identities.append(identity)
        }
        return self.hash(Data(identities.joined(separator: ",").utf8))
    }

    private static func stagedPublication(
        _ upload: MidasUsageHubV2Upload,
        storage: MidasUsageHubV2Storage) throws -> MidasUsageSyncPublication
    {
        var events: [MidasUsageSyncEvent] = []
        var accounts: [MidasUsageSyncAccountDay] = []
        for descriptor in upload.pages {
            guard let data = try storage.page(descriptor.digest, maximumBytes: self.maximumPageBytes),
                  self.hash(data) == descriptor.digest else { throw MidasUsageHubError.corruptCache }
            let page = try self.decode(MidasUsageHubV2Page.self, data)
            events.append(contentsOf: page.events)
            accounts.append(contentsOf: page.accountDays)
        }
        return upload.header.publication(events: events, accountDays: accounts)
    }

    static func prepare(
        _ publication: MidasUsageSyncPublication,
        maximumBytes: Int,
        storage: MidasUsageHubV2Storage) throws
        -> (header: MidasUsageHubV2Header, pages: [MidasUsageHubV2PageDescriptor])
    {
        // Provider/day boundaries keep closed historical pages byte-identical as today's events grow.
        let eventGroups = Dictionary(grouping: publication.events) { $0.provider.rawValue + ":" + $0.day }
        let accountGroups = Dictionary(grouping: publication.accountDays) { $0.provider.rawValue + ":" + $0.day }
        var descriptors: [MidasUsageHubV2PageDescriptor] = []
        for key in Set(eventGroups.keys).union(accountGroups.keys).sorted() {
            let events = (eventGroups[key] ?? []).sorted { $0.id < $1.id }
            let accounts = (accountGroups[key] ?? []).sorted { $0.accountScope < $1.accountScope }
            var offset = 0
            while offset < events.count {
                var count = min(512, events.count - offset)
                while true {
                    let page = MidasUsageHubV2Page(
                        schemaVersion: 1,
                        events: Array(events[offset..<(offset + count)]),
                        accountDays: [])
                    let data = try self.encode(page)
                    if data.count <= maximumBytes {
                        try self.store(data, events: count, accounts: 0, storage: storage, descriptors: &descriptors)
                        break
                    }
                    guard count > 1 else { throw MidasUsageHubError.responseTooLarge }
                    count /= 2
                }
                offset += count
            }
            offset = 0
            while offset < accounts.count {
                var count = min(512, accounts.count - offset)
                while true {
                    let page = MidasUsageHubV2Page(
                        schemaVersion: 1,
                        events: [],
                        accountDays: Array(accounts[offset..<(offset + count)]))
                    let data = try self.encode(page)
                    if data.count <= maximumBytes {
                        try self.store(data, events: 0, accounts: count, storage: storage, descriptors: &descriptors)
                        break
                    }
                    guard count > 1 else { throw MidasUsageHubError.responseTooLarge }
                    count /= 2
                }
                offset += count
            }
        }
        guard descriptors.reduce(0, { $0 + $1.byteCount }) <= self.maximumPublicationBytes else {
            throw MidasUsageHubError.responseTooLarge
        }
        return (MidasUsageHubV2Header(publication), descriptors)
    }

    private static func store(
        _ data: Data,
        events: Int,
        accounts: Int,
        storage: MidasUsageHubV2Storage,
        descriptors: inout [MidasUsageHubV2PageDescriptor]) throws
    {
        guard descriptors.reduce(0, { $0 + $1.byteCount }) <= self.maximumPublicationBytes - data.count else {
            throw MidasUsageHubError.responseTooLarge
        }
        let digest = self.hash(data)
        if try storage.page(digest, maximumBytes: self.maximumPageBytes) != data { try storage.savePage(
            data,
            digest: digest) }
        descriptors.append(MidasUsageHubV2PageDescriptor(
            digest: digest,
            byteCount: data.count,
            eventCount: events,
            accountDayCount: accounts))
    }

    private static func upload(
        _ upload: MidasUsageHubV2Upload,
        connection: MidasUsageHubConnection,
        storage: MidasUsageHubV2Storage,
        count: inout Int) async throws -> MidasUsageHubV2UploadReceipt
    {
        let response = try await MidasUsageHubClient.request(
            connection: connection,
            path: "v2/upload/start",
            body: self.encode(upload),
            limit: 1024 * 1024)
        let start = try self.decode(MidasUsageHubV2UploadStart.self, response)
        guard start.uploadID == upload.uploadID, Set(start.missingDigests).count == start.missingDigests.count,
              Set(start.missingDigests).isSubset(of: Set(upload.pages.map(\.digest)))
        else { throw MidasUsageHubError.invalidResponse }
        if start.committed {
            guard let receipt = start.receipt else { throw MidasUsageHubError.invalidResponse }
            return receipt
        }
        for digest in start.missingDigests {
            guard let page = try storage.page(digest, maximumBytes: self.maximumPageBytes),
                  self.hash(page) == digest
            else {
                throw MidasUsageHubError.corruptCache
            }
            _ = try await MidasUsageHubClient.request(
                connection: connection,
                path: "v2/upload/page/\(upload.uploadID.uuidString)/\(digest)",
                body: page,
                limit: 4096)
            count += 1
        }
        let committed = try await MidasUsageHubClient.request(
            connection: connection,
            path: "v2/upload/commit",
            body: self.encode(["uploadID": upload.uploadID]),
            limit: 4096)
        return try self.decode(MidasUsageHubV2UploadReceipt.self, committed)
    }

    private struct AccountSemantic: Equatable {
        let key: String
        let values: MidasUsageSyncValues
        init(_ value: MidasUsageSyncAccountDay) {
            self.key = value.provider.rawValue + ":" + value.accountScope + ":" + value.day
            self.values = value.values
        }
    }

    private static func semanticEqual(_ lhs: MidasUsageSyncPublication, _ rhs: MidasUsageSyncPublication) -> Bool {
        lhs.deviceID == rhs.deviceID && lhs.deviceName == rhs.deviceName && lhs.excludedRecords == rhs.excludedRecords
            && lhs.events.sorted { $0.provider.rawValue + $0.id < $1.provider.rawValue + $1.id }
            == rhs.events.sorted { $0.provider.rawValue + $0.id < $1.provider.rawValue + $1.id }
            && lhs.accountDays.map { AccountSemantic($0) }.sorted { $0.key < $1.key }
            == rhs.accountDays.map { AccountSemantic($0) }.sorted { $0.key < $1.key }
    }

    private static func fingerprint(
        header: MidasUsageHubV2Header,
        pages: [MidasUsageHubV2PageDescriptor]) throws -> String
    {
        try self.hash(self.encode([
            "pages": pages.map(\.digest).joined(separator: ","),
            "device": header.deviceID.uuidString,
            "name": header.deviceName,
            "excluded": String(header.excludedRecords),
        ]))
    }

    private static func peers(_ manifest: MidasUsageHubV2Manifest) -> [MidasUsageHubPeerReceipt] {
        manifest.receipts.map { receipt in
            MidasUsageHubPeerReceipt(
                deviceID: receipt.deviceID,
                deviceName: manifest.devices.first { $0.deviceID == receipt.deviceID }?
                    .deviceName ?? "Device",
                checkedAt: receipt.checkedAt,
                appliedRevisions: receipt.appliedRevisions)
        }
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw MidasUsageHubError.invalidResponse }
    }
}

extension Optional {
    fileprivate func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}

private final class TransportLocks: @unchecked Sendable {
    static let shared = TransportLocks()
    private let lock = NSLock()
    private var paths = Set<String>()
    func acquire(_ path: String) throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.paths.insert(path).inserted else { throw MidasUsageHubError.unavailable }
    }

    func release(_ path: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.paths.remove(path)
    }
}

/// A bounded decoded checkpoint cache avoids reparsing immutable pages on every heartbeat.
private final class DecodedPublications: @unchecked Sendable {
    static let shared = DecodedPublications()
    private let lock = NSLock()
    private var values: [String: MidasUsageSyncPublication] = [:]
    private var records = 0
    func get(_ key: String) -> MidasUsageSyncPublication? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values[key]
    }

    func put(_ publication: MidasUsageSyncPublication, key: String) {
        let count = publication.events.count + publication.accountDays.count
        guard count <= 250_000 else { return }
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.records + count > 250_000 {
            self.values.removeAll()
            self.records = 0
        }
        if self.values[key] == nil { self.records += count }
        self.values[key] = publication
    }
}
