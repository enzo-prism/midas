import Foundation

/// A public hosted comparison for the verified local model, never a charge or hardware-cost estimate.
/// Raw synced records remain unpriced; only complete, model-specific token classes receive a value here.
public enum DGXSparkPricing {
    public static let modelID = "Qwen/Qwen3.8-Flash-Next"
    public static let modelDisplayName = "Qwen3.8 Flash Next"
    public static let hostedProviderName = "Lyceum"
    public static let sourceURL = URL(string: "https://lyceum.technology/models/qwen/qwen3.8-flash-next/")!
    public static let verifiedOn = "2026-10-17"
    public static let inputUSDPerMillion = 0.20
    public static let cachedInputUSDPerMillion = 0.05
    public static let outputUSDPerMillion = 0.50
    public static let localQuantization = "NVFP4"

    public static func isKnownModel(_ model: String) -> Bool {
        model == self.modelID
    }

    /// Cached input is already a subset of input, not an additional token class.
    public static func estimate(
        model: String, input: Int?, cachedInput: Int?, output: Int?, total: Int?) -> Double?
    {
        guard self.isKnownModel(model), let input, let cachedInput, let output, let total,
              input >= 0, output >= 0, cachedInput >= 0, cachedInput <= input, total >= 0
        else { return nil }
        let sum = input.addingReportingOverflow(output)
        guard !sum.overflow, sum.partialValue == total else { return nil }
        let result = (Double(input - cachedInput) * self.inputUSDPerMillion
            + Double(cachedInput) * self.cachedInputUSDPerMillion
            + Double(output) * self.outputUSDPerMillion) / 1_000_000
        return result.isFinite ? result : nil
    }

    /// Preserve the full source history. Period selection belongs to the caller and reads daily rows.
    /// Recomputing from measurements makes this projection idempotent and ignores imported dollar amounts.
    public static func project(snapshot: CostUsageTokenSnapshot, now: Date = Date()) -> CostUsageTokenSnapshot {
        let daily = snapshot.daily.map(self.project)
        let session = daily.filter { $0.date == MidasUsageSyncPublication.day(now) }
        let historyCost = MidasUsageSyncLedger.sumDoubles(daily.map(\.costUSD))
        return CostUsageTokenSnapshot(
            sessionTokens: snapshot.sessionTokens,
            sessionCostUSD: MidasUsageSyncLedger.sumDoubles(session.map(\.costUSD)),
            sessionRequests: snapshot.sessionRequests,
            last30DaysTokens: snapshot.last30DaysTokens,
            last30DaysCostUSD: historyCost,
            last30DaysRequests: snapshot.last30DaysRequests,
            currencyCode: "USD",
            historyDays: snapshot.historyDays,
            historyLabel: snapshot.historyLabel,
            costProvenance: historyCost == nil ? .unknown : .listPriceEstimate,
            daily: daily,
            updatedAt: snapshot.updatedAt)
    }

    private static func project(_ row: CostUsageDailyReport.Entry) -> CostUsageDailyReport.Entry {
        let models = (row.modelBreakdowns ?? []).map { model in
            CostUsageDailyReport.ModelBreakdown(
                modelName: model.modelName,
                costUSD: self.estimate(
                    model: model.modelName,
                    input: model.inputTokens,
                    cachedInput: model.cacheReadTokens,
                    output: model.outputTokens,
                    total: model.totalTokens),
                totalTokens: model.totalTokens,
                requestCount: model.requestCount,
                inputTokens: model.inputTokens,
                outputTokens: model.outputTokens,
                cacheReadTokens: model.cacheReadTokens,
                cacheCreationTokens: model.cacheCreationTokens,
                reasoningTokens: model.reasoningTokens)
        }
        let priced = models.filter { $0.costUSD != nil }
        let pricedTokens = MidasUsageSyncLedger.sumIntegers(priced.map(\.totalTokens))
        let pricedRequests = MidasUsageSyncLedger.sumIntegers(priced.map { max(1, $0.requestCount ?? 1) })
        // Explicit categories replace raw unpriced categories, so projecting an already valued snapshot is stable.
        let remainingUnpriced = (row.estimatedRequestCount ?? 0) > 0
            ? max(0, row.unpricedRequestCount ?? 0)
            : max(0, (row.unpricedRequestCount ?? 0) - (pricedRequests ?? 0))
        let complete = row.totalTokens != nil && pricedTokens == row.totalTokens
            && models.allSatisfy { $0.costUSD != nil }
            && remainingUnpriced == 0
        let unpriced: Int? = complete ? 0 : max(1, remainingUnpriced, row.requestCount.flatMap { requests in
            guard let pricedRequests else { return requests }
            return max(0, requests - pricedRequests)
        } ?? 1)
        let uniqueModels = Set(models.map(\.modelName)).count == models.count
        let validSubtotal = uniqueModels && pricedTokens != nil && row.totalTokens.map { pricedTokens! <= $0 } == true
        return CostUsageDailyReport.Entry(
            date: row.date,
            inputTokens: row.inputTokens,
            outputTokens: row.outputTokens,
            cacheReadTokens: row.cacheReadTokens,
            cacheCreationTokens: row.cacheCreationTokens,
            reasoningTokens: row.reasoningTokens,
            totalTokens: row.totalTokens,
            requestCount: row.requestCount,
            costUSD: validSubtotal ? MidasUsageSyncLedger.sumDoubles(priced.map(\.costUSD)) : nil,
            modelsUsed: row.modelsUsed,
            modelBreakdowns: row.modelBreakdowns == nil ? nil : models,
            unpricedRequestCount: validSubtotal ? unpriced : max(1, row.requestCount ?? 1),
            estimatedRequestCount: validSubtotal ? pricedRequests : nil)
    }
}
