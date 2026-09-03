import CodexBarCore
import SwiftUI

/// Total 30-day spend header shown at the top of the Overview tab.
/// Sums each visible provider's `last30DaysCostUSD` (the same figure its card shows),
/// grouped by currency so mixed-currency setups never merge unlike units.
struct OverviewSpendSummary: Equatable {
    struct CurrencyTotal: Equatable {
        let currencyCode: String
        let amount: Double
    }

    struct Comparison: Equatable {
        enum Direction: Equatable {
            case up
            case down
            case flat
        }

        struct CurrencyDelta: Equatable {
            let currencyCode: String
            let direction: Direction
            let percent: Double
        }

        let deltas: [CurrencyDelta]
        let isPartial: Bool

        var hasUp: Bool {
            self.deltas.contains { $0.direction == .up }
        }

        var hasDown: Bool {
            self.deltas.contains { $0.direction == .down }
        }

        var isUp: Bool {
            self.hasUp && !self.hasDown
        }

        var isDown: Bool {
            self.hasDown && !self.hasUp
        }

        var text: String {
            self.deltas.map { delta in
                let arrow = switch delta.direction {
                case .up: "▲"
                case .down: "▼"
                case .flat: "■"
                }
                return "\(arrow) \(Int(delta.percent.rounded()))%"
            }.joined(separator: " · ") + " \(L("vs prior 30d"))" + (self.isPartial ? " \(L("· partial"))" : "")
        }

        /// Per-currency percent change of current vs prior totals. Nil when nothing is
        /// comparable (no shared currency with prior spend above zero).
        static func build(
            current: [CurrencyTotal],
            prior: [CurrencyTotal],
            currentPricedCount: Int,
            priorPricedCount: Int) -> Comparison?
        {
            var priorByCode: [String: Double] = [:]
            for total in prior {
                priorByCode[total.currencyCode, default: 0] += total.amount
            }
            var deltas: [CurrencyDelta] = []
            for total in current {
                guard let priorAmount = priorByCode[total.currencyCode], priorAmount > 0 else { continue }
                let change = ((total.amount - priorAmount) / priorAmount) * 100
                let direction: Direction = change > 0.5 ? .up : change < -0.5 ? .down : .flat
                deltas.append(CurrencyDelta(
                    currencyCode: total.currencyCode,
                    direction: direction,
                    percent: abs(change)))
            }
            guard !deltas.isEmpty else { return nil }
            return Comparison(deltas: deltas, isPartial: priorPricedCount < currentPricedCount)
        }
    }

    let totals: [CurrencyTotal]
    let pricedProviderCount: Int
    let providerCount: Int
    let totalTokens: Int?
    let comparison: Comparison?

    var hasSpend: Bool {
        !self.totals.isEmpty
    }

    var primarySpendText: String {
        guard !self.totals.isEmpty else { return L("Spend unavailable") }
        return self.totals.map { total in
            UsageFormatter.currencyString(total.amount, currencyCode: total.currencyCode)
        }.joined(separator: " · ")
    }

    var providerCoverageText: String {
        L(
            "%d of %d providers have spend",
            self.pricedProviderCount,
            self.providerCount)
    }

    var tokenText: String? {
        self.totalTokens.map { L("%@ tokens", UsageFormatter.tokenCountString($0)) }
    }

    /// Prior-period (days 31–60) costs for the comparison line. Empty while the
    /// background fetch has not produced prior data yet — the header then omits
    /// the comparison instead of showing a misleading zero baseline.
    static func build(
        costs: [(currencyCode: String, amount: Double)],
        tokens: [Int],
        providerCount: Int,
        priorCosts: [(currencyCode: String, amount: Double)] = [],
        priorPricedProviderCount: Int? = nil) -> OverviewSpendSummary
    {
        let totals = Self.groupedTotals(costs: costs)
        let priorTotals = Self.groupedTotals(costs: priorCosts)
        let comparison = Comparison.build(
            current: totals,
            prior: priorTotals,
            currentPricedCount: costs.count,
            priorPricedCount: priorPricedProviderCount ?? priorCosts.count)
        var tokenSum = 0
        var tokenOverflow = false
        for value in tokens {
            let result = tokenSum.addingReportingOverflow(value)
            if result.overflow { tokenOverflow = true; break }
            tokenSum = result.partialValue
        }
        return OverviewSpendSummary(
            totals: totals,
            pricedProviderCount: costs.count,
            providerCount: max(providerCount, costs.count),
            totalTokens: tokens.isEmpty || tokenOverflow ? nil : tokenSum,
            comparison: comparison)
    }

    private static func groupedTotals(costs: [(currencyCode: String, amount: Double)]) -> [CurrencyTotal] {
        var grouped: [String: Double] = [:]
        var order: [String] = []
        for cost in costs {
            let code = cost.currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let key = code.isEmpty ? "USD" : code
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: 0] += cost.amount
        }
        return order.compactMap { key in
            guard let amount = grouped[key] else { return nil }
            return CurrencyTotal(currencyCode: key, amount: amount)
        }
    }

    /// Sums `costUSD` over the prior 30-day window (days 31–60 back) from a
    /// 60-day daily series. Entries must be ascending by day; shorter series
    /// yield a partial sum and the caller marks the comparison partial.
    static func priorPeriodCost(daily: [CostUsageDailyReport.Entry]) -> Double {
        let sorted = daily.sorted { $0.date < $1.date }
        let priorWindow = sorted.dropLast(30).suffix(30)
        return priorWindow.compactMap(\.costUSD).reduce(0, +)
    }

    static func hasFullPriorWindow(daily: [CostUsageDailyReport.Entry]) -> Bool {
        let sorted = daily.sorted { $0.date < $1.date }
        return sorted.dropLast(30).suffix(30).count == 30
    }
}

struct OverviewSpendSummaryCardView: View {
    let summary: OverviewSpendSummary
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(L("Usage & Spend"))
                    .font(.headline.weight(.semibold))
                Text("·")
                Text(L("30d"))
            }
            .foregroundStyle(.secondary)

            Text(self.summary.primarySpendText)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .monospacedDigit()
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(self.summary.providerCoverageText)
                if let tokenText = self.summary.tokenText {
                    Text("·")
                    Text(tokenText)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if let comparison = self.summary.comparison {
                Text(comparison.text)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(comparison.isDown ? .green : comparison.isUp ? .orange : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.vertical, 10)
        .frame(width: self.width, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
                .padding(.horizontal, 6)
        }
    }
}

extension StatusItemController {
    func overviewSpendSummary(providers: [UsageProvider]) -> OverviewSpendSummary? {
        let snapshots = providers.compactMap { self.store.tokenSnapshot(for: $0) }
        let costs = snapshots.compactMap { snapshot -> (currencyCode: String, amount: Double)? in
            guard let amount = snapshot.last30DaysCostUSD else { return nil }
            return (snapshot.currencyCode, amount)
        }
        guard !costs.isEmpty else { return nil }
        let tokens = snapshots.compactMap(\.last30DaysTokens)
        let prior = self.store.priorSpendCosts(providers: providers)
        return OverviewSpendSummary.build(
            costs: costs,
            tokens: tokens,
            providerCount: providers.count,
            priorCosts: prior.costs,
            priorPricedProviderCount: prior.fullWindowCount)
    }
}
