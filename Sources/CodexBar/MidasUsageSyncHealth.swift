import CodexBarCore
import Foundation

enum MidasUsageSyncPhase: String, Codable, Sendable {
    case idle, checking, collecting, saving, uploading, applying
    var title: String {
        switch self {
        case .idle: "Ready"
        case .checking: "Checking shared usage"
        case .collecting: "Collecting recent usage"
        case .saving: "Saving usage on this Mac"
        case .uploading: "Uploading saved changes"
        case .applying: "Applying received usage"
        }
    }
}

/// A strong delivery claim requires every current participant's fresh, complete applied vector.
struct MidasSyncDeliveryHealth {
    let state: MidasUsageHubSyncState
    let receipts: [MidasUsageHubPeerReceipt]
    let localDeviceID: UUID
    let now: Date

    private var active: [MidasUsageHubDeviceRevision] {
        self.state.devices.filter { !$0.isRevoked }
    }

    private func coversHeads(_ vector: [String: Int]) -> Bool {
        self.active.allSatisfy { (vector[$0.deviceID.uuidString] ?? -1) >= $0.revision }
    }

    private func fresh(_ date: Date) -> Bool {
        (-60...300).contains(self.now.timeIntervalSince(date))
    }

    var allDevicesCaughtUp: Bool {
        guard self.fresh(self.state.checkedAt), self.coversHeads(self.state.appliedRevisions) else { return false }
        return self.active.filter { $0.deviceID != self.localDeviceID }.allSatisfy { device in
            guard device.supportsReceipts,
                  let receipt = self.receipts.first(where: { $0.deviceID == device.deviceID }),
                  self.fresh(receipt.checkedAt) else { return false }
            return self.coversHeads(receipt.appliedRevisions)
        }
    }

    var pendingSummary: String? {
        let peers = self.active.filter { $0.deviceID != self.localDeviceID }
        let legacy = peers.filter { !$0.supportsReceipts }
        if !legacy.isEmpty {
            return "Saved to hub · delivery unconfirmed for " + legacy.prefix(2).map(\.deviceName)
                .joined(separator: ", ")
        }
        let waiting = peers.filter { peer in
            guard let receipt = self.receipts.first(where: { $0.deviceID == peer.deviceID }) else { return true }
            return !self.fresh(receipt.checkedAt) || !self.coversHeads(receipt.appliedRevisions)
        }
        guard !waiting.isEmpty else { return nil }
        return "Saved to hub · waiting for a current receipt from " + waiting.prefix(2).map(\.deviceName)
            .joined(separator: ", ")
    }
}

extension MidasUsageSyncCoordinator {
    private var deliveryHealth: MidasSyncDeliveryHealth? {
        self.hubSyncState.map {
            MidasSyncDeliveryHealth(
                state: $0,
                receipts: self.peerReceipts,
                localDeviceID: self.syncDeviceID,
                now: self.syncStatusNow)
        }
    }

    var healthSummary: String {
        if !self.isEnabled { return self.hasConnection ? "Sync paused" : "Sync not connected" }
        if self.outboxRequiresRepair { return "Saved upload queue needs repair" }
        if self.issue != nil { return self.hasPendingUpload ? "Changes saved on this Mac" : "Needs attention" }
        if self.isSyncing { return self.phase.title }
        if self.hasPendingUpload { return "Changes saved on this Mac" }
        guard self.lastAppliedAt != nil else { return "Showing saved usage" }
        guard let deliveryHealth else { return "This Mac has received shared usage" }
        return deliveryHealth.allDevicesCaughtUp ? "All devices caught up" : "This Mac is up to date"
    }

    var peerDeliverySummary: String? {
        self.deliveryHealth?.pendingSummary
    }
}
