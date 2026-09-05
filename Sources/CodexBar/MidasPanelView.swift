import CodexBarCore
import SwiftUI

struct MidasPanelView: View {
    let store: UsageStore
    let settings: SettingsStore
    @Bindable var navigation: MidasNavigationState
    let presentation: (UsageProvider) -> MidasProviderPresentation
    let actions: MidasActions
    @State private var showsAllProviders = false

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
                Image(systemName: "sparkle").foregroundStyle(MidasTheme.accent).accessibilityHidden(true)
                Text("Midas").font(.system(size: 17, weight: .semibold, design: .rounded))
            }
            Spacer()
            Button(action: self.actions.refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(MidasQuietButtonStyle()).help("Refresh usage")
            .accessibilityLabel("Refresh usage").keyboardShortcut("r", modifiers: .command)
            Button(action: self.actions.settings) { Image(systemName: "gearshape") }
                .buttonStyle(MidasQuietButtonStyle()).help("Settings")
                .accessibilityLabel("Settings").keyboardShortcut(",", modifiers: .command)
            Menu {
                Button("Provider actions & accounts…", action: self.actions.legacyMenu)
                Divider()
                Button("Quit Midas", action: self.actions.quit).keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).fixedSize().help("More actions").accessibilityLabel("More actions")
        }
    }

    private var providers: [UsageProvider] {
        self.store.enabledProvidersForDisplay()
    }

    private var visibleProviders: [UsageProvider] {
        if self.showsAllProviders { return self.providers }
        return self.settings.resolvedMergedOverviewProviders(activeProviders: self.providers, maxVisibleProviders: 5)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 24) {
            MidasTotalSpendView(presentations: self.providers.map(self.presentation))
            HStack {
                Text(self.showsAllProviders ? "All providers" : "✨ Overview").font(.callout.weight(.medium))
                Spacer()
                if !self.providers.isEmpty {
                    Button(self.showsAllProviders ? "Favorites" : "All providers") {
                        self.showsAllProviders.toggle()
                    }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(MidasTheme.accent)
                }
            }
            if self.visibleProviders.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(self.providers.isEmpty ? "Make room for your favorite tools." : "Choose your favorites.")
                        .font(.headline)
                    Text(self.providers
                        .isEmpty ? "Connect a provider to see its usage here." :
                        "Your connected providers are in All providers.")
                        .font(.callout).foregroundStyle(MidasTheme.secondaryText)
                    Button(self.providers.isEmpty ? "Connect a provider" : "All providers") {
                        if self.providers.isEmpty { self.actions.settings() } else { self.showsAllProviders = true }
                    }.buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 22) {
                    ForEach(self.visibleProviders, id: \.self) { provider in
                        self.providerRow(self.presentation(provider))
                    }
                }
            }
            Button { self.actions.openUsage(nil) } label: {
                HStack {
                    Label("Open Usage", systemImage: "chart.xyaxis.line")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .font(.callout.weight(.medium)).padding(12)
                .background(MidasTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }

    private func providerRow(_ item: MidasProviderPresentation) -> some View {
        Button { self.navigation.provider = item.provider } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    MidasProviderLogo(provider: item.provider, size: 28)
                        .fixedSize().accessibilityHidden(true)
                    Text(item.name).font(.system(size: 15, weight: .semibold))
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    if item.isRefreshing { ProgressView().controlSize(.mini) }
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(MidasTheme.secondaryText)
                }
                MidasOverviewMetrics(item: item)
                if item.error != nil || item.isStale {
                    Label(
                        item.error == nil ? "Last known usage" : "Needs attention",
                        systemImage: "exclamationmark.circle")
                        .font(.caption2).foregroundStyle(MidasTheme.warning)
                } else if let reset = item.hero?.resetText {
                    Text(reset).font(.caption2).foregroundStyle(MidasTheme.secondaryText)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Show provider details")
    }
}

/// Shared overview hierarchy: a labeled money source, then capacity or token activity.
struct MidasOverviewMetrics: View {
    let item: MidasProviderPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let spend = self.item.spend {
                VStack(alignment: .leading, spacing: 5) {
                    Text(spend.title).font(.caption).foregroundStyle(MidasTheme.secondaryText)
                    Text(spend.value)
                        .font(.system(size: 27, weight: .medium, design: .rounded))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(spend.period).font(.caption)
                        .foregroundStyle(MidasTheme.secondaryText)
                        .multilineTextAlignment(.leading)
                    if let secondary = spend.secondaryValue, let label = spend.secondaryLabel {
                        Text("\(label): \(secondary)")
                            .font(.caption).foregroundStyle(MidasTheme.secondaryText)
                    }
                }
                .help(spend.detail)
                if let metric = self.item.hero {
                    self.quota(metric)
                } else if let activity = self.item.activitySummary {
                    Text(activity).font(.callout).foregroundStyle(MidasTheme.secondaryText)
                }
            } else if let metric = self.item.hero {
                VStack(alignment: .leading, spacing: 6) {
                    Text(metric.valueText)
                        .font(.system(size: 27, weight: .medium, design: .rounded)).monospacedDigit()
                    Text(metric.title).font(.caption).foregroundStyle(MidasTheme.secondaryText)
                    MidasRemainingBar(percent: metric.remainingPercent)
                }
                self.fallbackSpend
            } else {
                Text(self.item.activitySummary ?? self.item.summary)
                    .font(.system(size: 15, weight: .medium))
                    .multilineTextAlignment(.leading)
                self.fallbackSpend
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fallbackSpend: some View {
        Text(self.item.financialSummary.map { "\(self.item.financialLabel ?? "Provider usage"): \($0)" }
            ?? "Spend unavailable")
            .font(.caption2).foregroundStyle(MidasTheme.secondaryText)
    }

    private func quota(_ metric: MidasQuotaMetric) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(metric.title).foregroundStyle(MidasTheme.secondaryText)
                Spacer()
                Text(metric.valueText).monospacedDigit()
                    .foregroundStyle(metric.isExhausted ? MidasTheme.warning : MidasTheme.text)
            }
            .font(.callout)
            MidasRemainingBar(percent: metric.remainingPercent)
        }
    }
}
