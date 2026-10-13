import CodexBarCore
import Foundation

/// A calendar-month view of one provider's recorded daily subtotals, never a claim of complete billing coverage.
struct MidasMonthlySpend {
    enum Metric: String, CaseIterable, Identifiable {
        case cost
        case tokens

        var id: String {
            self.rawValue
        }
    }

    struct Month: Identifiable {
        let id: String
        /// UTC midnight is a neutral plotting coordinate for the source's month key, not a timezone conversion.
        let date: Date
        let tokens: Int?
        let cost: Double?
        let recordedDays: Int
        let pricedDays: Int
        let tokenDays: Int
        let isCurrentMonth: Bool
        let hasDuplicateDays: Bool
        let hasUnpricedUsage: Bool
    }

    struct Comparison {
        let current: Double
        let previous: Double
        let delta: Double
        let percent: Double?
        let isMonthToDate: Bool
        /// Both MTD subtotals stop at this shared ordinal day, capped to the previous month's length.
        let throughDay: Int?
    }

    private struct Day {
        let ordinal: Int
        let tokens: Int?
        let cost: Double?
        let isDuplicate: Bool
        let hasUnpricedUsage: Bool
    }

    let months: [Month]
    let currency: String
    let updatedAt: Date?
    let costLabel: String
    let explanation: String

    private let daysByMonth: [String: [Day]]
    private let todayOrdinal: Int

