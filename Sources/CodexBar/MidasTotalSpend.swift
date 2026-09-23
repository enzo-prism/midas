import Foundation

/// Estimates across the enabled providers supplied by the caller, never metered balances or secondary equivalents.
struct MidasTotalSpend {
    struct CurrencyTotal: Identifiable {
        let currency: String
        let amount: Double
        var id: String {
            self.currency
        }

        var value: String {
            self.amount.formatted(.currency(code: self.currency))
        }
    }

    let totals: [CurrencyTotal]
    let periodText: String
    let coverageText: String
    let includedProviderCount: Int
    let excludedProviderCount: Int
    /// Providers with billed organization spend, excluded from the estimate total by design.
    let billedProviderCount: Int
    let providerCount: Int
    let oldestUpdate: Date?
    let hasIncompleteCoverage: Bool

    init(presentations: [MidasProviderPresentation]) {
        var seenProviders = Set<String>()
        let unique = presentations.filter { seenProviders.insert($0.provider.rawValue).inserted }
        var sums: [String: Double] = [:]
        var periods = Set<String>()
        var updates: [Date] = []
        var included = 0
        let billed = unique.count(where: { $0.spend?.isBilled == true && $0.spend?.isEstimate != true })
        for presentation in unique {
            guard let spend = presentation.spend, spend.isEstimate,
                  spend.amount.isFinite, spend.amount >= 0
            else { continue }
            let currency = spend.currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !currency.isEmpty else { continue }
            let sum = (sums[currency] ?? 0) + spend.amount
            guard sum.isFinite else { continue }
            sums[currency] = sum
            let period = spend.period.trimmingCharacters(in: .whitespacesAndNewlines)
            periods.insert(period.isEmpty ? "Reported period" : period)
            updates.append(spend.updatedAt)
            included += 1
        }
        self.totals = sums.keys.sorted().map { CurrencyTotal(currency: $0, amount: sums[$0]!) }
        self.providerCount = unique.count
        self.includedProviderCount = included
        self.excludedProviderCount = unique.count - included
        self.oldestUpdate = updates.min()
        self.billedProviderCount = billed
        // Billed providers are intentionally separate, so they do not make the estimate incomplete.
        self.hasIncompleteCoverage = included + billed < unique.count || unique.contains {
            $0.spend?.coverageNote != nil || $0.cloudUsage?.accounts.contains {
                $0.error != nil || $0.usage?.totalTokens == nil
            } == true
        }
        if periods.count == 1, let period = periods.first {
            self.periodText = period
        } else if periods.isEmpty {
            self.periodText = "No estimate data"
        } else {
            self.periodText = "Across provider reporting periods"
        }
        if self.providerCount == 0 {
            self.coverageText = "No enabled providers"
        } else if included == 0 {
            self.coverageText = "No usable estimates · \(self.providerCount) providers"
        } else if self.excludedProviderCount > billed {
            self.coverageText = "\(included) of \(self.providerCount) providers · "
                + "\(self.excludedProviderCount) without a usable estimate"
        } else if billed > 0 {
            self.coverageText = "\(included) of \(self.providerCount) providers · "
                + "\(billed) billed shown separately"
        } else {
            self.coverageText = "\(included) \(included == 1 ? "provider" : "providers") · recorded estimates only"
        }
    }
}
