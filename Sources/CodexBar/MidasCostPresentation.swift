import CodexBarCore
import Foundation

/// A display-only projection. Missing values and days never become zero.
struct MidasCostPresentation {
    enum Period: String, CaseIterable, Identifiable {
        case week = "7 days"
        case month = "30 days"
        case all = "All available"
        var id: String {
            self.rawValue
        }

        var days: Int? {
            switch self {
            case .week: 7
            case .month: 30
            case .all: nil
            }
        }
    }

    struct Day: Identifiable {
        let id: String
        let date: Date
        let tokens: Int?
        let requests: Int?
        let cost: Double?
        let apiEquivalent: Double?
    }

    struct Model: Identifiable {
        let id: String
        let tokens: Int?
        let cost: Double?
    }

    let days: [Day]
    let models: [Model]
    let currency: String
    let costLabel: String
    let explanation: String
    let updatedAt: Date?
    let coverage: String
    let totalTokens: Int?
    let totalCost: Double?
    let totalAPIEquivalent: Double?
    let meteredTotal: Double?
    let meteredPeriod: String

    init(
        snapshot: CostUsageTokenSnapshot?,
        period: Period,
        now: Date = Date(),
        reportingCalendar: Calendar = .current)
    {
        self.currency = snapshot?.currencyCode ?? "USD"
        self.updatedAt = snapshot?.updatedAt
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        // Preserve source date keys as neutral calendar days. Cursor/local token logs use local dates;
        // parsing at UTC midnight is only a stable plotting coordinate, not a claim about the source zone.
        let localDayFormatter = DateFormatter()
        localDayFormatter.calendar = calendar
        localDayFormatter.locale = Locale(identifier: "en_US_POSIX")
        localDayFormatter.timeZone = reportingCalendar.timeZone
        localDayFormatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.date(from: localDayFormatter.string(from: now)) ?? calendar.startOfDay(for: now)
        let lower = period.days.flatMap { calendar.date(byAdding: .day, value: 1 - $0, to: today) }
        let entries = (snapshot?.daily ?? []).filter { entry in
            guard let date = formatter.date(from: entry.date), formatter.string(from: date) == entry.date else {
                return false
            }
            return date <= today && (lower == nil || date >= lower!)
        }.sorted { $0.date < $1.date }
        // The chart sums daily records only; meteredCostUSD is shown separately below it.
        // Cursor marks their enclosing snapshot mixed even when every daily row is an API estimate.
        let dailyProvenance = CostProvenance.forWindow(
            snapshot: snapshot?.costProvenance ?? .unknown,
            hasWindowCosts: entries.contains { Self.valid($0.costUSD) != nil },
            includesMetered: false)
        switch dailyProvenance {
        case .listPriceEstimate:
            if entries.contains(where: { Self.valid($0.apiEquivalentCostUSD) != nil }) {
                self.costLabel = "Estimated model-tier cost"
                self.explanation = "Token usage valued at the model's pricing tier. This is an estimate, not a bill. "
                    + "Standard API-equivalent value is shown separately."
            } else {
                self.costLabel = "API-equivalent value"
                self.explanation = "Token usage valued at public API rates. This is an estimate, not a bill."
            }
        case .vendorMetered:
            self.costLabel = "Provider-metered usage"
            self.explanation = "Usage reported by the provider. Plan deductions are not necessarily cash charges."
        case .mixed:
            self.costLabel = "Mixed-source usage value"
            self.explanation = "These records mix provider metering and API-rate estimates; they are not billed spend."
        case .unknown:
            self.costLabel = "Usage value · source unspecified"
            self.explanation = "The source does not establish how these values were calculated. Billing is unavailable."
        }
        self.days = entries.compactMap { entry in
            guard let date = formatter.date(from: entry.date) else { return nil }
            return Day(
                id: entry.date,
                date: date,
                tokens: entry.totalTokens,
                requests: entry.requestCount,
                cost: Self.valid(entry.costUSD),
                apiEquivalent: Self.valid(entry.apiEquivalentCostUSD))
        }
        let grouped = Dictionary(grouping: entries.flatMap { $0.modelBreakdowns ?? [] }, by: \.modelName)
        self.models = grouped.map { name, rows in
            Model(
                id: name,
                tokens: Self.sum(rows.map(\.totalTokens)),
                cost: Self.sum(rows.map { Self.valid($0.costUSD) }))
        }.sorted { ($0.tokens ?? 0) > ($1.tokens ?? 0) }
        self.totalTokens = Self.sum(self.days.map(\.tokens))
        self.totalCost = Self.sum(self.days.map(\.cost))
        self.totalAPIEquivalent = Self.sum(self.days.map(\.apiEquivalent))
        self.meteredTotal = Self.valid(snapshot?.meteredCostUSD)
        self.meteredPeriod = snapshot?.historyLabel ?? "\(snapshot?.historyDays ?? 0)-day source window"
        let priced = self.days.count(where: { $0.cost != nil })
        if self.days.isEmpty {
            self.coverage = "No daily records available for this period. Missing days are not treated as zero."
        } else {
            self.coverage = "\(self.days.count) recorded days · \(priced) with a usage value. "
                + "Totals include recorded values only; missing days and unpriced usage are excluded."
        }
    }

    func money(_ amount: Double?) -> String {
        guard let amount else { return "Unavailable" }
        return amount.formatted(.currency(code: self.currency))
    }

    private static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func sum<T: AdditiveArithmetic>(_ values: [T?]) -> T? {
        let known = values.compactMap(\.self)
        return known.isEmpty ? nil : known.reduce(.zero, +)
    }
}
