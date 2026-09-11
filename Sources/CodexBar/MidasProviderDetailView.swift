import CodexBarCore
import SwiftUI

struct MidasProviderDetailView: View {
    let presentation: MidasProviderPresentation
    let actions: MidasActions
    var showsOpenUsage = true

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            self.identity
            if let exhausted = self.presentation.metrics.first(where: \.isExhausted) {
                Label("\(exhausted.title) exhausted", systemImage: "exclamationmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(MidasTheme.warning)
                    .help(exhausted.resetText ?? "Wait for this limit to reset before continuing.")
            }
            if let cloud = self.presentation.cloudUsage {
                MidasCloudUsageView(summary: cloud, showsAccounts: true)
            }
            self.spendHeadline
            if self.actions.accountPresentations(self.presentation.provider).count > 1 {
                MidasAccountUsageView(accounts: self.actions.accountPresentations(self.presentation.provider))
            }
            self.hero
            if !self.presentation.metrics.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(self.presentation.metrics) { metric in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(metric.title)
                                Spacer()
                                Text(metric.valueText).monospacedDigit()
                                    .foregroundStyle(metric.isExhausted ? MidasTheme.warning : MidasTheme.text)
                            }
                            if let reset = metric.resetText {
                                Text(reset).font(.caption).foregroundStyle(MidasTheme.secondaryText)
                            }
                        }
                        .font(.callout)
                    }
                }
            }
            if let resets = self.presentation.resetCreditsText {
                Label(resets, systemImage: "arrow.counterclockwise")
                    .font(.callout).foregroundStyle(MidasTheme.secondaryText)
                    .help(self.presentation.resetCreditsHelp ?? resets)
            }
            if self.presentation.spend == nil, let value = self.presentation.financialSummary {
                VStack(alignment: .leading, spacing: 6) {
                    Text(self.presentation.financialLabel ?? "Provider usage")
                        .font(.caption).foregroundStyle(MidasTheme.secondaryText)
                    Text(value).font(.callout).textSelection(.enabled)
                }
            }
            if !self.presentation.notes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(self.presentation.notes.enumerated()), id: \.offset) { _, note in
                        Text(note).font(.callout).foregroundStyle(MidasTheme.secondaryText)
                    }
                }
            }
            if let error = self.presentation.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Connection needs attention", systemImage: "exclamationmark.triangle")
                        .font(.callout.weight(.medium))
                    Text(error).font(.caption).textSelection(.enabled)
                    Button("Manage connection") { self.actions.accounts(self.presentation.provider) }
                        .buttonStyle(.bordered)
                }
                .foregroundStyle(MidasTheme.warning)
            }
            HStack(alignment: .top, spacing: 8) {
                if self.presentation.isRefreshing {
                    ProgressView().controlSize(.mini).accessibilityLabel("Refreshing usage")
                } else {
                    Image(systemName: self.presentation.isStale ? "clock.badge.exclamationmark" : "clock")
                        .accessibilityHidden(true)
                }
                Text(self.presentation.freshness)
                    .help(self.presentation.updatedAt?.formatted(date: .complete, time: .shortened) ?? "No update yet")
            }
            .font(.caption).foregroundStyle(MidasTheme.secondaryText)
            if self.showsOpenUsage {
                Button {
                    self.actions.openUsage(self.presentation.provider)
                } label: {
                    HStack {
                        Text("Open Usage").fontWeight(.medium)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .padding(12)
                    .background(MidasTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(MidasTheme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: 12) {
            MidasProviderLogo(provider: self.presentation.provider, size: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(self.presentation.name).font(.system(size: 20, weight: .semibold))
                if !self.presentation.account.isEmpty {
                    Text(self.presentation.account).font(.caption).lineLimit(2)
                        .foregroundStyle(MidasTheme.secondaryText)
                }
                if let plan = self.presentation.plan, !plan.isEmpty {
                    Text(plan).font(.caption).foregroundStyle(MidasTheme.secondaryText)
                }
            }
            Spacer(minLength: 0)
            Button { self.actions.accounts(self.presentation.provider) } label: {
                Image(systemName: "person.crop.circle").font(.system(size: 17))
            }
            .buttonStyle(MidasQuietButtonStyle())
            .help("Manage accounts for \(self.presentation.name)")
            .accessibilityLabel("Manage accounts for \(self.presentation.name)")
        }
    }

    private var spendHeadline: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(self.presentation.spend?.title ?? "Token spend (API rates)")
                .font(.callout).foregroundStyle(MidasTheme.secondaryText)
            Text(self.presentation.spend?.value ?? "—")
                .font(.system(size: 46, weight: .semibold))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                .textSelection(.enabled)
            if let spend = self.presentation.spend {
                Text(spend.period).font(.callout).foregroundStyle(MidasTheme.secondaryText)
                    .help("Spend data updated \(spend.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                Text(spend.detail).font(.caption).foregroundStyle(MidasTheme.secondaryText)
                if let value = spend.secondaryValue, let label = spend.secondaryLabel {
                    Text("\(label): \(value)")
                        .font(.caption).foregroundStyle(MidasTheme.secondaryText)
                }
            } else {
                Text("No recorded cost data yet")
                    .font(.caption).foregroundStyle(MidasTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var hero: some View {
        Group {
            if let metric = self.presentation.hero {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(metric.title).font(.callout).foregroundStyle(MidasTheme.secondaryText)
                        Spacer(minLength: 4)
                        Text(metric.valueText)
                            .font(.system(size: 28, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(metric.isExhausted ? MidasTheme.warning : MidasTheme.text)
                            .minimumScaleFactor(0.65).lineLimit(1)
                    }
                    MidasRemainingBar(percent: metric.remainingPercent)
                    if let reset = metric.resetText {
                        Text(reset).font(.caption).foregroundStyle(MidasTheme.secondaryText)
                            .help(metric.helpText ?? reset)
                    }
                    if metric.isExhausted {
                        Text("No capacity remaining for this period.")
                            .font(.caption).foregroundStyle(MidasTheme.warning)
                    }
                }
                .accessibilityElement(children: .combine)
            } else if let activity = self.presentation.activitySummary {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Usage remaining").font(.callout).foregroundStyle(MidasTheme.secondaryText)
                    Text("No quota reported").font(.headline)
                    Text(activity).font(.callout).textSelection(.enabled)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Usage remaining").font(.callout).foregroundStyle(MidasTheme.secondaryText)
                    Text(self.presentation.placeholder ?? "Usage unavailable")
                        .font(.headline)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MidasTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}
