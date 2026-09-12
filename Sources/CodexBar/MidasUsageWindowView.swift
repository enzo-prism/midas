import CodexBarCore
import SwiftUI

/// The deliberately spacious companion to the compact menu-bar panel.
struct MidasUsageWindowView: View {
    let store: UsageStore
    let settings: SettingsStore
    @Bindable var navigation: MidasNavigationState
    let presentation: (UsageProvider) -> MidasProviderPresentation
    let actions: MidasActions
    @State private var showsCosts = false
    @State private var period: MidasCostPresentation.Period = .month

    private var providers: [UsageProvider] {
        self.store.enabledProvidersForDisplay()
    }

    var body: some View {
        HStack(spacing: 0) {
            self.sidebar
                .frame(width: 196)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let provider = self.navigation.provider, self.providers.contains(provider) {
                        self.providerContent(provider)
                    } else {
                        self.overview
                    }
                }
                .padding(32)
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(MidasTheme.background)
        }
        .foregroundStyle(MidasTheme.text)
        .tint(MidasTheme.accent)
        .frame(minWidth: 760, minHeight: 520)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 8) {
                MidasPixelCrown(animated: false)
                Text("Midas").font(.system(size: 23, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    self.navigationButton("Overview", selected: self.navigation.provider == nil) {
                        self.navigation.provider = nil
                    } icon: {
                        Image(systemName: "square.grid.2x2").frame(width: 24, height: 24)
                    }
                    Text("PROVIDERS")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MidasTheme.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.top, 20)
                        .padding(.bottom, 4)
                    ForEach(self.providers, id: \.self) { provider in
                        self.navigationButton(
                            self.presentation(provider).name,
                            selected: self.navigation.provider == provider)
                        {
                            self.navigation.provider = provider
                        } icon: {
                            MidasProviderLogo(provider: provider, size: 24).fixedSize()
                        }
                    }
                }
            }
            Button(action: self.actions.settings) {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(MidasTheme.surface)
    }

    private func navigationButton(
        _ title: String,
        selected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> some View) -> some View
    {
        Button(action: action) {
            HStack(spacing: 10) {
                icon()
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                selected ? MidasTheme.accent.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Overview")
                        .font(.system(size: 29, weight: .semibold))
                }
                Spacer()
                Button(action: self.actions.refresh) { Image(systemName: "arrow.clockwise") }
                    .help("Refresh usage")
                    .accessibilityLabel("Refresh usage")
            }
            MidasTotalSpendView(
                presentations: self.providers.map(self.presentation),
                periodLabel: MidasSpendPeriod(selection: self.settings.midasSpendPeriodSelection).label,
                periodControl: AnyView(MidasSpendPeriodControl(settings: self.settings, store: self.store)))
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MidasTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            if self.providers.isEmpty {
                ContentUnavailableView {
                    Label("Make yourself at home", systemImage: "sparkles")
                } description: {
                    Text("Add a provider in Settings to start seeing your available capacity.")
                } actions: {
                    Button("Set up providers", action: self.actions.settings)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 20)], alignment: .leading, spacing: 20) {
                    ForEach(self.providers, id: \.self) { provider in
                        self.overviewCard(self.presentation(provider))
                    }
                }
            }
        }
    }

    private func overviewCard(_ item: MidasProviderPresentation) -> some View {
        Button {
            self.navigation.provider = item.provider
        } label: {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    MidasProviderLogo(provider: item.provider, size: 32)
                        .fixedSize().accessibilityHidden(true)
                    Text(item.name).font(.system(size: 17, weight: .semibold))
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(MidasTheme.secondaryText)
                }
                Text(item.spend.flatMap {
                    $0.isEstimate ? MidasOverviewMoney.format($0.amount, currency: $0.currency) : nil
                } ?? "—")
                    .font(.system(size: 28, weight: .medium)).monospacedDigit()
                    .accessibilityLabel("Estimated inference spend")
                    .accessibilityValue(item.spend?.value ?? "Unavailable")
                MidasOverviewMetrics(item: item, accounts: self.actions.accountPresentations(item.provider))
                if item.spend?.isEstimate != true {
                    Text(item.spendUnavailableReason ?? "Estimate unavailable")
                        .font(.caption).foregroundStyle(MidasTheme.secondaryText)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(MidasTheme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Show provider usage and costs")
    }

    private func providerContent(_ provider: UsageProvider) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                Text(self.showsCosts ? self.presentation(provider).name : "Spend & usage")
                    .font(.system(size: 28, weight: .semibold))
                Spacer()
                Picker("View", selection: self.$showsCosts) {
                    Text("Usage").tag(false)
                    Text("Costs").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
            }
            if !self.showsCosts {
                MidasProviderDetailView(
                    presentation: self.presentation(provider), actions: self.actions, showsOpenUsage: false)
                Divider()
            }
            HStack {
                Text(self.showsCosts
                    ? MidasCostPresentation(snapshot: self.costSnapshot(provider), period: self.period).costLabel
                    : "Activity history")
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                Picker("History period", selection: self.$period) {
                    ForEach(MidasCostPresentation.Period.allCases) { period in
                        Text(period.rawValue).tag(period)
                    }
                }
                .fixedSize()
            }
            MidasUsageHistoryView(
                model: MidasCostPresentation(snapshot: self.costSnapshot(provider), period: self.period),
                showsCosts: self.showsCosts,
                isRefreshing: self.store.isTokenRefreshInFlight(for: provider))
            if self.costSnapshot(provider) == nil {
                Text(self.settings.costUsageEnabled
                    ? "History appears when this provider supplies supported usage records."
                    : "Local cost history is off. You can enable it in Settings.")
                    .font(.callout)
                    .foregroundStyle(MidasTheme.secondaryText)
                Button("Open Settings", action: self.actions.settings)
            }
        }
    }

    private func costSnapshot(_ provider: UsageProvider) -> CostUsageTokenSnapshot? {
        let derived = self.store.tokenSnapshot(
            fromProviderSnapshot: self.store.snapshot(for: provider),
            provider: provider)
        if UsageStore.tokenCostRequiresProviderSnapshot(provider) { return derived }
        return derived ?? self.store.tokenSnapshot(for: provider)
    }
}
