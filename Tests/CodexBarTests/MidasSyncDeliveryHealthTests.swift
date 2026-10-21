import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MidasSyncDeliveryHealthTests {
    @Test func strongClaimRequiresFreshReceiptsCoveringEveryActiveHead() {
        let now = Date(timeIntervalSince1970: 1_789_171_200)
        let local = UUID(), second = UUID(), third = UUID()
        let heads = [local, second, third].map {
            MidasUsageHubDeviceRevision(
                deviceID: $0,
                deviceName: "Fixture",
                revision: 2,
                publishedAt: now,
                supportsReceipts: true)
        }
        let complete = Dictionary(uniqueKeysWithValues: [local, second, third].map { ($0.uuidString, 2) })
        let state = MidasUsageHubSyncState(checkedAt: now, appliedRevisions: complete, devices: heads)
        let fresh = [second, third].map {
            MidasUsageHubPeerReceipt(deviceID: $0, deviceName: "Fixture", checkedAt: now, appliedRevisions: complete)
        }
        #expect(MidasSyncDeliveryHealth(state: state, receipts: fresh, localDeviceID: local, now: now)
            .allDevicesCaughtUp)
        let stale = [
            MidasUsageHubPeerReceipt(
                deviceID: second,
                deviceName: "Fixture",
                checkedAt: now.addingTimeInterval(-301),
                appliedRevisions: complete),
            fresh[1],
        ]
        #expect(!MidasSyncDeliveryHealth(state: state, receipts: stale, localDeviceID: local, now: now)
            .allDevicesCaughtUp)
        let incomplete = [
            MidasUsageHubPeerReceipt(
                deviceID: second,
                deviceName: "Fixture",
                checkedAt: now,
                appliedRevisions: [local.uuidString: 2, second.uuidString: 2]),
            fresh[1],
        ]
        #expect(!MidasSyncDeliveryHealth(state: state, receipts: incomplete, localDeviceID: local, now: now)
            .allDevicesCaughtUp)
    }
}
