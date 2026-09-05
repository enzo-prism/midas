import CodexBarCore
import Foundation

/// Token counts only; money, requests, and quota percentages are never substituted for tokens.
enum MidasTokenTooltip {
    static func text(
        favorite: UsageProvider,
        providers: [UsageProvider],
        snapshots: [UsageProvider: CostUsageTokenSnapshot],
        now: Date = Date(),
        calendar: Calendar = .current) -> String
    {
        let enabled = Set(providers)
        let counts = enabled.compactMap { provider in
            snapshots[provider].flatMap { self.count($0, now: now, calendar: calendar) }
        }
        let selected = enabled.contains(favorite)
            ? snapshots[favorite].flatMap { self.count($0, now: now, calendar: calendar) } : nil
        let name = ProviderDefaults.metadata[favorite]?.displayName ?? favorite.rawValue
        let total = counts.isEmpty ? nil : self.sum(counts)
        let coverage = !counts.isEmpty && counts.count < enabled
            .count ? " (\(counts.count)/\(enabled.count) reporting)" : ""
        return "Past 30 days\n\(name): \(self.label(selected))\nAll providers: \(self.label(total))\(coverage)"
    }

    static func count(_ snapshot: CostUsageTokenSnapshot, now: Date, calendar: Calendar) -> Int? {
        // This historically named field can contain seven-day or billing-cycle totals.
        let rollingLabel = "Last \(snapshot.historyDays) days"
        let isRolling = snapshot.historyLabel.map {
            $0 == rollingLabel || $0.hasPrefix(rollingLabel + " (")
        } ?? true
        guard snapshot.historyDays >= 30, isRolling else { return nil }
        if snapshot.historyDays == 30, calendar.isDate(snapshot.updatedAt, inSameDayAs: now),
           let total = snapshot.last30DaysTokens
        {
            return total >= 0 ? total : nil
        }
        guard let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)),
              let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        let rows = snapshot.daily.filter {
            guard let date = formatter.date(from: $0.date) else { return false }
            return date >= start && date < end
        }
        guard !rows.isEmpty, rows.allSatisfy({ ($0.totalTokens ?? -1) >= 0 }) else { return nil }
        return self.sum(rows.compactMap(\.totalTokens))
    }

    private static func label(_ count: Int?) -> String {
        count.map { "\($0.formatted()) tokens" } ?? "Unavailable"
    }

    private static func sum(_ counts: [Int]) -> Int? {
        var total = 0
        for count in counts {
            let next = total.addingReportingOverflow(count)
            guard !next.overflow else { return nil }
            total = next.partialValue
        }
        return total
    }
}
