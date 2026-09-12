import CodexBarCore
import SwiftUI

struct MidasProviderDetailView: View {
    let presentation: MidasProviderPresentation
    let actions: MidasActions
    var showsOpenUsage = true

    private var accounts: [MidasAccountPresentation] {
        self.actions.accountPresentations(self.presentation.provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            self.identity
            self.spendHeadline
            if self.accounts.count > 1 {
                MidasAccountUsageView(accounts: self.accounts)
            } else {
                self.hero
                ForEach(self.presentation.metrics) { metric in
                    MidasAccountQuotaBar(metric: metric)
                }
                MidasBankedResetsRow(presentation: self.accounts.first?.presentation ?? self.presentation)
            }
            if let error = self.presentation.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Connection needs attention", systemImage: "exclamationmark.triangle")
                        .font(.callout.weight(.medium))
                    DisclosureGroup("Connection details") {
                        Text(error).font(.caption).textSelection(.enabled)
                    }
                    Button("Manage connection") { self.actions.accounts(self.presentation.provider) }
                        .buttonStyle(.bordered)
                }
                .foregroundStyle(MidasTheme.warning)
            }
            if self.presentation.isStale {
                Label("Usage may be outdated", systemImage: "clock.badge.exclamationmark")
                    .font(.caption).foregroundStyle(MidasTheme.warning)
            }
            self.estimateDetails
            if let cloud = self.presentation.cloudUsage {
                DisclosureGroup("Token history") {
                    MidasCloudUsageView(summary: cloud, showsAccounts: true)
                        .padding(.top, 8)
                }
            }
            self.sourceDetails
            if self.showsOpenUsage {
                Button {
                    self.actions.openUsage(self.presentation.provider)
                } label: {
                    HStack {
                        Text("Spend history").fontWeight(.medium)
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

    private var estimateDetails: some View {
        DisclosureGroup("Estimate details") {
            VStack(alignment: .leading, spacing: 8) {
                if let spend = self.presentation.spend {
                    Text(spend.title).fontWeight(.medium)
                    Text(spend.detail)
                    if let value = spend.secondaryValue, let label = spend.secondaryLabel {
                        Text("\(label): \(value)")
                    }
                    Text("Updated \(spend.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                } else if self.presentation.cloudUsage != nil {
                    Text(
                        "An estimate needs reported history and a blended rate. OpenAI does not provide the input, "
                            + "cached, and output token breakdown needed for exact API pricing.")
                    Button("Review estimate setup") { self.actions.settings() }
                } else {
                    Text("No cost data is available for this period.")
                }
                if let value = self.presentation.financialSummary {
                    Text("\(self.presentation.financialLabel ?? "Provider usage"): \(value)")
                }
            }
            .font(.caption).foregroundStyle(MidasTheme.secondaryText)
            .textSelection(.enabled).padding(.top, 8)
        }
    }

    private var sourceDetails: some View {
        DisclosureGroup("Account & source details") {
            VStack(alignment: .leading, spacing: 8) {
                if self.accounts.count <= 1 {
                    if !self.presentation.account.isEmpty { Text(self.presentation.account) }
                    if let plan = self.presentation.plan, !plan.isEmpty { Text(plan) }
                }
                if let activity = self.presentation.activitySummary { Text(activity) }
                if self.accounts.count <= 1, let resets = self.presentation.resetCreditsText {
                    Text("Banked resets: \(resets)")
                    if let help = self.presentation.resetCreditsHelp { Text(help) }
                }
                ForEach(Array(self.presentation.notes.enumerated()), id: \.offset) { _, note in
                    Text(note)
                }
                Text(self.presentation.freshness)
                if let updatedAt = self.presentation.updatedAt {
                    Text(updatedAt.formatted(date: .complete, time: .shortened))
                }
                if self.presentation.isRefreshing {
                    ProgressView().controlSize(.mini).accessibilityLabel("Refreshing usage")
                }
                Button("Refresh") { self.actions.refresh() }
            }
            .font(.caption).foregroundStyle(MidasTheme.secondaryText)
            .textSelection(.enabled).padding(.top, 8)
        }
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: 12) {
            MidasProviderLogo(provider: self.presentation.provider, size: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(self.presentation.name).font(.system(size: 20, weight: .semibold))
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
            Text("Estimated inference spend")
                .font(.callout).foregroundStyle(MidasTheme.secondaryText)
            Text(self.presentation.spend?.value ?? "—")
                .font(.system(size: 46, weight: .semibold))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                .textSelection(.enabled)
            if let spend = self.presentation.spend {
                Text(spend.period).font(.callout).foregroundStyle(MidasTheme.secondaryText)
                    .help("Spend data updated \(spend.updatedAt.formatted(date: .abbreviated, time: .shortened))")
            } else {
                Text("Estimate unavailable")
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
                    Text(MidasAccountQuotaLayout.resetLine(metric, includesWindow: false))
                        .font(.caption).foregroundStyle(MidasTheme.secondaryText)
                    if let help = metric.helpText {
                        DisclosureGroup("Reset time") {
                            Text(help).font(.caption).textSelection(.enabled)
                        }
                        .font(.caption)
                    }
                }
                .accessibilityElement(children: .combine)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(self.presentation.provider == .codex ? "Weekly limit unavailable" : "Limit unavailable")
                        .font(.headline)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MidasTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}
