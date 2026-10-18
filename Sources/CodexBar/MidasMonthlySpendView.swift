import Charts
import SwiftUI

/// Calendar-month comparisons use the full provider snapshot, independently of daily history filters.
struct MidasMonthlySpendView: View {
    let model: MidasMonthlySpend
    @Binding var showsCosts: Bool
    @Binding var monthCount: Int
    @State private var hoveredMonth: String?
    @State private var selectedMonth: String?

    private var metric: MidasMonthlySpend.Metric {
        self.showsCosts ? .cost : .tokens
    }

    private var focusedMonth: MidasMonthlySpend.Month? {
        self.model.months.first { $0.id == (self.hoveredMonth ?? self.selectedMonth) }
            ?? self.model.months.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    self.title
                    Spacer()
                    self.metricPicker
                }
                VStack(alignment: .leading, spacing: 12) {
                    self.title
                    self.metricPicker
                }
            }
            if let month = self.focusedMonth {
                self.summary(month)
            }
            if self.model.months.contains(where: { self.value($0) != nil }) {
                self.chart
            } else {
                ContentUnavailableView(
                    self.showsCosts ? "No priced monthly records" : "No monthly token records",
                    systemImage: "chart.bar.xaxis",
                    description: Text("Available daily records will be grouped into calendar months here."))
                    .frame(minHeight: 180)
            }
            HStack {
                Picker("Months shown", selection: self.$monthCount) {
                    Text("6 months").tag(6)
                    Text("12 months").tag(12)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
                Spacer()
                Button { self.moveSelection(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous month")
                    .disabled(self.focusedIndex == nil || self.focusedIndex == 0)
                Button { self.moveSelection(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next month")
                    .disabled(self.focusedIndex == nil || self.focusedIndex == self.model.months.count - 1)
            }
            Text("Recorded subtotals only. Missing days and unpriced activity are excluded; "
                + "a gap is unavailable, not zero. The current month is still in progress.")
                .font(.caption)
                .foregroundStyle(MidasTheme.secondaryText)
            if self.showsCosts {
                Text(self.model.explanation)
                    .font(.caption)
                    .foregroundStyle(MidasTheme.secondaryText)
            }
            DisclosureGroup("Monthly records") {
                self.monthlyRecords.padding(.top, 12)
            }
            .font(.callout)
        }
        .onChange(of: self.model.months.map(\.id)) { _, months in
            if let selectedMonth, !months.contains(selectedMonth) { self.selectedMonth = nil }
            self.hoveredMonth = nil
        }
    }

    private var title: some View {
        Text("Month by month").font(.system(size: 20, weight: .semibold))
    }

    private var metricPicker: some View {
        Picker("Monthly metric", selection: self.$showsCosts) {
            Text("Costs").tag(true)
            Text("Tokens").tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 170)
    }

    private func summary(_ month: MidasMonthlySpend.Month) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(self.monthLabel(month) + (month.isCurrentMonth ? " · month to date" : ""))
                Spacer()
                Text(self.coverage(month))
            }
            .font(.caption)
            .foregroundStyle(MidasTheme.secondaryText)
            Text(self.formatted(month))
                .font(.system(size: 32, weight: .medium))
                .monospacedDigit()
                .textSelection(.enabled)
            Text(self.showsCosts ? self.model.costLabel : "Recorded tokens")
                .font(.caption).foregroundStyle(MidasTheme.secondaryText)
            if let comparison = self.model.comparison(for: month.id, metric: self.metric) {
                let percent = comparison.percent.map { " (\($0.formatted(.number.precision(.fractionLength(1))))%)" }
                    ?? ""
                Text("\(comparison.delta > 0 ? "+" : "")\(self.formatted(comparison.delta))\(percent) "
                    + "vs previous month’s recorded subtotal")
                    .font(.callout).monospacedDigit()
                if let day = comparison.throughDay {
                    Text("Both months through day \(day): \(self.formatted(comparison.current)) "
                        + "vs \(self.formatted(comparison.previous)).")
                        .font(.caption).foregroundStyle(MidasTheme.secondaryText)
                }
            } else {
                Text("Comparison unavailable · matching records in the previous month are required.")
                    .font(.caption).foregroundStyle(MidasTheme.secondaryText)
            }
        }
        .frame(minHeight: 126, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    private var chart: some View {
        Chart {
            ForEach(self.model.months) { month in
                if let value = self.value(month) {
                    BarMark(x: .value("Month", month.id), y: .value(self.axisLabel, value))
                        .foregroundStyle(MidasTheme.accent.opacity(month.isCurrentMonth ? 0.55 : 1))
                        .cornerRadius(4)
                        .accessibilityLabel(self.monthLabel(month))
                        .accessibilityValue(self.formatted(month) + ". " + self.coverage(month))
                    if value == 0 {
                        PointMark(x: .value("Month", month.id), y: .value(self.axisLabel, 0))
                            .foregroundStyle(MidasTheme.accent)
                            .accessibilityHidden(true)
                    }
                }
            }
            if let month = self.focusedMonth {
                RuleMark(x: .value("Selected month", month.id))
                    .foregroundStyle(MidasTheme.secondaryText.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: self.model.months.map(\.id))
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXSelection(value: self.$hoveredMonth)
        .chartYAxisLabel(self.axisLabel)
        .chartXAxis {
            AxisMarks(values: self.model.months.map(\.id)) { axis in
                AxisValueLabel(anchor: .top) {
                    if let key = axis.as(String.self), let month = self.model.months.first(where: { $0.id == key }) {
                        VStack(spacing: 2) {
                            if self.model.months.count > 6 {
                                Text(month.date.formatted(Self.shortMonthFormat))
                                Text(month.date.formatted(Self.yearFormat))
                            } else {
                                Text(month.date.formatted(Self.axisFormat))
                            }
                            if self.value(month) == nil { Text("—").foregroundStyle(MidasTheme.secondaryText) }
                        }
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                AxisGridLine()
                AxisValueLabel(format: Decimal.FormatStyle.number.notation(.compactName))
            }
        }
        .frame(height: 220)
        .accessibilityLabel(self.showsCosts ? "Monthly \(self.model.costLabel)" : "Monthly token usage")
        .accessibilityValue("\(self.model.months.count) calendar months. Exact values are in Monthly records.")
        .help("Hover over a month to compare recorded totals, or use the month buttons and Monthly records.")
    }

    private var monthlyRecords: some View {
        VStack(spacing: 4) {
            ForEach(self.model.months.reversed()) { month in
                Button {
                    self.hoveredMonth = nil
                    self.selectedMonth = month.id
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(self.monthLabel(month) + (month.isCurrentMonth ? " · to date" : ""))
                            Text(self.coverage(month)).font(.caption).foregroundStyle(MidasTheme.secondaryText)
                        }
                        Spacer()
                        Text(self.formatted(month)).monospacedDigit()
                    }
                    .padding(10)
                    .contentShape(Rectangle())
                    .background(
                        self.focusedMonth?.id == month.id ? MidasTheme.accent.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(self.focusedMonth?.id == month.id ? .isSelected : [])
                .accessibilityHint("Select this month for comparison")
            }
        }
    }

    private var axisLabel: String {
        self.showsCosts ? self.model.currency : "Tokens"
    }

    private var focusedIndex: Int? {
        self.model.months.firstIndex { $0.id == self.focusedMonth?.id }
    }

    private func moveSelection(_ offset: Int) {
        guard let index = self.focusedIndex, self.model.months.indices.contains(index + offset) else { return }
        self.hoveredMonth = nil
        self.selectedMonth = self.model.months[index + offset].id
    }

    private func value(_ month: MidasMonthlySpend.Month) -> Double? {
        self.showsCosts ? month.cost : month.tokens.map(Double.init)
    }

    private func formatted(_ value: Double?) -> String {
        guard let value else { return "Unavailable" }
        return self.showsCosts ? MidasCostPresentation.money(value, currency: self.model.currency)
            : value.formatted(.number.precision(.fractionLength(0)))
    }

    private func formatted(_ month: MidasMonthlySpend.Month) -> String {
        self.showsCosts ? self.formatted(month.cost) : (month.tokens?.formatted() ?? "Unavailable")
    }

    private func coverage(_ month: MidasMonthlySpend.Month) -> String {
        if month.hasDuplicateDays { return "Conflicting daily records" }
        let valued = self.showsCosts ? month.pricedDays : month.tokenDays
        let unpriced = self.showsCosts && month.hasUnpricedUsage ? " · unpriced activity" : ""
        return "\(month.recordedDays) recorded days · \(valued) with \(self.showsCosts ? "costs" : "tokens")\(unpriced)"
    }

    private func monthLabel(_ month: MidasMonthlySpend.Month) -> String {
        month.date.formatted(Self.monthFormat)
    }

    private static var axisFormat: Date.FormatStyle {
        var format = Date.FormatStyle().month(.abbreviated).year(.twoDigits)
        format.timeZone = MidasSpendPeriod.utc
        format.calendar = Calendar(identifier: .gregorian)
        return format
    }

    private static var monthFormat: Date.FormatStyle {
        var format = Date.FormatStyle().month(.wide).year()
        format.timeZone = MidasSpendPeriod.utc
        format.calendar = Calendar(identifier: .gregorian)
        return format
    }

    private static var shortMonthFormat: Date.FormatStyle {
        var format = Date.FormatStyle().month(.abbreviated)
        format.timeZone = MidasSpendPeriod.utc
        format.calendar = Calendar(identifier: .gregorian)
        return format
    }

    private static var yearFormat: Date.FormatStyle {
        var format = Date.FormatStyle().year(.twoDigits)
        format.timeZone = MidasSpendPeriod.utc
        format.calendar = Calendar(identifier: .gregorian)
        return format
    }
}
