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
                    Text(account.presentation.hero.map { "Weekly: \($0.valueText)" } ?? "Weekly usage unavailable")
                    if let reset = account.presentation.hero?.resetText {
                        Text(reset).foregroundStyle(MidasTheme.secondaryText)
                    }
                    ForEach(account.presentation.metrics) { metric in
                        Text("\(metric.title): \(metric.valueText)")
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
        guard provider == .codex, self.settings.midasTrackAllAccounts else { return [] }
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
