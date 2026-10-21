import CodexBarCore
import Foundation

extension MidasUsageSyncCoordinator {
    struct Cache: Codable, Sendable {
        var schemaVersion = 2
        let localDeviceID: UUID
        let deviceBinding: String?
        let accountFingerprint: String
        let workspace: MidasUsageSyncWorkspace
        let publications: [MidasUsageSyncPublication]
        let pendingLocal: MidasUsageSyncPublication?
        let lastPublishedAt: Date?
        let lastReceivedAt: Date?

        /// Keep synthesized optional omission semantics without visiting the bulk arrays.
        struct Metadata: Encodable {
            let schemaVersion: Int
            let localDeviceID: UUID
            let deviceBinding: String?
            let accountFingerprint: String
            let workspace: MidasUsageSyncWorkspace
            let lastPublishedAt: Date?
            let lastReceivedAt: Date?

            init(_ cache: Cache) {
                self.schemaVersion = cache.schemaVersion
                self.localDeviceID = cache.localDeviceID
                self.deviceBinding = cache.deviceBinding
                self.accountFingerprint = cache.accountFingerprint
                self.workspace = cache.workspace
                self.lastPublishedAt = cache.lastPublishedAt
                self.lastReceivedAt = cache.lastReceivedAt
            }
        }
    }

    struct PublicationReference: Codable, Sendable {
        let deviceID: UUID
        let revision: String
    }

    struct PagedCache: Codable, Sendable {
        var schemaVersion = 3
        let localDeviceID: UUID
        let deviceBinding: String?
        let accountFingerprint: String
        let workspace: MidasUsageSyncWorkspace
        let publications: [PublicationReference]
        let lastPublishedAt: Date?
        let lastReceivedAt: Date?
    }

    struct Outbox: Codable, Sendable {
        var schemaVersion = 1
        let localDeviceID: UUID
        let deviceBinding: String?
        let workspace: MidasUsageSyncWorkspace
        let revision: String
        let pending: Bool
    }
}

extension MidasUsageSyncCoordinator {
    func message(_ error: Error) -> String {
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
                case .unsupportedProtocol, .incompatibleProtocol:
                    return "Update Midas on your hub to continue syncing. Saved usage is retained."
                case .revisionExpired:
                    return "Shared history is refreshing from your hub. Saved changes are retained."
                case .corruptCache:
                    return "The local download cache needs repair. Saved usage is retained."
                case .timedOut, .nameResolutionFailed, .secureConnectionFailed, .unavailable: break
                }
            }
            return "Your Tailscale hub is unavailable. Check Tailscale and that the Mac mini is awake. " +
                "Last received usage is retained and new usage will retry."
        }
        if let error = error as? MidasUsageSyncError { return error.localizedDescription }
        return "The shared folder is unavailable. Check access and retry."
    }

    static func coverageIssue(
        result: MidasUsageSyncFolder.Result,
        ledger: MidasUsageSyncLedger) -> String?
    {
        if result.rejectedFiles > 0 { return "Some device files could not be validated and were excluded." }
        if result
            .unavailableFiles >
            0 { return "Some device files are still downloading. Last received history is retained." }
        if ledger
            .excludedRecords >
            0
        {
            return "Some recorded activity could not be included. " +
                "Delivery can still finish; totals have limited coverage."
        }
        if ledger.publications.contains(where: { $0.legacyAggregateDayCount > 0 }) {
            return "Some older days are preserved as legacy totals. Their underlying activity cannot be fully checked."
        }
        return nil
    }
}
