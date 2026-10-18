import CodexBarCore
import SwiftUI

struct MidasPanelView: View {
    private enum InfoPage {
        case sync, coverage
    }

    let store: UsageStore
    let settings: SettingsStore
    @Bindable var navigation: MidasNavigationState
    let presentation: (UsageProvider) -> MidasProviderPresentation
    let actions: MidasActions
    /// Also permits deterministic previews of the Reduce Transparency fallback.
    var opaqueNavigation = false
    @State private var infoPage: InfoPage?

    var body: some View {
        VStack(spacing: 0) {
            self.header
                .padding(.horizontal, 14).padding(.vertical, 8)
            if let page = self.infoPage {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(page == .sync ? "Usage scope & sync" : "Estimate coverage").font(.headline)
                        if page == .sync {
                            MidasSyncStatusView(coordinator: self.store.midasUsageSync)
                        } else {
                            MidasSpendCoverageView(presentations: self.store.midasProvidersForTotalDisplay()
                                .map(self.presentation))
                        }
                    }
                    .padding(16)
                }
            } else if let provider = self.navigation.provider {
                Divider()
                ScrollView {
                    MidasProviderDetailView(
                        presentation: self.presentation(provider), actions: self.actions, showsOpenUsage: false)
                        .padding(16)
                }
                .id(provider)
            } else {
                MidasTotalSpendView(
                    presentations: self.store.midasProvidersForTotalDisplay().map(self.presentation),
                    tokenTotal: self.store
                        .midasRecordedTokenTotal(providers: self.store.midasProvidersForTotalDisplay()),
                    periodLabel: MidasSpendPeriod(selection: self.settings.midasSpendPeriodSelection)
                        .label(reportingTimeZone: self.store.midasDisplayTimeZone),
                    periodControl: AnyView(MidasSpendPeriodControl(settings: self.settings, store: self.store)),
                    compact: true)
                    .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)
                Divider()
                ScrollView {
                    self.providerList
                        .padding(.horizontal, 16)
                }
                .scrollIndicators(.automatic)
            }
            Divider()
            self.footer
                .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .frame(width: MidasPanelLayout.width)
        .frame(maxHeight: .infinity)
        .background(MidasTheme.background)
        .foregroundStyle(MidasTheme.text)
        .font(.system(size: 13))
    }

    private var header: some View {
        HStack(spacing: 8) {
            if self.navigation.provider != nil || self.infoPage != nil {
                Button {
                    if self.infoPage != nil {
                        self.infoPage = nil
                    } else {
                        self.navigation.provider = nil
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help("Back to overview").accessibilityLabel("Back to overview")
                .keyboardShortcut("[", modifiers: .command)
            } else {
                Image(systemName: "crown.fill")
                    .foregroundStyle(MidasTheme.accent)
                    .accessibilityHidden(true)
            }
            Text("Midas").font(.headline)
            Spacer(minLength: 8)
            MidasNavigationGlass(forceOpaque: self.opaqueNavigation) {
                HStack(spacing: 0) {
                    Button(action: self.actions.refresh) {
                        Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
                    }
                    .help("Refresh usage").accessibilityLabel("Refresh usage")
                    .keyboardShortcut("r", modifiers: .command)
                    Button(action: self.actions.settings) {
                        Image(systemName: "gearshape").frame(width: 28, height: 28)
                    }
                    .help("Settings").accessibilityLabel("Settings")
                    .keyboardShortcut(",", modifiers: .command)
                    self.moreActions
                }
                .buttonStyle(.borderless)
                .padding(2)
            }
            .fixedSize()
        }
    }

    private var moreActions: some View {
        Menu {
            Button("Estimate details…") { self.infoPage = .coverage }
            Divider()
            Menu("Menu-bar provider") {
                Picker("Menu-bar provider", selection: Binding(
                    get: { self.settings.midasMenuBarFocusProvider },
                    set: { self.settings.midasMenuBarFocusProvider = $0 }))
                {
                    ForEach(self.providers, id: \.self) { provider in
                        Text(ProviderDefaults.metadata[provider]?.displayName ?? provider.rawValue).tag(provider)
                    }
                }
                .pickerStyle(.inline)
            }
            Button("Provider actions & accounts…", action: self.actions.legacyMenu)
            Button("Check for Updates…", action: self.actions.checkForUpdates)
            Divider()
            Button("Quit Midas", action: self.actions.quit).keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "ellipsis").frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .fixedSize().help("More actions").accessibilityLabel("More actions")
    }

    private var providers: [UsageProvider] {
        self.store.midasProvidersForUsageDisplay()
    }

    private var providerList: some View {
        VStack(spacing: 0) {
            if self.providers.isEmpty {
                VStack(spacing: 10) {
                    Text("Your usage, at a glance").font(.headline)
                    Button("Connect an account", action: self.actions.settings)
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 18)
            } else {
                ForEach(self.providers, id: \.self) { provider in
                    if provider != self.providers.first { Divider() }
                    self.providerRow(self.presentation(provider))
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { self.infoPage = .sync } label: {
                Label(self.syncPresentation.title, systemImage: self.syncPresentation.symbol)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(self.store.midasUsageSync.issue == nil
                        ? MidasTheme.secondaryText : MidasTheme.warning)
                    .frame(minHeight: 24)
            }
            .buttonStyle(.borderless)
            .help("Usage scope and sync status")
            .accessibilityLabel("Usage scope: \(self.syncPresentation.title). Show sync status")
            Spacer(minLength: 4)
            Button { self.actions.openUsage(self.navigation.provider) } label: {
                Label("Spend history", systemImage: "chart.bar.xaxis")
                    .font(.system(size: 11, weight: .medium))
                    .frame(minHeight: 24)
            }
            .buttonStyle(.borderless)
            .help("Open usage and spend history")
        }
        .controlSize(.small)
        .frame(minHeight: 22)
    }

    private var syncPresentation: MidasSyncPresentation {
        let sync = self.store.midasUsageSync
        return MidasSyncPresentation(
            isEnabled: sync.isEnabled,
            includesSyncedUsage: sync.includesSyncedUsage,
            hasConnection: sync.hasConnection,
            otherDeviceCount: sync.devices.count(where: { !$0.isThisMac }),
            transport: sync.transport)
    }

    private func providerValue(_ item: MidasProviderPresentation) -> String {
        if let spark = item.dgxSpark {
            return spark.amount.map { MidasOverviewMoney.format($0, currency: "USD") } ?? "—"
        }
        return item.spend.flatMap {
            $0.isDisplayable ? MidasOverviewMoney.format($0.amount, currency: $0.currency) : nil
        } ?? "—"
    }

    private func providerRow(_ item: MidasProviderPresentation) -> some View {
        let accounts = self.actions.accountPresentations(item.provider)
        return Button { self.navigation.provider = item.provider } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    MidasProviderLogo(provider: item.provider, size: 18)
                        .fixedSize().accessibilityHidden(true)
                    Text(item.name).font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if item.isStale || item.error != nil {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(MidasTheme.warning)
                            .help("Last known usage. Open provider details for connection status.")
                            .accessibilityLabel("Last known usage")
                    }
                    Spacer(minLength: 4)
                    if item.isRefreshing {
                        ProgressView().controlSize(.mini).accessibilityLabel("Refreshing usage")
                    }
                    Text(self.providerValue(item))
                        .font(.system(size: 17, weight: .semibold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .accessibilityLabel(item.dgxSpark == nil
                            ? item.spend?.accessibilityTitle ?? "Estimated inference spend"
                            : "API-equivalent value, last 30 days UTC")
                        .accessibilityValue(self.providerValue(item))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                MidasCompactOverviewMetrics(item: item, accounts: accounts)
                if item.dgxSpark != nil {
                    EmptyView()
                } else if item.spend?.isBilled == true {
                    Text("Billed separately · excluded from estimate")
                        .font(.system(size: 11)).foregroundStyle(MidasTheme.secondaryText)
                } else if item.spend?.isEstimate != true {
                    Text(item.spendUnavailableReason ?? "Estimate unavailable")
                        .font(.system(size: 11)).foregroundStyle(MidasTheme.secondaryText)
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .accessibilityValue(MidasCompactAccessibility.summary(item, accounts: accounts))
        .accessibilityHint("Show provider details")
    }
}

/// Capacity belongs to each account; money is shown once in the provider heading.
struct MidasOverviewMetrics: View {
    let item: MidasProviderPresentation
    var accounts: [MidasAccountPresentation] = []

    var body: some View {
        let metrics = MidasAccountQuotaLayout.overviewMetrics(self.item)
        VStack(alignment: .leading, spacing: 10) {
            if let spark = self.item.dgxSpark {
                Text("\(spark.tokenText) recorded tokens · Last 30 days")
                    .font(.callout).monospacedDigit()
                Text(spark.coverageText).font(.caption).foregroundStyle(MidasTheme.secondaryText)
            } else if self.accounts.count > 1 {
                MidasAccountOverviewBars(accounts: self.accounts)
            } else if !self.item.activityMetrics.isEmpty {
                MidasCompactOverviewMetrics(item: self.item)
                if self.item.isStale || self.item.error != nil {
                    Text("Stale").font(.caption).foregroundStyle(MidasTheme.warning)
                }
            } else if !metrics.isEmpty {
                ForEach(metrics) { selected in
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
            if self.item.dgxSpark == nil, self.accounts.count <= 1 {
                MidasBankedResetsRow(presentation: self.accounts.first?.presentation ?? self.item)
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
        return amount.formatted(.currency(code: currency).precision(.fractionLength(2)))
    }
}
