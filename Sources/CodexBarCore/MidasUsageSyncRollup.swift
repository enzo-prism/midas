#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Older local history that no longer fits one publication as individual events.
///
/// A rollup is an ordinary event (same wire format, readable by every hub and Midas version) carrying
/// one device's sum for a provider, UTC day, model and pricing state. Its identity is device-specific,
/// so two Macs' rollups add instead of replacing each other. Each provider/day is either all
/// individual events or all rollups, never both, so nothing is counted twice within one device.
/// Cross-device copy detection only applies to days still published as individual events.
public enum MidasUsageSyncRollup {
    struct DayKey: Hashable, Comparable {
        let provider: UsageProvider
        let day: String

        init(_ event: MidasUsageSyncEvent) {
            self.provider = event.provider
            self.day = event.day
        }

        static func < (lhs: DayKey, rhs: DayKey) -> Bool {
            lhs.day == rhs.day ? lhs.provider.rawValue < rhs.provider.rawValue : lhs.day < rhs.day
        }
    }

    private struct GroupKey: Hashable {
        let day: DayKey
        let model: String?
        let provenance: CostProvenance
        let priced: Bool

        init(_ event: MidasUsageSyncEvent) {
            self.day = DayKey(event)
            self.model = event.values.model
            self.provenance = event.values.provenance
            self.priced = event.values.costUSD != nil
        }
    }

    private static func id(deviceID: UUID?, key: GroupKey) -> String {
        let value = [
            "midas-day-rollup-v1", deviceID?.uuidString ?? "", key.day.provider.rawValue, key.day.day,
            key.model ?? "", key.provenance.rawValue, key.priced ? "priced" : "unpriced",
        ]
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func isRollup(_ event: MidasUsageSyncEvent, deviceID: UUID?) -> Bool {
        event.id == self.id(deviceID: deviceID, key: GroupKey(event))
    }

    /// Sums events with the ledger's own rules, so a rolled-up day reports the same totals.
    struct Builder {
        private var groups: [GroupKey: Totals] = [:]

        var isEmpty: Bool {
            self.groups.isEmpty
        }

        mutating func add(_ event: MidasUsageSyncEvent) {
            self.groups[GroupKey(event), default: Totals()].add(event)
        }

        func events(deviceID: UUID?) -> [MidasUsageSyncEvent] {
            self.groups.compactMap { key, totals in
                totals.event(deviceID: deviceID, key: key)
            }
        }
    }

    /// Rolls every event into per-group totals and returns them as rollup events.
    static func rollUp(_ events: some Sequence<MidasUsageSyncEvent>, deviceID: UUID?) -> [MidasUsageSyncEvent] {
        var builder = Builder()
        for event in events.sorted(by: {
            $0.provider == $1.provider ? $0.id < $1.id : $0.provider.rawValue < $1.provider.rawValue
        }) {
            builder.add(event)
        }
        return builder.events(deviceID: deviceID)
    }

    private struct Totals {
        var tokens: Int?
        var requests: Int?
        var cost: Double?
        var apiEquivalent: Double?
        var input: Int?
        var output: Int?
        var cacheRead: Int?
        var cacheCreation: Int?
        var reasoning: Int?
        var unpriced = 0
        var estimated = 0
        var pricingRevision: Int?
        var observedAt = Date.distantPast

        mutating func add(_ event: MidasUsageSyncEvent) {
            let values = event.values
            Self.add(values.tokens, to: &self.tokens)
            Self.add(values.requests, to: &self.requests)
            Self.add(values.tokenMix.inputTokens, to: &self.input)
            Self.add(values.tokenMix.outputTokens, to: &self.output)
            Self.add(values.tokenMix.cacheReadTokens, to: &self.cacheRead)
            Self.add(values.tokenMix.cacheCreationTokens, to: &self.cacheCreation)
            Self.add(values.tokenMix.reasoningTokens, to: &self.reasoning)
            if let cost = values.costUSD { self.cost = (self.cost ?? 0) + cost }
            if let cost = values.apiEquivalentCostUSD { self.apiEquivalent = (self.apiEquivalent ?? 0) + cost }
            // The ledger counts an unpriced event at least once even when its own counter is zero.
            self.unpriced += max(values.unpricedRequests, values.costUSD == nil ? 1 : 0)
            self.estimated += values.estimatedRequests
            if let revision = values.pricingRevision { self.pricingRevision = max(self.pricingRevision ?? 0, revision) }
            self.observedAt = max(self.observedAt, event.observedAt)
        }

        private static func add(_ value: Int?, to total: inout Int?) {
            guard let value else { return }
            total = (total ?? 0) + value
        }

        func event(deviceID: UUID?, key: GroupKey) -> MidasUsageSyncEvent? {
            let event = MidasUsageSyncEvent(
                id: MidasUsageSyncRollup.id(deviceID: deviceID, key: key),
                provider: key.day.provider,
                day: key.day.day,
                observedAt: self.observedAt,
                values: MidasUsageSyncValues(
                    tokens: self.tokens,
                    requests: self.requests,
                    costUSD: self.cost,
                    apiEquivalentCostUSD: self.apiEquivalent,
                    tokenMix: CostUsageTokenMix(
                        inputTokens: self.input,
                        outputTokens: self.output,
                        cacheReadTokens: self.cacheRead,
                        cacheCreationTokens: self.cacheCreation,
                        reasoningTokens: self.reasoning),
                    provenance: key.provenance,
                    model: key.model,
                    unpricedRequests: self.unpriced,
                    estimatedRequests: self.estimated,
                    pricingRevision: self.pricingRevision))
            return (try? event.values.validate()) == nil ? nil : event
        }
    }
}
