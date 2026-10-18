import CodexBarCore
import SwiftUI

/// Native sidebar navigation with a resizable workspace for usage and cost history.
struct MidasUsageWindowView: View {
    private enum Destination: Hashable {
        case overview
        case provider(UsageProvider)
    }

    let store: UsageStore
    let settings: SettingsStore
    @Bindable var navigation: MidasNavigationState
    let presentation: (UsageProvider) -> MidasProviderPresentation
    let actions: MidasActions
    @State private var showsCosts = false
    @State private var period: MidasCostPresentation.Period = .month
    @State private var monthlyShowsCosts = true
    @State private var monthCount = 6
    @State private var comparisonProvider: UsageProvider = .codex

    private var providers: [UsageProvider] {
        self.store.midasProvidersForUsageDisplay()
    }

    private var selection: Binding<Destination?> {
        Binding(
            get: {
                if let provider = self.navigation.provider, self.providers.contains(provider) {
                    return .provider(provider)
                }
                return .overview
            },
            set: { destination in
                guard let destination else { return }
                switch destination {
                case .overview: self.navigation.provider = nil
                case let .provider(provider): self.navigation.provider = provider
                }
            })
    }

    private var navigationTitle: String {
        guard let provider = self.navigation.provider, self.providers.contains(provider) else { return "Overview" }
        return self.presentation(provider).name
    }

