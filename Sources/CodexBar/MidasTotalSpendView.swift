import SwiftUI

struct MidasTotalSpendView: View {
    let presentations: [MidasProviderPresentation]
    var periodLabel: String?
    var periodAction: (() -> Void)?
    @State private var showsCoverage = false

    private var total: MidasTotalSpend {
        MidasTotalSpend(presentations: self.presentations)
    }

    var body: some View {
        let total = self.total
        VStack(alignment: .leading, spacing: 10) {
            Text("Estimated inference spend")
                .font(.callout).foregroundStyle(MidasTheme.secondaryText)
            if total.totals.isEmpty {
                Text("—").font(.system(size: 44, weight: .semibold))
                    .accessibilityLabel("Estimated inference spend unavailable")
            } else {
                ForEach(total.totals) { currency in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(MidasOverviewMoney.format(currency.amount, currency: currency.currency))
                            .font(.system(size: 44, weight: .semibold))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                            .textSelection(.enabled)
                        if total.totals.count > 1 {
                            Text(currency.currency).font(.caption).foregroundStyle(MidasTheme.secondaryText)
                        }
                    }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                if let periodAction {
                    Button(action: periodAction) {
                        Label(self.periodLabel ?? total.periodText, systemImage: "chevron.down")
                    }.buttonStyle(.plain)
                } else if !total.totals.isEmpty || self.periodLabel != nil {
                    Text(self.periodLabel ?? total.periodText)
                }
                Spacer(minLength: 8)
                if !self.presentations.isEmpty {
                    Button(self.coverageLabel) { self.showsCoverage = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(self.isPartial ? MidasTheme.warning : MidasTheme.secondaryText)
                        .popover(isPresented: self.$showsCoverage) { self.coverage }
                }
            }
            .font(.caption).foregroundStyle(MidasTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(MidasTheme.text)
    }

    private var isPartial: Bool {
        self.total.hasIncompleteCoverage
    }

    private var coverageLabel: String {
        self.total.totals.isEmpty ? "Estimate unavailable" : self.isPartial ? "Partial total" : "Estimate details"
    }

    private var coverage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Estimate coverage").font(.headline)
                Text(self.total.coverageText).font(.callout)
                ForEach(self.presentations, id: \.provider) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.callout.weight(.semibold))
                        Text(item.spend?.detail ?? item.spendUnavailableReason ?? "No dollar estimate available.")
                        if let cloud = item.cloudUsage { Text(cloud.coverage) }
                        if let spend = item.spend {
                            Text("Updated \(spend.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                    .font(.caption).foregroundStyle(MidasTheme.secondaryText)
                }
            }
            .padding(18)
        }.frame(width: 336).frame(maxHeight: 440)
    }
}
