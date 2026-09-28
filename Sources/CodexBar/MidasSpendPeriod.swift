import CodexBarCore
import Foundation

/// Selects reported daily date keys against calendar boundaries in the source's reporting time zone.
/// Local transcript scans key days in this Mac's time zone; OpenAI cloud and Anthropic cost reports use UTC.
/// The period must be computed in the same zone as the keys; this does not rebin aggregates between zones.
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

    static let utc = TimeZone(secondsFromGMT: 0)!

    func range(now: Date = Date(), timeZone: TimeZone = .current) -> Range? {
        let calendar = Self.calendar(timeZone)
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
        return Range(start: Self.key(start, calendar: calendar), end: Self.key(end, calendar: calendar))
    }

    /// Missing dates mean zero only when a caller explicitly certifies that the source covers the range.
    /// A rolling total is deliberately never consulted for calendar-month calculations.
    func amount(
        snapshot: CostUsageTokenSnapshot,
        sourceCoverage: Range? = nil,
        costField: CostField = .cost,
        timeZone: TimeZone = .current,
        now: Date = Date()) -> Amount?
    {
        guard let range = self.range(now: now, timeZone: timeZone) else { return nil }
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

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func key(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func isValidDay(_ text: String) -> Bool {
        let parts = text.split(separator: "-")
        guard parts.count == 3, text.count == 10,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let date = Self.calendar(Self.utc).date(from: DateComponents(year: year, month: month, day: day))
        else { return false }
        return Self.key(date, calendar: Self.calendar(Self.utc)) == text
    }
}