    var body: some View {
        NavigationSplitView {
            self.sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let provider = self.navigation.provider, self.providers.contains(provider) {
                        self.providerContent(provider)
                    } else {
                        self.overview
                    }
                }
                .padding(24)
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(MidasTheme.background)
            .navigationTitle(self.navigationTitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: self.actions.refresh) {
                        Label("Refresh usage", systemImage: "arrow.clockwise")
                    }
                    .help("Refresh usage")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .foregroundStyle(MidasTheme.text)
        .tint(MidasTheme.accent)
        .frame(minWidth: 760, minHeight: 520)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "crown.fill")
                    .foregroundStyle(MidasTheme.accent)
                    .accessibilityHidden(true)
                Text("Midas").font(.headline)
            }
            .padding(16)
            List(selection: self.selection) {
                Label("Overview", systemImage: "square.grid.2x2")
                    .tag(Destination.overview)
                Section("Providers") {
                    ForEach(self.providers, id: \.self) { provider in
                        Label {
                            Text(self.presentation(provider).name)
                                .lineLimit(1)
                        } icon: {
                            MidasProviderLogo(provider: provider, size: 18)
                                .fixedSize().accessibilityHidden(true)
                        }
                        .tag(Destination.provider(provider))
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    Button(action: self.actions.settings) {
                        Label("Settings…", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderless)
                    Spacer(minLength: 0)
                }
                .padding(16)
            }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            MidasTotalSpendView(
                presentations: self.store.midasProvidersForTotalDisplay().map(self.presentation),
                tokenTotal: self.store.midasRecordedTokenTotal(providers: self.store.midasProvidersForTotalDisplay()),
                periodLabel: MidasSpendPeriod(selection: self.settings.midasSpendPeriodSelection)
                    .label(reportingTimeZone: self.store.midasDisplayTimeZone),
                periodControl: AnyView(MidasSpendPeriodControl(settings: self.settings, store: self.store)))
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MidasTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            if self.providers.isEmpty {
                ContentUnavailableView {
                    Label("Make yourself at home", systemImage: "sparkles")
                } description: {
                    Text("Add a provider in Settings to start seeing your available capacity.")
                } actions: {
                    Button("Set up providers", action: self.actions.settings)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], alignment: .leading, spacing: 16) {
                    ForEach(self.providers, id: \.self) { provider in
                        self.overviewCard(self.presentation(provider))
                    }
                }
                if let provider = self.providers.first(where: { $0 == self.comparisonProvider })
                    ?? self.providers.first
                {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("Compare provider", selection: Binding(
                            get: { provider },
                            set: { self.comparisonProvider = $0 }))
                        {
                            ForEach(self.providers, id: \.self) { provider in
                                Text(self.presentation(provider).name).tag(provider)
                            }
                        }
                        .fixedSize()
                        self.monthlyComparison(provider)
                    }
                    .padding(20)
                    .background(MidasTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            DisclosureGroup("Usage scope & sync") {
                MidasSyncStatusView(coordinator: self.store.midasUsageSync)
                    .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private func overviewCard(_ item: MidasProviderPresentation) -> some View {
        if let spark = item.dgxSpark {
            Button { self.navigation.provider = item.provider } label: {
                MidasDGXSparkCard(model: spark, isRefreshing: item.isRefreshing, showsNavigation: true)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Show DGX Spark token breakdown and API pricing basis")
        } else {
            self.cloudOverviewCard(item)
        }
    }

    private func cloudOverviewCard(_ item: MidasProviderPresentation) -> some View {
        Button {
            self.navigation.provider = item.provider
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    MidasProviderLogo(provider: item.provider, size: 24)
                        .fixedSize().accessibilityHidden(true)
                    Text(item.name).font(.headline)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(MidasTheme.secondaryText)
                }
                Text(item.spend.flatMap {
                    $0.isDisplayable ? MidasOverviewMoney.format($0.amount, currency: $0.currency) : nil
                } ?? "—")
                    .font(.system(size: 28, weight: .medium)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.65)
                    .accessibilityLabel(item.spend?.accessibilityTitle ?? "Estimated inference spend")
                    .accessibilityValue(item.spend?.value ?? "Unavailable")
                MidasOverviewMetrics(item: item, accounts: self.actions.accountPresentations(item.provider))
                if item.spend?.isBilled == true {
                    Text("Billed · not in estimate total")
                        .font(.caption).foregroundStyle(MidasTheme.secondaryText)
                } else if item.spend?.isEstimate != true {
                    Text(item.spendUnavailableReason ?? "Estimate unavailable")
                        .font(.caption).foregroundStyle(MidasTheme.secondaryText)
                } else if item.spend?.coverageNote != nil {
                    Label("Partial estimate", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(MidasTheme.warning)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(MidasTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Show provider usage and costs")
    }

    private func providerContent(_ provider: UsageProvider) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(provider == .localInference ? "DGX Spark" : "Spend & usage")
                    .font(.title2.weight(.semibold))
                Spacer()
                Picker("View", selection: self.$showsCosts) {
                    Text("Usage").tag(false)
                    Text("Costs").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
            }
            if provider == .localInference || !self.showsCosts {
                MidasProviderDetailView(
                    presentation: self.presentation(provider), actions: self.actions, showsOpenUsage: false)
                Divider()
            }
            self.monthlyComparison(provider)
            Divider()
            HStack {
                Text(self.showsCosts
                    ? self.dailyHistory(provider).costLabel
                    : "Activity history")
                    .font(.title3.weight(.semibold))
                Spacer()
                Picker("History period", selection: self.$period) {
                    ForEach(MidasCostPresentation.Period.allCases) { period in
                        Text(period.rawValue).tag(period)
                    }
                }
                .fixedSize()
            }
            MidasUsageHistoryView(
                model: self.dailyHistory(provider),
                showsCosts: self.showsCosts,
                isRefreshing: self.store.isTokenRefreshInFlight(for: provider))
            if self.costSnapshot(provider) == nil {
                let explanation = self.store.usesSyncedUsage(for: provider)
                    ? "Shared history appears after a connected Mac supplies supported usage records."
                    : (self.settings.costUsageEnabled
                        ? "History appears when this provider supplies supported usage records."
                        : "Local cost history is off. You can enable it in Settings.")
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(MidasTheme.secondaryText)
                Button("Open Settings", action: self.actions.settings)
            }
        }
    }

    private func costSnapshot(_ provider: UsageProvider) -> CostUsageTokenSnapshot? {
        self.store.displayTokenSnapshot(for: provider)
    }

    private func dailyHistory(_ provider: UsageProvider) -> MidasCostPresentation {
        let snapshot = self.costSnapshot(provider)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = self.store.spendReportingTimeZone(for: provider, snapshot: snapshot)
        return MidasCostPresentation(snapshot: snapshot, period: self.period, reportingCalendar: calendar)
    }

    private func monthlyComparison(_ provider: UsageProvider) -> some View {
        let snapshot = self.costSnapshot(provider)
        let timeZone = self.store.spendReportingTimeZone(for: provider, snapshot: snapshot)
        let utcDays = timeZone == MidasSpendPeriod.utc
        return VStack(alignment: .leading, spacing: 16) {
            MidasMonthlySpendView(
                model: MidasMonthlySpend(
                    snapshot: snapshot,
                    monthCount: self.monthCount,
                    reportingTimeZone: timeZone),
                showsCosts: self.$monthlyShowsCosts,
                monthCount: self.$monthCount)
                .id(provider)
            if self.store.usesSyncedUsage(for: provider) {
                Text("Shared history uses UTC days and retains up to 12 months. Only recorded usage is included.")
                    .font(.caption).foregroundStyle(MidasTheme.secondaryText)
            } else if provider == .codex, self.settings.midasCloudUsageEnabled {
                Text("Codex cloud currently supplies 30 days. Older months remain unavailable.")
                    .font(.caption).foregroundStyle(MidasTheme.secondaryText)
            } else if provider == .mistral {
                Text("Mistral currently supplies the current UTC month. Older months remain unavailable.")
                    .font(.caption).foregroundStyle(MidasTheme.secondaryText)
            } else if self.settings.costUsageHistoryDays < 365,
                      self.settings.costUsageEnabled || UsageStore.tokenCostRequiresProviderSnapshot(provider)
            {
                HStack {
                    Text("History is set to \(self.settings.costUsageHistoryDays) days. "
                        + "Load a longer window to compare more months where the source supports it.")
                        .font(.caption).foregroundStyle(MidasTheme.secondaryText)
                    Spacer(minLength: 8)
                    Button("Load up to 12 months") {
                        self.settings.costUsageHistoryDays = 365
                        self.actions.refresh()
                    }
                    .disabled(self.store.isRefreshing)
                }
            }
            if !self.settings.costUsageEnabled, !UsageStore.tokenCostRequiresProviderSnapshot(provider),
               !self.store.usesSyncedUsage(for: provider)
            {
                HStack {
                    Text("Local cost history is off. Enable it in Settings to load available local records.")
                        .font(.caption).foregroundStyle(MidasTheme.secondaryText)
                    Spacer(minLength: 8)
                    Button("Open Settings", action: self.actions.settings)
                }
            }
            Text(utcDays ? "Source dates use UTC." : "Source dates use this Mac’s time zone.")
                .font(.caption).foregroundStyle(MidasTheme.secondaryText)
            if let updated = snapshot?.updatedAt {
                Text("Source updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(MidasTheme.secondaryText)
            }
            if self.store.isTokenRefreshInFlight(for: provider) {
                Label("Refreshing · showing saved records", systemImage: "arrow.clockwise")
                    .font(.caption).foregroundStyle(MidasTheme.secondaryText)
            }
        }
    }
}
