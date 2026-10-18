import SwiftUI

struct MidasTotalSpendView: View {
    let presentations: [MidasProviderPresentation]
    var tokenTotal: MidasRecordedTokenTotal?
    var periodLabel: String?
    var periodControl: AnyView?
    var compact = false
    var coverageAction: (() -> Void)?
    @State private var showsCoverage = false

    private var total: MidasTotalSpend {
        MidasTotalSpend(presentations: self.presentations)
    }

    var body: some View {
        let total = self.total
        VStack(alignment: .leading, spacing: self.compact ? 5 : 10) {
            HStack {
                Text("Estimated AI token value")
                    .font(self.compact ? .system(size: 11, weight: .medium) : .callout)
                    .foregroundStyle(MidasTheme.secondaryText)
                Spacer(minLength: 4)
                if self.compact, let periodControl { periodControl }
            }
            if total.totals.isEmpty {
                Text("—").font(.system(size: self.compact ? 34 : 44, weight: .semibold))
                    .accessibilityLabel("Estimated AI token value unavailable")
            } else {
                ForEach(total.totals) { currency in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(MidasOverviewMoney.format(currency.amount, currency: currency.currency))
                            .font(.system(size: self.compact ? 34 : 44, weight: .semibold))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                            .textSelection(.enabled)
                        if total.totals.count > 1 {
                            Text(currency.currency).font(.caption).foregroundStyle(MidasTheme.secondaryText)
                        }
                    }
                }
            }
            if let tokenTotal {
                Text(tokenTotal.label)
                    .font(self.compact ? .system(size: 12, weight: .medium) : .title3.weight(.medium))
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .accessibilityIdentifier("midas-recorded-token-total")
                    .help("Input, output, and cache tokens from recorded usage in the selected period. "
                        + "Missing records and provider quota percentages are excluded.")
            }
            HStack(alignment: .firstTextBaseline) {
                if !self.compact, let periodControl {
                    periodControl
                } else if !self.compact || self.periodControl == nil {
                    Text(self.periodLabel ?? total.periodText)
                } else {
                    Text(total.includedProviderCount == total.providerCount
                        ? "\(total.providerCount) \(total.providerCount == 1 ? "provider" : "providers")"
                        : "\(total.includedProviderCount) of \(total.providerCount) providers")
                }
                Spacer(minLength: 8)
                if !self.presentations.isEmpty {
                    Button {
                        if let coverageAction {
                            coverageAction()
                        } else {
                            self.showsCoverage.toggle()
                        }
                    } label: {
                        Label(
                            self.coverageLabel,
                            systemImage: self.isPartial ? "exclamationmark.circle" : "info.circle")
                            .frame(minHeight: 20)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(self.isPartial ? MidasTheme.warning : MidasTheme.secondaryText)
                    .accessibilityHint("Shows which providers contribute to the estimate")
                }
            }
            .font(self.compact ? .system(size: 11) : .caption).foregroundStyle(MidasTheme.secondaryText)
            if self.showsCoverage {
                MidasSpendCoverageView(presentations: self.presentations)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(MidasTheme.text)
    }

    private var isPartial: Bool {
        self.total.hasIncompleteCoverage || self.tokenTotal?.isPartial == true
    }

    private var coverageLabel: String {
        self.total.totals.isEmpty ? "Estimate unavailable" : self.isPartial ? "Partial total" : "Estimate details"
    }
}

struct MidasSpendCoverageView: View {
    let presentations: [MidasProviderPresentation]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(MidasTotalSpend(presentations: self.presentations).coverageText).font(.caption)
            ForEach(self.presentations, id: \.provider) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.caption.weight(.semibold))
                    Text(item.spend?.detail ?? item.spendUnavailableReason ?? "No dollar estimate available.")
                    if let cloud = item.cloudUsage { Text(cloud.coverage) }
                    if let spend = item.spend {
                        Text("Updated \(spend.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                .font(.caption).foregroundStyle(MidasTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
    }
}
