import CodexBarCore
import SwiftUI

struct MidasAccountUsageView: View {
    let accounts: [MidasAccountPresentation]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connected accounts").font(.headline)
            Text("Limits belong to each account and are not added together.")
                .font(.caption).foregroundStyle(MidasTheme.secondaryText)
            ForEach(self.accounts) { account in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text(account.presentation.account).textSelection(.enabled)
                        Spacer(minLength: 4)
                        if account.isPrimary {
                            Text("Primary").foregroundStyle(MidasTheme.accent)
                        }
                    }
                    .font(.callout.weight(.medium))
                    if let plan = account.presentation.plan { Text(plan).font(.caption) }
                    if let metric = account.presentation.hero {
                        MidasAccountQuotaBar(metric: metric)
                    } else {
                        Text("Usage unavailable").foregroundStyle(MidasTheme.secondaryText)
                    }
                    ForEach(account.presentation.metrics) { metric in
                        MidasAccountQuotaBar(metric: metric)
                    }
                    Text(account.presentation.freshness)
                        .foregroundStyle(account.presentation.isStale ? MidasTheme.warning : MidasTheme.secondaryText)
                    if let error = account.presentation.error {
                        Text(error).foregroundStyle(MidasTheme.warning)
                    }
                }
                .font(.caption)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MidasTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

extension StatusItemController {
    func midasAccountPresentations(for provider: UsageProvider) -> [MidasAccountPresentation] {
        guard provider == .codex else { return self.midasTokenAccountPresentations(for: provider) }
        let projection = self.settings.codexVisibleAccountProjection
        let snapshots = Dictionary(
            self.store.codexAccountSnapshots.map { ($0.id, $0) },
            uniquingKeysWith: { _, new in new })
        return projection.visibleAccounts.sorted { $0.isActive && !$1.isActive }.map { account in
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
            return MidasAccountPresentation(id: account.id, isPrimary: account.isActive, presentation: presentation)
        }
    }
}

struct MidasAccountQuotaBar: View {
    let metric: MidasQuotaMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(self.metric.title).foregroundStyle(MidasTheme.secondaryText)
                Spacer(minLength: 8)
                Text(self.metric.valueText).monospacedDigit()
            }
            .font(.callout)
            MidasRemainingBar(percent: self.metric.remainingPercent)
            if let reset = self.metric.resetText {
                Text(reset).font(.caption2).foregroundStyle(MidasTheme.secondaryText)
            }
        }
    }
}

struct MidasAccountOverviewBars: View {
    let accounts: [MidasAccountPresentation]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(self.accounts) { account in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(account.presentation.account)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        if account.isPrimary {
                            Text("Primary").foregroundStyle(MidasTheme.accent)
                        }
                    }
                    .font(.caption.weight(.medium))
                    if let metric = account.presentation.hero ?? account.presentation.metrics.first {
                        MidasAccountQuotaBar(metric: metric)
                    } else {
                        Text("Usage unavailable").font(.caption).foregroundStyle(MidasTheme.secondaryText)
                    }
                    if account.presentation.isStale || account.presentation.error != nil {
                        Text("Last known usage · Needs attention")
                            .font(.caption2).foregroundStyle(MidasTheme.warning)
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
                presentation: presentation)
        }
    }
}
