import Charts
import SwiftUI

struct MidasUsageHistoryView: View {
    let model: MidasCostPresentation
    let showsCosts: Bool
    let isRefreshing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(self.showsCosts ? self.model.money(self.model.totalCost) : self.number(self.model.totalTokens))
                    .font(.system(size: 38, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .textSelection(.enabled)
                Text(self.showsCosts ? self.model.costLabel : "Recorded tokens")
                    .font(.callout)
                    .foregroundStyle(MidasTheme.secondaryText)
            }
            if self.showsCosts {
                Text(self.model.explanation).font(.callout).foregroundStyle(MidasTheme.secondaryText)
                if let apiValue = self.model.totalAPIEquivalent {
                    LabeledContent("Standard API-equivalent value", value: self.model.money(apiValue))
                }
                if let metered = self.model.meteredTotal {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Provider-metered consumption", value: self.model.money(metered))
                        Text("\(self.model.meteredPeriod) · full source window, independent of the period filter")
                            .font(.caption).foregroundStyle(MidasTheme.secondaryText)
                    }
                }
            }
            if self.hasChartValues {
                Chart(self.model.days) { day in
                    if let value = self.chartValue(day) {
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value(self.axisLabel, value))
                            .foregroundStyle(MidasTheme.accent)
                            .cornerRadius(3)
                    }
                }
                .chartYAxisLabel(self.axisLabel)
                .chartXAxisLabel("Recorded date")
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(date.formatted(Self.axisDateFormat))
                            }
                        }
                    }
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .environment(\.calendar, Self.reportingCalendar)
                .environment(\.timeZone, Self.reportingCalendar.timeZone)
                .frame(height: 210)
                .accessibilityLabel(self.showsCosts ? self.model.costLabel : "Daily token usage")
                .accessibilityValue("\(self.model.days.count) recorded days. Daily values are listed below.")
            } else {
                ContentUnavailableView(
                    "No recorded history",
                    systemImage: "chart.bar.xaxis",
                    description:
                    Text("Recorded activity will appear here when it is available for this period."))
                    .frame(minHeight: 140)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(self.model.coverage)
                if let updated = self.model.updatedAt {
                    Text("Source updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                }
                if self.isRefreshing { Label("Refreshing · showing saved records", systemImage: "arrow.clockwise") }
            }
            .font(.caption)
            .foregroundStyle(MidasTheme.secondaryText)
            if !self.model.models.isEmpty { self.modelTable }
            if !self.model.days.isEmpty { self.dailyTable }
        }
    }

    /// Date-only source records use neutral UTC plotting coordinates in MidasCostPresentation.
    /// Keep chart binning and labels in the same zone, including on Pacific-time Macs.
    private static var reportingCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static var axisDateFormat: Date.FormatStyle {
        var format = Date.FormatStyle().month(.abbreviated).day()
        format.calendar = Self.reportingCalendar
        format.timeZone = Self.reportingCalendar.timeZone
        return format
    }

    private var axisLabel: String {
        self.showsCosts ? self.model.currency : "Tokens"
    }

    private var hasChartValues: Bool {
        self.model.days.contains { self.chartValue($0) != nil }
    }

    private func chartValue(_ day: MidasCostPresentation.Day) -> Double? {
        self.showsCosts ? day.cost : day.tokens.map(Double.init)
    }

    private func number(_ value: Int?) -> String {
        value?.formatted() ?? "Unavailable"
    }

    private var modelTable: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("By model").font(.system(size: 17, weight: .semibold))
            Text("Available model records · totals may not cover all daily activity")
                .font(.caption).foregroundStyle(MidasTheme.secondaryText)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow {
                    Text("Model")
                    Text(self.showsCosts ? self.model.currency : "Tokens")
                }.font(.caption).foregroundStyle(MidasTheme.secondaryText)
                ForEach(self.model.models) { item in
                    GridRow {
                        Text(item.id).frame(maxWidth: .infinity, alignment: .leading)
                        Text(self.showsCosts ? self.model.money(item.cost) : self.number(item.tokens))
                            .monospacedDigit().gridColumnAlignment(.trailing)
                    }
                }
            }
            .textSelection(.enabled)
        }
    }

    private var dailyTable: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Daily records").font(.system(size: 17, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow {
                    Text("Date").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Tokens")
                    Text(self.showsCosts ? self.model.currency : "Requests")
                }.font(.caption).foregroundStyle(MidasTheme.secondaryText)
                ForEach(self.model.days.reversed()) { day in
                    GridRow {
                        Text(day.id)
                        Text(self.number(day.tokens)).monospacedDigit().gridColumnAlignment(.trailing)
                        Text(self.showsCosts ? self.model.money(day.cost) : self.number(day.requests))
                            .monospacedDigit().gridColumnAlignment(.trailing)
                    }
                }
            }
            .textSelection(.enabled)
        }
    }
}
