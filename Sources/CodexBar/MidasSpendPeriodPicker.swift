import CodexBarCore
import SwiftUI

/// A native menu keeps date selection out of the compact panel's content flow.
struct MidasSpendPeriodControl: View {
    @Bindable var settings: SettingsStore
    let store: UsageStore

    private var months: [String] {
        let dates = self.store.midasProvidersForUsageDisplay().flatMap { provider in
            self.store.displayTokenSnapshot(for: provider)?.daily.map(\.date) ?? []
        }
        return MidasSpendPeriodChoices.recordedMonths(
            dates: dates,
            selection: self.settings.midasSpendPeriodSelection,
            timeZone: self.store.midasDisplayTimeZone)
    }

    var body: some View {
        Menu {
            Picker("Spend period", selection: self.$settings.midasSpendPeriodSelection) {
                Text("This month").tag("currentMonth")
                Text("Last 30 days").tag("rolling30Days")
                if !self.months.isEmpty {
                    Section("Recorded months") {
                        ForEach(self.months, id: \.self) { month in
                            Text(MidasSpendPeriod(selection: month).label).tag(month)
                        }
                    }
                }
            }
            .pickerStyle(.inline)
            Divider()
            Text(MidasSpendPeriodChoices.dateLabel(
                selection: self.settings.midasSpendPeriodSelection,
                timeZone: self.store.midasDisplayTimeZone))
        } label: {
            Text(MidasSpendPeriod(selection: self.settings.midasSpendPeriodSelection)
                .label(reportingTimeZone: self.store.midasDisplayTimeZone))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .controlSize(.small)
        .accessibilityLabel("Spend period")
        .accessibilityValue(MidasSpendPeriod(selection: self.settings.midasSpendPeriodSelection)
            .label(reportingTimeZone: self.store.midasDisplayTimeZone))
        .help("Choose the date range for estimated spend")
    }
}

/// Dates are validated before becoming choices; malformed history must never look like the current month.
enum MidasSpendPeriodChoices {
    static func recordedMonths(
        dates: [String],
        selection: String = "currentMonth",
        now: Date = Date(),
        timeZone: TimeZone = .current) -> [String]
    {
        let formatter = self.formatter
        let current = String(MidasSpendPeriod.currentMonth.range(now: now, timeZone: timeZone)?.start.prefix(7) ?? "")
        let candidates = dates + (selection.count == 7 ? [selection + "-01"] : [])
        return Set(candidates.compactMap { day -> String? in
            guard day.count == 10, let date = formatter.date(from: day), formatter.string(from: date) == day else {
                return nil
            }
            let month = String(day.prefix(7))
            return month < current ? month : nil
        }).sorted(by: >)
    }

    static func dateLabel(selection: String, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        guard let range = MidasSpendPeriod(selection: selection).range(now: now, timeZone: timeZone),
              let start = self.formatter.date(from: range.start), let end = self.formatter.date(from: range.end)
        else { return "Dates unavailable" }
        let format = DateIntervalFormatter()
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateTemplate = "MMM d"
        return format.string(from: start, to: end)
    }

    private static var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}
