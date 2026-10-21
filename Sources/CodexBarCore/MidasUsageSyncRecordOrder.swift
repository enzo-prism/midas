import Foundation

/// Business ordering for copies of one numeric measurement. Delivery timestamps are not corrections.
public enum MidasUsageSyncRecordOrder {
    public static func prefers(_ lhs: MidasUsageSyncEvent, over rhs: MidasUsageSyncEvent) -> Bool {
        // A copied prefix may be observed later but must never erase a completed measurement.
        if lhs.values.tokens != rhs.values.tokens {
            return (lhs.values.tokens ?? -1) > (rhs.values.tokens ?? -1)
        }
        if lhs.observedAt != rhs.observedAt { return lhs.observedAt > rhs.observedAt }
        if lhs.values.pricingRevision != rhs.values.pricingRevision,
           (lhs.values.pricingRevision ?? 0) != (rhs.values.pricingRevision ?? 0)
        {
            return (lhs.values.pricingRevision ?? 0) > (rhs.values.pricingRevision ?? 0)
        }
        let left = self.pricingQuality(lhs.values)
        let right = self.pricingQuality(rhs.values)
        if left != right { return left > right }
        guard lhs != rhs else { return false }
        return self.canonical(lhs) > self.canonical(rhs)
    }

    public static func prefers(_ lhs: MidasUsageSyncAccountDay, over rhs: MidasUsageSyncAccountDay) -> Bool {
        // Account reports may be authoritatively corrected downward; choose the whole newer report.
        if lhs.observedAt != rhs.observedAt { return lhs.observedAt > rhs.observedAt }
        if lhs.values.pricingRevision != rhs.values.pricingRevision,
           (lhs.values.pricingRevision ?? 0) != (rhs.values.pricingRevision ?? 0)
        {
            return (lhs.values.pricingRevision ?? 0) > (rhs.values.pricingRevision ?? 0)
        }
        let left = self.pricingQuality(lhs.values)
        let right = self.pricingQuality(rhs.values)
        if left != right { return left > right }
        guard lhs != rhs else { return false }
        return self.canonical(lhs) > self.canonical(rhs)
    }

    private static func pricingQuality(_ values: MidasUsageSyncValues) -> Int {
        var quality = values.costUSD != nil ? 100 : 0
        quality += values.apiEquivalentCostUSD != nil ? 20 : 0
        quality += values.model != nil ? 1 : 0
        switch values.provenance {
        case .vendorBilled: quality += 40
        case .vendorMetered: quality += 30
        case .listPriceEstimate: quality += 10
        case .mixed: quality += 5
        case .unknown: break
        }
        return quality
    }

    private static func canonical(_ value: some Encodable) -> String {
        autoreleasepool {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }
}
