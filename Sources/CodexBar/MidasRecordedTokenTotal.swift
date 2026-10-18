import CodexBarCore
import Foundation

/// A recorded subtotal over the same calendar window as the displayed estimates.
/// Provider account bills remain separate because their sessions can also appear in coding logs.
struct MidasRecordedTokenTotal {
    let tokens: Int?
    let reportingProviders: Int
    let providerCount: Int
    let isPartial: Bool

    @MainActor static func providersForTotal(
        local: [UsageProvider], shared: [UsageProvider], combined: Bool) -> [UsageProvider]
    {
        let source = combined ? shared.filter { UsageStore.midasSyncProviders.contains($0) } : local
        return Set(source).sorted { $0.rawValue < $1.rawValue }
    }

    init(
        providers: [UsageProvider],
        snapshots: [UsageProvider: CostUsageTokenSnapshot],
        period: MidasSpendPeriod,
        reportingTimeZones: [UsageProvider: TimeZone] = [:],
        now: Date = Date())
    {
        let unique = Set(providers).filter { snapshots[$0]?.costProvenance != .vendorBilled }
        var total = 0
        var reporting = 0
        var partial = false
        var overflow = false
        for provider in unique.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let snapshot = snapshots[provider],
                  let amount = period.tokens(
                      snapshot: snapshot,
                      timeZone: reportingTimeZones[provider] ?? .current,
                      now: now),
                  let count = amount.tokens
            else { partial = true; continue }
            partial = partial || amount.isPartial
            let next = total.addingReportingOverflow(count)
            if next.overflow { overflow = true; break }
            total = next.partialValue
            reporting += 1
        }
        self.tokens = reporting > 0 && !overflow ? total : nil
        self.reportingProviders = reporting
        self.providerCount = unique.count
        self.isPartial = partial || overflow || reporting < unique.count
    }

    var label: String {
        self.tokens.map { "\($0.formatted()) recorded tokens" } ?? "Recorded tokens unavailable"
    }
}

extension UsageStore {
    func midasRecordedTokenTotal(providers: [UsageProvider]) -> MidasRecordedTokenTotal {
        let snapshots = Dictionary(uniqueKeysWithValues: Set(providers).compactMap { provider in
            self.displayTokenSnapshot(for: provider).map { (provider, $0) }
        })
        let zones = Dictionary(uniqueKeysWithValues: Set(providers).map { provider in
            (provider, self.spendReportingTimeZone(for: provider, snapshot: snapshots[provider]))
        })
        return MidasRecordedTokenTotal(
            providers: providers,
            snapshots: snapshots,
            period: MidasSpendPeriod(selection: self.settings.midasSpendPeriodSelection),
            reportingTimeZones: zones)
    }
}
