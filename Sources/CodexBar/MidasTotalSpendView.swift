import SwiftUI

struct MidasTotalSpendView: View {
    let presentations: [MidasProviderPresentation]

    private var total: MidasTotalSpend {
        MidasTotalSpend(presentations: self.presentations)
    }

    var body: some View {
        let total = self.total
        VStack(alignment: .leading, spacing: 10) {
            Text("Total token spend (API rates)")
                .font(.callout).foregroundStyle(MidasTheme.secondaryText)
            if total.totals.isEmpty {
                Text("—").font(.system(size: 42, weight: .semibold))
                    .accessibilityLabel("Total token spend (API rates) unavailable")
            } else {
                ForEach(total.totals) { currency in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(currency.value)
                            .font(.system(size: 42, weight: .semibold))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                            .textSelection(.enabled)
                        if total.totals.count > 1 {
                            Text(currency.currency).font(.caption).foregroundStyle(MidasTheme.secondaryText)
                        }
                    }
                }
                Text(total.periodText).font(.callout).foregroundStyle(MidasTheme.secondaryText)
            }
            Text(total.coverageText).font(.caption).foregroundStyle(MidasTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(MidasTheme.text)
        .accessibilityElement(children: .combine)
        .help(total.oldestUpdate.map {
            "Oldest included estimate updated \($0.formatted(date: .abbreviated, time: .shortened))"
        } ?? "Estimates are summed across enabled providers; unavailable values are excluded.")
    }
}