    init(
        snapshot: CostUsageTokenSnapshot?,
        monthCount: Int = 6,
        now: Date = Date(),
        reportingTimeZone: TimeZone = .current)
    {
        var reportingCalendar = Calendar(identifier: .gregorian)
        reportingCalendar.timeZone = reportingTimeZone
        let sourceToday = reportingCalendar.dateComponents([.year, .month, .day], from: now)
        let calendar = Self.calendar
        let today = calendar.date(from: sourceToday) ?? calendar.startOfDay(for: now)
        let currentMonth = calendar.dateInterval(of: .month, for: today)?.start ?? today
        self.todayOrdinal = calendar.component(.day, from: today)
        self.currency = snapshot?.currencyCode ?? "USD"
        self.updatedAt = snapshot?.updatedAt

        // Only the shared provenance copy is needed here. Avoid its unrelated unchecked token/model sums.
        let presentation = MidasCostPresentation(
            snapshot: snapshot.map(Self.provenanceSnapshot),
            period: .all,
            now: now,
            reportingCalendar: reportingCalendar)
        self.costLabel = presentation.costLabel
        self.explanation = presentation.costLabel == "Estimated model-tier cost"
            ? "Token usage valued at the model's pricing tier. This is an estimate, not a bill."
            : presentation.explanation

        let entries = (snapshot?.daily ?? []).filter { entry in
            guard let date = Self.sourceDate(entry.date) else { return false }
            return date <= today
        }
        let groupedDays = Dictionary(grouping: entries, by: \.date)
        let groupedMonths = Dictionary(grouping: groupedDays.keys, by: { String($0.prefix(7)) })
        let daysByMonth: [String: [Day]] = groupedMonths.mapValues { keys in
            keys.sorted().compactMap { key in
                guard let rows = groupedDays[key], let first = rows.first,
                      let ordinal = Int(key.suffix(2))
                else { return nil }
                let duplicate = rows.count > 1
                return Day(
                    ordinal: ordinal,
                    tokens: duplicate ? nil : Self.valid(first.totalTokens),
                    cost: duplicate ? nil : Self.valid(first.costUSD),
                    isDuplicate: duplicate,
                    hasUnpricedUsage: rows.contains { ($0.unpricedRequestCount ?? 0) > 0 })
            }
        }
        self.daysByMonth = daysByMonth
        self.months = (0..<min(12, max(1, monthCount))).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .month, value: -offset, to: currentMonth) else { return nil }
            let key = Self.monthKey(date)
            let days = daysByMonth[key] ?? []
            let duplicate = days.contains(where: \.isDuplicate)
            return Month(
                id: key,
                date: date,
                tokens: duplicate ? nil : Self.sum(days.map(\.tokens)),
                cost: duplicate ? nil : Self.sum(days.map(\.cost)),
                recordedDays: days.count,
                pricedDays: days.count(where: { $0.cost != nil }),
                tokenDays: days.count(where: { $0.tokens != nil }),
                isCurrentMonth: offset == 0,
                hasDuplicateDays: duplicate,
                hasUnpricedUsage: days.contains(where: \.hasUnpricedUsage))
        }
    }

    /// Reporting calendars describe the source, independently of whether its prices establish billing.
    static func reportingTimeZone(
        provider: UsageProvider,
        codexCloudEnabled: Bool,
        provenance: CostProvenance,
        localTimeZone: TimeZone = .current) -> TimeZone
    {
        switch provider {
        case .openai, .anthropic, .mistral:
            MidasSpendPeriod.utc
        case .codex where codexCloudEnabled:
            MidasSpendPeriod.utc
        default:
            provenance == .vendorBilled ? MidasSpendPeriod.utc : localTimeZone
        }
    }

    /// Compare adjacent months only when recorded-day coverage matches, or both completed months have all days.
    /// Even matching coverage is a comparison of recorded subtotals, not certified account-wide usage.
    func comparison(for monthID: String, metric: Metric) -> Comparison? {
        guard let month = self.months.first(where: { $0.id == monthID }),
              !month.hasDuplicateDays,
              let previousDate = Self.calendar.date(byAdding: .month, value: -1, to: month.date)
        else { return nil }
        let currentDays = self.daysByMonth[month.id] ?? []
        let previousDays = self.daysByMonth[Self.monthKey(previousDate)] ?? []
        guard !previousDays.contains(where: \.isDuplicate),
              let currentLength = Self.calendar.range(of: .day, in: .month, for: month.date)?.count,
              let previousLength = Self.calendar.range(of: .day, in: .month, for: previousDate)?.count
        else { return nil }
        let throughDay = month.isCurrentMonth ? min(self.todayOrdinal, previousLength) : nil
        let current = currentDays.filter { throughDay == nil || $0.ordinal <= throughDay! }
        let previous = previousDays.filter { throughDay == nil || $0.ordinal <= throughDay! }
        guard !current.isEmpty, !previous.isEmpty else { return nil }
        let sameDays = current.map(\.ordinal) == previous.map(\.ordinal)
        let completeMonths = !month.isCurrentMonth
            && current.count == currentLength && previous.count == previousLength
        guard sameDays || completeMonths else { return nil }

        let currentValue: Double
        let previousValue: Double
        let delta: Double
        switch metric {
        case .cost:
            guard current.allSatisfy({ $0.cost != nil && !$0.hasUnpricedUsage }),
                  previous.allSatisfy({ $0.cost != nil && !$0.hasUnpricedUsage }),
                  let currentCost = Self.sum(current.map(\.cost)),
                  let previousCost = Self.sum(previous.map(\.cost))
            else { return nil }
            currentValue = currentCost
            previousValue = previousCost
            delta = currentCost - previousCost
        case .tokens:
            guard current.allSatisfy({ $0.tokens != nil }), previous.allSatisfy({ $0.tokens != nil }),
                  let currentTokens = Self.sum(current.map(\.tokens)),
                  let previousTokens = Self.sum(previous.map(\.tokens))
            else { return nil }
            currentValue = Double(currentTokens)
            previousValue = Double(previousTokens)
            // Subtract the checked integer totals before conversion to preserve small large-count differences.
            delta = Double(currentTokens - previousTokens)
        }
        let percent = previousValue > 0 ? delta / previousValue * 100 : nil
        return Comparison(
            current: currentValue,
            previous: previousValue,
            delta: delta,
            percent: percent.flatMap { $0.isFinite ? $0 : nil },
            isMonthToDate: month.isCurrentMonth,
            throughDay: throughDay)
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MidasSpendPeriod.utc
        return calendar
    }

    private static func sourceDate(_ key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard key.count == 10, parts.count == 3,
              let year = Int(parts[0]), (1...9999).contains(year),
              let month = Int(parts[1]), (1...12).contains(month),
              let day = Int(parts[2]), (1...31).contains(day),
              let date = self.calendar.date(from: DateComponents(year: year, month: month, day: day))
        else { return nil }
        let components = self.calendar.dateComponents([.year, .month, .day], from: date)
        let roundTrip = String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0)
        return roundTrip == key ? date : nil
    }

    private static func monthKey(_ date: Date) -> String {
        let components = self.calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    private static func valid(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    private static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func sum(_ values: [Int?]) -> Int? {
        let known = values.compactMap(\.self)
        guard !known.isEmpty else { return nil }
        var total = 0
        for value in known {
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
    }

    private static func sum(_ values: [Double?]) -> Double? {
        let known = values.compactMap(\.self)
        guard !known.isEmpty else { return nil }
        var total = 0.0
        for value in known {
            total += value
            guard total.isFinite else { return nil }
        }
        return total
    }

    private static func provenanceSnapshot(_ snapshot: CostUsageTokenSnapshot) -> CostUsageTokenSnapshot {
        .init(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            currencyCode: snapshot.currencyCode,
            costProvenance: snapshot.costProvenance,
            daily: snapshot.daily.map { entry in
                .init(
                    date: entry.date,
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: nil,
                    costUSD: entry.costUSD,
                    apiEquivalentCostUSD: entry.apiEquivalentCostUSD,
                    modelsUsed: nil,
                    modelBreakdowns: nil)
            },
            updatedAt: snapshot.updatedAt)
    }
}
