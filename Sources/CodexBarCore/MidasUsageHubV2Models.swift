import Foundation

/// A durable reader receipt. It describes applied data, never merely a successful upload.
public struct MidasUsageHubPeerReceipt: Codable, Sendable, Equatable {
    public let deviceID: UUID
    public let deviceName: String
    public let checkedAt: Date
    public let appliedRevisions: [String: Int]

    public init(
        deviceID: UUID,
        deviceName: String,
        checkedAt: Date,
        appliedRevisions: [String: Int] = [:])
    {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.checkedAt = checkedAt
        self.appliedRevisions = appliedRevisions
    }
}

public struct MidasUsageHubDeviceRevision: Codable, Sendable, Equatable {
    public let deviceID: UUID
    public let deviceName: String
    public let revision: Int
    public let publishedAt: Date
    public let supportsReceipts: Bool
    public let isRevoked: Bool

    public init(
        deviceID: UUID,
        deviceName: String,
        revision: Int,
        publishedAt: Date,
        supportsReceipts: Bool = false,
        isRevoked: Bool = false)
    {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.revision = revision
        self.publishedAt = publishedAt
        self.supportsReceipts = supportsReceipts
        self.isRevoked = isRevoked
    }
}

/// A selected checkpoint. The caller acknowledges it only after its own application state is durable.
public struct MidasUsageHubSyncState: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let hubVersion: String
    public let checkedAt: Date
    public let appliedRevisions: [String: Int]
    public let acceptedLocalRevision: Int?
    public let devices: [MidasUsageHubDeviceRevision]
    public let peers: [MidasUsageHubPeerReceipt]
    public let uploadedPages: Int
    public let downloadedPages: Int

    public init(
        protocolVersion: Int = 2,
        hubVersion: String = "",
        checkedAt: Date = Date(),
        appliedRevisions: [String: Int] = [:],
        acceptedLocalRevision: Int? = nil,
        devices: [MidasUsageHubDeviceRevision] = [],
        peers: [MidasUsageHubPeerReceipt] = [],
        uploadedPages: Int = 0,
        downloadedPages: Int = 0)
    {
        self.protocolVersion = protocolVersion
        self.hubVersion = hubVersion
        self.checkedAt = checkedAt
        self.appliedRevisions = appliedRevisions
        self.acceptedLocalRevision = acceptedLocalRevision
        self.devices = devices
        self.peers = peers
        self.uploadedPages = uploadedPages
        self.downloadedPages = downloadedPages
    }
}

struct MidasUsageHubV2Manifest: Codable, Sendable {
    struct Limits: Codable, Sendable {
        let pageBytes: Int
        let publicationRecords: Int
        let publicationBytes: Int
    }

    let protocolVersion: Int
    let hubVersion: String
    let workspace: MidasUsageSyncWorkspace
    let limits: Limits
    let devices: [MidasUsageHubV2Head]
    let receipts: [MidasUsageHubV2Receipt]
    let checkedAt: Date
}

struct MidasUsageHubV2Header: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let workspaceID: UUID
    let deviceID: UUID
    let deviceName: String
    let publishedAt: Date
    let excludedRecords: Int

    init(_ publication: MidasUsageSyncPublication) {
        self.schemaVersion = publication.schemaVersion
        self.workspaceID = publication.workspaceID
        self.deviceID = publication.deviceID
        self.deviceName = publication.deviceName
        self.publishedAt = publication.publishedAt
        self.excludedRecords = publication.excludedRecords
    }

    func publication(
        events: [MidasUsageSyncEvent],
        accountDays: [MidasUsageSyncAccountDay]) -> MidasUsageSyncPublication
    {
        MidasUsageSyncPublication(
            workspaceID: self.workspaceID,
            deviceID: self.deviceID,
            deviceName: self.deviceName,
            publishedAt: self.publishedAt,
            events: events,
            accountDays: accountDays,
            excludedRecords: self.excludedRecords,
            schemaVersion: self.schemaVersion)
    }
}

struct MidasUsageHubV2PageDescriptor: Codable, Sendable, Equatable {
    let digest: String
    let byteCount: Int
    let eventCount: Int
    let accountDayCount: Int
}

struct MidasUsageHubV2Page: Codable, Sendable {
    let schemaVersion: Int
    let events: [MidasUsageSyncEvent]
    let accountDays: [MidasUsageSyncAccountDay]
}

struct MidasUsageHubV2Head: Codable, Sendable {
    let deviceID: UUID
    let deviceName: String
    let revision: Int
    let digest: String
    let header: MidasUsageHubV2Header
    let pages: [MidasUsageHubV2PageDescriptor]
    let eventCount: Int
    let accountDayCount: Int
    let revoked: Bool
    let supportsReceipts: Bool?
}

struct MidasUsageHubV2Receipt: Codable, Sendable {
    let deviceID: UUID
    let appliedRevisions: [String: Int]
    let checkedAt: Date
}

struct MidasUsageHubV2Upload: Codable, Sendable {
    let uploadID: UUID
    let expectedRevision: Int
    let header: MidasUsageHubV2Header
    let pages: [MidasUsageHubV2PageDescriptor]
}

struct MidasUsageHubV2UploadReceipt: Codable, Sendable {
    let deviceID: UUID
    let revision: Int
    let digest: String
    let acceptedAt: Date
    let publicationSucceeded: Bool
}

struct MidasUsageHubV2UploadStart: Decodable, Sendable {
    let uploadID: UUID
    let missingDigests: [String]
    let committed: Bool
    let receipt: MidasUsageHubV2UploadReceipt?
}
