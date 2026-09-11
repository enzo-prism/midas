import CodexBarCore
import Foundation

/// Selects reported daily date keys against UTC calendar boundaries.
/// Source calendars must be disclosed; this does not rebin local-day aggregates into UTC.
enum MidasSpendPeriod: Equatable, Sendable {
    case currentMonth
    case rolling30Days
    case month(year: Int, month: Int)

    struct Range: Equatable, Sendable {
        let start: String
        let end: String

        func contains(_ day: String) -> Bool {
            day >= self.start && day <= self.end
        }

        func contains(_ other: Self) -> Bool {
            self.start <= other.start && self.end >= other.end
        }
    }

    enum CostField: Sendable {
        case cost
        case apiEquivalent
    }

    struct Amount: Equatable, Sendable {
        /// A known subtotal, never an invented zero for absent data.
        let dollars: Double?
        let range: Range
        /// This describes the supplied history, not coverage of all accounts or devices.
        let isPartial: Bool
    }

    func range(now: Date = Date()) -> Range? {
        let calendar = Self.calendar
        let today = calendar.startOfDay(for: now)
        let start: Date
        let end: Date
        switch self {
        case .rolling30Days:
            guard let first = calendar.date(byAdding: .day, value: -29, to: today) else { return nil }
            start = first
            end = today
        case .currentMonth:
            guard let interval = calendar.dateInterval(of: .month, for: today) else { return nil }
            start = interval.start
            end = today
        case let .month(year, month):
            guard (1...9999).contains(year), (1...12).contains(month),
                  let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  first <= today,
                  let interval = calendar.dateInterval(of: .month, for: first),
                  let last = calendar.date(byAdding: .day, value: -1, to: interval.end)
            else { return nil }
            start = first
            end = min(today, last)
        }
        return Range(start: Self.key(start), end: Self.key(end))
    }

    /// Missing dates mean zero only when a caller explicitly certifies that the source covers the range.
    /// A rolling total is deliberately never consulted for calendar-month calculations.
    func amount(
        snapshot: CostUsageTokenSnapshot,
        sourceCoverage: Range? = nil,
        costField: CostField = .cost,
        now: Date = Date()) -> Amount?
    {
        guard let range = self.range(now: now) else { return nil }
        guard snapshot.currencyCode == "USD" else {
            return Amount(dollars: nil, range: range, isPartial: true)
        }
        var partial = sourceCoverage?.contains(range) != true
        var seen: Set<String> = []
        var sum = 0.0
        var pricedRows = 0
        for row in snapshot.daily {
            guard Self.isValidDay(row.date) else {
                partial = true
                continue
            }
            guard range.contains(row.date) else { continue }
            // Duplicate daily aggregates cannot safely be added or arbitrarily picked.
            guard seen.insert(row.date).inserted else {
                return Amount(dollars: nil, range: range, isPartial: true)
            }
            let cost = switch costField {
            case .cost: row.costUSD
            case .apiEquivalent: row.apiEquivalentCostUSD
            }
            if (row.unpricedRequestCount ?? 0) > 0 { partial = true }
            guard let cost, cost.isFinite, cost >= 0 else {
                partial = true
                continue
            }
            sum += cost
            guard sum.isFinite else { return Amount(dollars: nil, range: range, isPartial: true) }
            pricedRows += 1
        }
        let amount = pricedRows > 0 || !partial ? sum : nil
        return Amount(dollars: amount, range: range, isPartial: partial)
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func key(_ date: Date) -> String {
        let components = Self.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func isValidDay(_ text: String) -> Bool {
        let parts = text.split(separator: "-")
        guard parts.count == 3, text.count == 10,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let date = Self.calendar.date(from: DateComponents(year: year, month: month, day: day))
        else { return false }
        return Self.key(date) == text
    }
}
