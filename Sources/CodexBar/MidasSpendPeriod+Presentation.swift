import CodexBarCore
import Foundation

extension MidasSpendPeriod {
    init(selection: String) {
        if selection == "rolling30Days" { self = .rolling30Days; return }
        let parts = selection.split(separator: "-")
        if parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month) {
            self = .month(year: year, month: month)
        } else {
            self = .currentMonth
        }
    }

    var label: String {
        guard self != .rolling30Days else { return "Last 30 days" }
        guard let range = self.range() else { return "Month unavailable" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: range.start) else { return "Month unavailable" }
        formatter.locale = .current
        formatter.dateFormat = self == .currentMonth ? "MMMM" : "MMM yyyy"
        return formatter.string(from: date)
    }
}

extension StatusItemController {
    func midasPeriodPresentation(
        _ presentation: MidasProviderPresentation, token: CostUsageTokenSnapshot?) -> MidasProviderPresentation
    {
        var result = presentation
        let period = MidasSpendPeriod(selection: self.settings.midasSpendPeriodSelection)
        guard let token, let original = result.spend, original.isEstimate else {
            result.spend = nil
            if presentation.provider == .codex, self.settings.midasCloudUsageEnabled {
                result.spendUnavailableReason = self.settings.midasCloudUSDPerMillionTokens <= 0
                    ? "Set estimate rate" : "History pending"
            } else {
                result.spendUnavailableReason = "Estimate unavailable"
            }
            return result
        }
        guard let estimate = period.amount(snapshot: token), let amount = estimate.dollars else {
            result.spend = nil
            result.spendUnavailableReason = "No priced history for this period"
            return result
        }
        let scope = "\(estimate.range.start)–\(estimate.range.end)"
        let calendarNote = result.provider == .codex && self.settings.midasCloudUsageEnabled
            ? "OpenAI daily dates use UTC."
            : "Uses recorded daily dates in the source’s reporting calendar."
        let coverage = "Recorded history only; complete account and date coverage is not established."
        result.spend = MidasSpendPresentation(
            title: "Estimated inference spend",
            value: amount.formatted(.currency(code: original.currency)),
            period: period.label,
            detail: original.detail + "\n\(scope). \(calendarNote) \(coverage)",
            updatedAt: original.updatedAt,
            amount: amount,
            currency: original.currency,
            secondaryValue: nil,
            secondaryLabel: nil,
            isEstimate: true,
            coverageNote: estimate.isPartial ? coverage : nil)
        return result
    }
}
