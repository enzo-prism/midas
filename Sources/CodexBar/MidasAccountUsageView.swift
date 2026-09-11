import CodexBarCore
import SwiftUI

struct MidasAccountUsageView: View {
    let accounts: [MidasAccountPresentation]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(self.accounts) { account in
                VStack(alignment: .leading, spacing: 12) {
                    Text(account.displayName ?? account.presentation.account)
                        .font(.callout.weight(.semibold))
                        .textSelection(.enabled)
                        .help(account.presentation.account)
                    let metrics = MidasAccountQuotaLayout.allMetrics(account.presentation)
                    if metrics.isEmpty {
                        Text("Usage unavailable").foregroundStyle(MidasTheme.secondaryText)
                    }
                    ForEach(metrics) { metric in
                        MidasAccountQuotaBar(metric: metric)
                    }
                    if account.presentation.error != nil || account.presentation.isStale {
                        Text(metrics.isEmpty ? "Needs attention" : "Last known usage")
                            .font(.caption).foregroundStyle(MidasTheme.warning)
                            .help(account.presentation.error ?? account.presentation.freshness)
                    }
                    self.details(for: account, metrics: metrics)
                }
            }
        }
    }

    private func details(for account: MidasAccountPresentation, metrics: [MidasQuotaMetric]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if !account.presentation.account.isEmpty {
                    Text(account.presentation.account)
                }
                if let plan = account.presentation.plan, !plan.isEmpty {
                    Text(plan)
                }
                ForEach(metrics) { metric in
                    if let reset = metric.resetsAt {
                        Text("\(metric.title) reset: \(reset.formatted(date: .complete, time: .shortened))")
                    } else if let help = metric.helpText, !help.isEmpty {
                        Text("\(metric.title): \(help)")
                    }
                }
                if !account.presentation.freshness.isEmpty {
                    Text(account.presentation.freshness)
                }
                if let updated = account.presentation.updatedAt {
                    Text("Updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                }
                if let error = account.presentation.error, !error.isEmpty {
                    Text(error).foregroundStyle(MidasTheme.warning)
                }
            }
            .font(.caption).foregroundStyle(MidasTheme.secondaryText)
            .textSelection(.enabled).padding(.top, 6)
        } label: {
            Text("Account details")
                .accessibilityLabel("Account details for \(account.displayName ?? account.presentation.account)")
        }
        .font(.caption).foregroundStyle(MidasTheme.secondaryText)
    }
}

/// Keep independent limits visible when the headline balance would hide a tighter constraint.
enum MidasAccountQuotaLayout {
    static func allMetrics(_ presentation: MidasProviderPresentation) -> [MidasQuotaMetric] {
        var seen = Set<String>()
        return ([presentation.hero].compactMap(\.self) + presentation.metrics)
            .filter { $0.remainingPercent.isFinite && seen.insert($0.id).inserted }
    }

    static func overviewMetrics(_ presentation: MidasProviderPresentation) -> [MidasQuotaMetric] {
        let metrics = self.allMetrics(presentation)
        guard let first = metrics.first else { return [] }
        return [first] + metrics.dropFirst().filter {
            $0.isExhausted || ($0.remainingPercent < first.remainingPercent
                && ($0.remainingPercent <= 10 || first.remainingPercent - $0.remainingPercent >= 20))
        }
    }

    static func resetLine(_ metric: MidasQuotaMetric, includesWindow: Bool, now: Date = Date()) -> String {
        let window = metric.title == "This week" ? "Weekly" : metric.title
        let reset = metric.resetText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = if let date = metric.resetsAt, date <= now {
            "Reset pending update"
        } else {
            reset.flatMap { $0.isEmpty ? nil : $0 } ?? "Reset unavailable"
        }
        return includesWindow ? "\(window) · \(detail)" : detail
    }
}

enum MidasAccountNames {
    static func resolve(
        identities: [(id: String, identity: String)],
        provider: UsageProvider,
        aliases: [String: String],
        hidePersonalInfo: Bool = false) -> [String: String]
    {
        if hidePersonalInfo {
            return Dictionary(identities.enumerated().map { index, account in
                (account.id, "Account \(index + 1)")
            }, uniquingKeysWith: { _, new in new })
        }
        let candidates = identities.enumerated().map { index, account in
            let alias = aliases[provider.rawValue + ":" + account.id]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let identity = account.identity.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = identity.isEmpty ? "Account \(index + 1)" : identity
            let candidate = alias.flatMap { $0.isEmpty ? nil : $0 }
                ?? (identity.contains("@") ? String(identity.split(separator: "@", omittingEmptySubsequences: false)[0])
                    : fallback)
            return (id: account.id, candidate: candidate.isEmpty ? fallback : candidate, fallback: fallback)
        }
        let counts = Dictionary(grouping: candidates, by: { $0.candidate.lowercased() }).mapValues(\.count)
        return Dictionary(candidates.map { account in
            (
                account.id,
                counts[account.candidate.lowercased(), default: 0] > 1
                    ? account.fallback : account.candidate)
        }, uniquingKeysWith: { _, new in new })
    }
}

