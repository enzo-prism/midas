import CodexBarCore
import Foundation

/// The local machine always reports a rolling UTC window, independent of the cloud spend picker.
struct MidasDGXSparkPresentation {
    let tokens: Int?
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let outputTokens: Int?
    let amount: Double?
    let range: MidasSpendPeriod.Range?
    let modelNames: [String]
    let hasVerifiedModel: Bool
    let hasUnpricedUsage: Bool
    let updatedAt: Date?
    let isStale: Bool

    var tokenText: String {
        self.tokens?.formatted() ?? "—"
    }

    var valueText: String {
        self.amount.map { MidasCostPresentation.money($0, currency: "USD") } ?? "—"
    }

    var preciseValueText: String? {
        self.amount.map { $0.formatted(.currency(code: "USD").precision(.fractionLength(2...8))) }
    }

    var modelText: String {
        self.hasVerifiedModel ? DGXSparkPricing.modelDisplayName : "Model not verified"
    }

    var basisText: String {
        self.hasVerifiedModel ? "\(DGXSparkPricing.hostedProviderName) API rates" : "Pricing basis unavailable"
    }

    var coverageText: String {
        if self.tokens == nil { return "Waiting for recorded usage" }
        return self.hasUnpricedUsage
            ? "Partial history · some tokens unpriced" : "Partial history · recorded usage only"
    }

    var freshnessText: String {
        guard let updatedAt else { return "Waiting for Spark’s first sync" }
        return "\(self.isStale ? "Last received" : "Updated") "
            + updatedAt.formatted(date: .abbreviated, time: .shortened)
    }

    static func make(snapshot: CostUsageTokenSnapshot?, now: Date = Date()) -> Self {
        let period = MidasSpendPeriod.rolling30Days
        let range = period.range(now: now, timeZone: MidasSpendPeriod.utc)
        let rows = snapshot?.daily.filter { range?.contains($0.date) == true } ?? []
        let models = Set(rows.flatMap { ($0.modelsUsed ?? []) + ($0.modelBreakdowns?.map(\.modelName) ?? []) })
            .sorted()
        let tokens = snapshot.flatMap { period.tokens(snapshot: $0, timeZone: MidasSpendPeriod.utc, now: now)?.tokens }
        let amount = snapshot.flatMap { period.amount(snapshot: $0, timeZone: MidasSpendPeriod.utc, now: now)?.dollars }
        let unpriced = rows.contains {
            ($0.unpricedRequestCount ?? 0) > 0 || ($0.totalTokens ?? 0) > 0 && $0.costUSD == nil
        }
        return Self(
            tokens: tokens,
            inputTokens: Self.completeSum(rows, \.inputTokens),
            cachedInputTokens: Self.completeSum(rows, \.cacheReadTokens),
            outputTokens: Self.completeSum(rows, \.outputTokens),
            amount: amount,
            range: range,
            modelNames: models,
            hasVerifiedModel: models.contains(where: DGXSparkPricing.isKnownModel),
            hasUnpricedUsage: unpriced,
            updatedAt: snapshot?.updatedAt,
            isStale: snapshot.map { now.timeIntervalSince($0.updatedAt) > 15 * 60 } ?? false)
    }

    /// An incomplete breakdown is unavailable rather than a misleading subtotal or invented zero.
    private static func completeSum(
        _ rows: [CostUsageDailyReport.Entry],
        _ field: KeyPath<CostUsageDailyReport.Entry, Int?>) -> Int?
    {
        guard !rows.isEmpty else { return nil }
        var total = 0
        for row in rows {
            guard let value = row[keyPath: field], value >= 0 else { return nil }
            let next = total.addingReportingOverflow(value)
            guard !next.overflow else { return nil }
            total = next.partialValue
        }
        return total
    }
}
