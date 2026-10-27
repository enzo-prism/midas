import CodexBarCore
import SwiftUI

/// Button values retain quotas as well as money when SwiftUI combines their children.
enum MidasCompactAccessibility {
    static func summary(_ item: MidasProviderPresentation, accounts: [MidasAccountPresentation] = []) -> String {
        var parts: [String] = []
        if let spark = item.dgxSpark {
            let value = spark.amount.map { MidasOverviewMoney.format($0, currency: "USD") } ?? "Unavailable"
            parts.append("API-equivalent value, last 30 days UTC: \(value), not a bill")
        } else if let spend = item.spend, spend.isDisplayable {
            parts
                .append(
                    "\(spend.accessibilityTitle): \(MidasOverviewMoney.format(spend.amount, currency: spend.currency))")
            if spend.isBilled { parts.append("Billed separately; excluded from estimate total") }
            if spend.coverageNote != nil { parts.append("Partial estimate") }
        } else {
            parts.append(item.spendUnavailableReason ?? "Estimate unavailable")
        }
        if let spark = item.dgxSpark {
            parts.append("\(spark.tokenText) recorded tokens, last 30 days UTC")
            parts.append(spark.pricingCoverageText)
            parts.append(spark.coverageText)
            parts.append(spark.freshnessText)
        } else if accounts.count > 1 {
            for account in accounts {
                parts.append(account.displayName ?? account.presentation.account)
                parts.append(contentsOf: self.usage(account.presentation))
            }
        } else {
            let account = item.provider == .codex ? accounts.first : nil
            if let account { parts.append(account.displayName ?? account.presentation.account) }
            parts.append(contentsOf: self.usage(account?.presentation ?? item))
        }
        if item.isRefreshing { parts.append("Refreshing usage") }
        return parts.joined(separator: "; ")
    }

    private static func usage(_ item: MidasProviderPresentation) -> [String] {
        let metrics = MidasAccountQuotaLayout.overviewMetrics(item)
        var parts = metrics.map {
            "\($0.title): \($0.valueText), \(MidasAccountQuotaLayout.resetLine($0, includesWindow: false))"
        }
        if metrics.isEmpty, !item.activityMetrics.isEmpty {
            parts = item.activityMetrics.map { "\($0.title): \($0.valueText), \($0.detailText)" }
            parts.append("Estimated left versus busiest recorded day or week; no reported plan limit")
        } else if metrics.isEmpty {
            parts.append("Limit unavailable")
        }
        if let resets = item.resetCreditsText { parts.append("Reset credits: \(resets)") }
        if item.isStale || item.error != nil {
            parts
                .append(metrics.isEmpty && item.activityMetrics
                    .isEmpty ? "Connection needs attention" : "Last known usage")
        }
        return parts
    }
}