extension StatusItemController {
    func midasAccountPresentations(for provider: UsageProvider) -> [MidasAccountPresentation] {
        guard provider == .codex else { return self.midasTokenAccountPresentations(for: provider) }
        let projection = self.settings.codexVisibleAccountProjection
        let snapshots = Dictionary(
            self.store.codexAccountSnapshots.map { ($0.id, $0) },
            uniquingKeysWith: { _, new in new })
        let visible = projection.visibleAccounts.sorted { $0.isActive && !$1.isActive }
        let names = MidasAccountNames.resolve(
            identities: visible.map { ($0.id, self.accountInfo(for: $0).email ?? "") },
            provider: provider,
            aliases: self.settings.midasAccountAliases,
            hidePersonalInfo: self.settings.hidePersonalInfo)
        return visible.map { account in
            let entry = snapshots[account.id]
            let snapshot = entry?.snapshot
            let card = self.menuCardModel(
                for: provider,
                snapshotOverride: snapshot,
                errorOverride: entry?.error,
                forceOverrideCard: true,
                accountOverride: self.accountInfo(for: account))
            let presentation = MidasProviderPresentation.make(
                provider: provider,
                card: card,
                snapshot: snapshot,
                tokenSnapshot: nil,
                isRefreshing: self.store.refreshingProviders.contains(provider),
                isStale: entry?.error != nil || snapshot == nil)
            return MidasAccountPresentation(
                id: account.id,
                isPrimary: account.isActive,
                presentation: presentation,
                displayName: names[account.id])
        }
    }
}

struct MidasAccountQuotaBar: View {
    let metric: MidasQuotaMetric
    var label: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(self.label ?? self.metric.title)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(self.metric.valueText).monospacedDigit()
            }
            .font(.callout)
            MidasRemainingBar(percent: self.metric.remainingPercent)
            Text(MidasAccountQuotaLayout.resetLine(self.metric, includesWindow: self.label != nil))
                .font(.caption).foregroundStyle(MidasTheme.secondaryText)
                .help(self.metric.helpText ?? "")
        }
    }
}

struct MidasAccountOverviewBars: View {
    let accounts: [MidasAccountPresentation]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(self.accounts) { account in
                VStack(alignment: .leading, spacing: 10) {
                    let metrics = MidasAccountQuotaLayout.overviewMetrics(account.presentation)
                    let name = account.displayName ?? account.presentation.account
                    if let first = metrics.first {
                        MidasAccountQuotaBar(metric: first, label: name)
                            .help(account.presentation.account)
                        ForEach(metrics.dropFirst()) { metric in
                            MidasAccountQuotaBar(metric: metric)
                        }
                    } else {
                        HStack {
                            Text(name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text("Usage unavailable").foregroundStyle(MidasTheme.secondaryText)
                        }
                        .font(.callout)
                    }
                    if account.presentation.isStale || account.presentation.error != nil {
                        Text(metrics.isEmpty ? "Needs attention" : "Last known usage")
                            .font(.caption).foregroundStyle(MidasTheme.warning)
                            .help(account.presentation.error ?? account.presentation.freshness)
                    }
                }
            }
        }
    }
}

extension StatusItemController {
    private func midasTokenAccountPresentations(for provider: UsageProvider) -> [MidasAccountPresentation] {
        let accounts = self.settings.tokenAccounts(for: provider)
        guard accounts.count > 1 else { return [] }
        let names = MidasAccountNames.resolve(
            identities: accounts.map { ($0.id.uuidString, $0.label) },
            provider: provider,
            aliases: self.settings.midasAccountAliases,
            hidePersonalInfo: self.settings.hidePersonalInfo)
        let snapshots = Dictionary(
            (self.store.accountSnapshots[provider] ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { _, new in new })
        return accounts.map { account in
            let entry = snapshots[account.id]
            let snapshot = entry?.snapshot
            let card = self.menuCardModel(
                for: provider,
                snapshotOverride: snapshot,
                errorOverride: entry?.error,
                forceOverrideCard: true,
                accountOverride: AccountInfo(email: account.label, plan: nil))
            let presentation = MidasProviderPresentation.make(
                provider: provider,
                card: card,
                snapshot: snapshot,
                tokenSnapshot: nil,
                isRefreshing: self.store.refreshingProviders.contains(provider),
                isStale: entry?.error != nil || snapshot == nil)
            return MidasAccountPresentation(
                id: account.id.uuidString,
                isPrimary: self.settings.selectedTokenAccount(for: provider)?.id == account.id,
                presentation: presentation,
                displayName: names[account.id.uuidString])
        }
    }
}
