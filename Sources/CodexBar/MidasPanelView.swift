import CodexBarCore
import SwiftUI

struct MidasPanelView: View {
    let store: UsageStore
    let settings: SettingsStore
    @Bindable var navigation: MidasNavigationState
    let presentation: (UsageProvider) -> MidasProviderPresentation
    let actions: MidasActions
    @State private var showsPeriodPicker = false

    var body: some View {
        VStack(spacing: 0) {
            self.header.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let provider = self.navigation.provider {
                        Button {
                            self.navigation.provider = nil
                        } label: {
                            Label("Overview", systemImage: "chevron.left")
                        }
                        .buttonStyle(.plain).foregroundStyle(MidasTheme.secondaryText)
                        .keyboardShortcut("[", modifiers: .command)
                        MidasProviderDetailView(presentation: self.presentation(provider), actions: self.actions)
                    } else {
                        self.overview
                    }
                }
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 400)
        .frame(maxHeight: .infinity)
        .background(MidasTheme.background)
        .foregroundStyle(MidasTheme.text)
        .tint(MidasTheme.accent)
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                MidasPixelCrown()
                Text("Midas").font(.system(size: 17, weight: .semibold))
            }
            Spacer()
            Button(action: self.actions.refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(MidasQuietButtonStyle()).help("Refresh usage")
                .accessibilityLabel("Refresh usage").keyboardShortcut("r", modifiers: .command)
            Button(action: self.actions.settings) { Image(systemName: "gearshape") }
                .buttonStyle(MidasQuietButtonStyle()).help("Settings")
                .accessibilityLabel("Settings").keyboardShortcut(",", modifiers: .command)
            Menu {
                Menu("Menu-bar provider") {
                    ForEach(self.providers, id: \.self) { provider in
                        Button {
                            self.settings.midasMenuBarFocusProvider = provider
                        } label: {
                            Text(ProviderDefaults.metadata[provider]?.displayName ?? provider.rawValue)
                        }
                    }
                }
                Button("Provider actions & accounts…", action: self.actions.legacyMenu)
                Button("Check for Updates…", action: self.actions.checkForUpdates)
                Divider()
                Button("Quit Midas", action: self.actions.quit).keyboardShortcut("q", modifiers: .command)
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().help("More actions").accessibilityLabel("More actions")
        }
    }

    private var providers: [UsageProvider] {
        self.store.enabledProvidersForDisplay()
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 24) {
            MidasTotalSpendView(
                presentations: self.providers.map(self.presentation),
                periodLabel: MidasSpendPeriod(selection: self.settings.midasSpendPeriodSelection).label,
                periodAction: { self.showsPeriodPicker = true })
                .popover(isPresented: self.$showsPeriodPicker) {
                    MidasSpendPeriodPicker(settings: self.settings, store: self.store)
                }
            if self.providers.isEmpty {
                Button("Connect an account", action: self.actions.settings)
                    .buttonStyle(.borderedProminent).padding(.vertical, 16)
            } else {
                VStack(spacing: 20) {
                    ForEach(self.providers, id: \.self) { provider in
                        Divider()
                        self.providerRow(self.presentation(provider))
                    }
                }
            }
            Button { self.actions.openUsage(nil) } label: {
                HStack {
                    Text("Spend history")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(MidasTheme.secondaryText)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func providerRow(_ item: MidasProviderPresentation) -> some View {
        Button { self.navigation.provider = item.provider } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    MidasProviderLogo(provider: item.provider, size: 22)
                        .fixedSize().accessibilityHidden(true)
                    Text(item.name).font(.system(size: 15, weight: .semibold))
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    if item.isRefreshing { ProgressView().controlSize(.mini) }
                    Text(item.spend.flatMap { $0.isEstimate ? MidasOverviewMoney.format(
                        $0.amount,
                        currency: $0.currency) : nil } ?? "—")
                        .font(.system(size: 21, weight: .medium)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .accessibilityLabel("Estimated inference spend")
                        .accessibilityValue(item.spend.flatMap { $0.isEstimate ? $0.value : nil } ?? "Unavailable")
                }
                MidasOverviewMetrics(item: item, accounts: self.actions.accountPresentations(item.provider))
                if item.spend?.isEstimate != true {
                    Text(item.spendUnavailableReason ?? "Estimate unavailable")
                        .font(.caption).foregroundStyle(MidasTheme.secondaryText)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Show provider details")
    }
}

/// Capacity belongs to each account; money is shown once in the provider heading.
struct MidasOverviewMetrics: View {
    let item: MidasProviderPresentation
    var accounts: [MidasAccountPresentation] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if self.accounts.count > 1 {
                MidasAccountOverviewBars(accounts: self.accounts)
            } else if self.item.hero != nil || !self.item.metrics.isEmpty {
                ForEach(MidasAccountQuotaLayout.overviewMetrics(self.item)) { selected in
                    MidasAccountQuotaBar(metric: selected)
                }
                if self.item.isStale || self.item.error != nil {
                    Text("Stale").font(.caption).foregroundStyle(MidasTheme.warning)
                }
            } else {
                Text(self.item.error != nil ? "Needs attention" : "Limit unavailable")
                    .font(.caption)
                    .foregroundStyle(self.item.error != nil ? MidasTheme.warning : MidasTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Keep estimates scannable without rounding a nonzero amount down to zero.
enum MidasOverviewMoney {
    static func format(_ amount: Double, currency: String) -> String {
        if amount > 0, amount < 0.01 {
            return "<" + 0.01.formatted(.currency(code: currency))
        }
        return amount.formatted(.currency(code: currency).precision(.fractionLength(amount < 1 ? 2 : 0)))
    }
}