/// Independent limits share columns, never a combined or averaged quota.
struct MidasCompactOverviewMetrics: View {
    let item: MidasProviderPresentation
    var accounts: [MidasAccountPresentation] = []

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        if let spark = self.item.dgxSpark {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(spark.tokenText) tokens · Last 30 days UTC")
                    .font(.system(size: 12)).monospacedDigit()
                Text("API-equivalent value · \(spark.basisText)")
                    .font(.system(size: 11)).foregroundStyle(MidasTheme.secondaryText)
                Text(spark.pricingCoverageText)
                    .font(.system(size: 11)).foregroundStyle(MidasTheme.secondaryText)
                Text(spark.coverageText)
                    .font(.system(size: 11)).foregroundStyle(MidasTheme.secondaryText)
            }
        } else if self.accounts.count > 1 {
            LazyVGrid(columns: self.columns, alignment: .leading, spacing: 10) {
                ForEach(self.accounts) { account in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(account.displayName ?? account.presentation.account)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                            .help(account.presentation.account)
                        self.metrics(account.presentation)
                        if account.presentation.resetCreditsText != nil {
                            MidasBankedResetsRow(presentation: account.presentation)
                                .font(.system(size: 11))
                        }
                        if account.presentation.isStale || account.presentation.error != nil {
                            Label("Last known usage", systemImage: "clock")
                                .font(.system(size: 11)).foregroundStyle(MidasTheme.warning)
                        }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                let account = self.item.provider == .codex ? self.accounts.first : nil
                let usage = account?.presentation ?? self.item
                if let account {
                    Text(account.displayName ?? account.presentation.account)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                        .help(account.presentation.account)
                }
                let metrics = MidasAccountQuotaLayout.overviewMetrics(usage)
                if metrics.count > 1 {
                    LazyVGrid(columns: self.columns, alignment: .leading, spacing: 8) {
                        ForEach(metrics) { metric in MidasCompactQuotaMetric(metric: metric) }
                    }
                } else {
                    self.metrics(usage)
                }
                if usage.resetCreditsText != nil {
                    MidasBankedResetsRow(presentation: usage)
                }
                if account != nil, usage.isStale || usage.error != nil {
                    Label("Last known usage", systemImage: "clock")
                        .font(.system(size: 11)).foregroundStyle(MidasTheme.warning)
                }
            }
        }
    }

    @ViewBuilder private func metrics(_ item: MidasProviderPresentation) -> some View {
        let metrics = MidasAccountQuotaLayout.overviewMetrics(item)
        if !metrics.isEmpty {
            ForEach(metrics) { metric in MidasCompactQuotaMetric(metric: metric) }
        } else if !item.activityMetrics.isEmpty {
            LazyVGrid(columns: self.columns, alignment: .leading, spacing: 8) {
                ForEach(item.activityMetrics) { metric in MidasCompactActivityMetric(metric: metric) }
            }
        } else {
            Label(
                item.error != nil ? "Usage unavailable · needs attention" : "Limit unavailable",
                systemImage: item.error != nil ? "exclamationmark.circle" : "minus.circle")
                .font(.system(size: 11)).foregroundStyle(MidasTheme.secondaryText)
        }
    }
}

/// Historical activity keeps the same compact rhythm as quotas without implying a plan limit.
struct MidasCompactActivityMetric: View {
    let metric: MidasActivityMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(self.metric.title)
                    .font(.system(size: 11)).foregroundStyle(MidasTheme.secondaryText)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Text(self.metric.valueText)
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .lineLimit(1).fixedSize()
            }
            if self.metric.hasBaseline {
                MidasRemainingBar(percent: self.metric.remainingPercent, warningWhenLow: false)
            }
            Text(self.metric.hasBaseline ? "vs \(self.metric.comparisonLabel)" : "No baseline")
                .font(.system(size: 11)).foregroundStyle(MidasTheme.secondaryText)
                .lineLimit(1).truncationMode(.middle)
        }
        .help("\(self.metric.detailText). Historical activity baseline; no reported plan limit.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.metric.title)
        .accessibilityValue("\(self.metric.valueText), \(self.metric.detailText), no reported plan limit")
    }
}

struct MidasCompactQuotaMetric: View {
    let metric: MidasQuotaMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(self.metric.title)
                    .font(.system(size: 11)).foregroundStyle(MidasTheme.secondaryText)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Text(self.metric.valueText)
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(self.metric.isExhausted ? MidasTheme.warning : MidasTheme.text)
                    .lineLimit(1).fixedSize()
            }
            if self.metric.statusText == nil {
                MidasRemainingBar(percent: self.metric.remainingPercent)
                    .opacity(self.metric.isLastKnown ? 0.55 : 1)
            }
            Text(MidasAccountQuotaLayout.resetLine(self.metric, includesWindow: false))
                .font(.system(size: 11)).foregroundStyle(MidasTheme.secondaryText)
                .lineLimit(1).truncationMode(.middle)
        }
        .help(self.metric.helpText ?? MidasAccountQuotaLayout.resetLine(self.metric, includesWindow: true))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.metric.title)
        .accessibilityValue(
            "\(self.metric.valueText), \(MidasAccountQuotaLayout.resetLine(self.metric, includesWindow: false))")
    }
}
