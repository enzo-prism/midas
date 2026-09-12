import CodexBarCore
import SwiftUI

@MainActor
struct DisplayPane: View {
    private static let maxOverviewProviders = SettingsStore.mergedOverviewProviderLimit

    static func overviewProviderLimitText(limit: Int = Self.maxOverviewProviders) -> String {
        L("overview_choose_providers", String(limit))
    }

    @State private var isOverviewProviderPopoverPresented = false
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                if self.isMidasBundle {
                    self.midasMenuBarSection
                }
                if self.showsLegacyControls {
                    SettingsSection(contentSpacing: 12) {
                        Text(L("section_menu_bar"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        PreferenceToggleRow(
                            title: L("merge_icons_title"),
                            subtitle: L("merge_icons_subtitle"),
                            binding: self.$settings.mergeIcons)
                        PreferenceToggleRow(
                            title: L("switcher_shows_icons_title"),
                            subtitle: L("switcher_shows_icons_subtitle"),
                            binding: self.$settings.switcherShowsIcons)
                            .disabled(!self.settings.mergeIcons)
                            .opacity(self.settings.mergeIcons ? 1 : 0.5)
                        PreferenceToggleRow(
                            title: L("show_most_used_provider_title"),
                            subtitle: L("show_most_used_provider_subtitle"),
                            binding: self.$settings.menuBarShowsHighestUsage)
                            .disabled(!self.settings.mergeIcons)
                            .opacity(self.settings.mergeIcons ? 1 : 0.5)
                        PreferenceToggleRow(
                            title: L("menu_bar_shows_percent_title"),
                            subtitle: L("menu_bar_shows_percent_subtitle"),
                            binding: self.$settings.menuBarShowsBrandIconWithPercent)
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L("display_mode_title"))
                                    .font(.body)
                                Text(L("display_mode_subtitle"))
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Picker(L("Display mode"), selection: self.$settings.menuBarDisplayMode) {
                                ForEach(MenuBarDisplayMode.allCases) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 200)
                        }
                        .disabled(!self.settings.menuBarShowsBrandIconWithPercent)
                        .opacity(self.settings.menuBarShowsBrandIconWithPercent ? 1 : 0.5)
                    }
                }

                Divider()

                SettingsSection(contentSpacing: 12) {
                    Text(L("section_menu_content"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    if self.showsLegacyControls {
                        PreferenceToggleRow(
                            title: L("show_usage_as_used_title"),
                            subtitle: L("show_usage_as_used_subtitle"),
                            binding: self.$settings.usageBarsShowUsed)
                        PreferenceToggleRow(
                            title: L("show_quota_warning_markers_title"),
                            subtitle: L("show_quota_warning_markers_subtitle"),
                            binding: self.$settings.quotaWarningMarkersVisible)
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L("weekly_progress_work_days_title"))
                                    .font(.body)
                                Text(L("weekly_progress_work_days_subtitle"))
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Picker(
                                L("weekly_progress_work_days_title"),
                                selection: self.$settings.weeklyProgressWorkDays)
                            {
                                Text(L("Off")).tag(nil as Int?)
                                Text(L("4 days")).tag(4 as Int?)
                                Text(L("5 days")).tag(5 as Int?)
                                Text(L("7 days")).tag(7 as Int?)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 100)
                        }
                        PreferenceToggleRow(
                            title: L("show_reset_time_as_clock_title"),
                            subtitle: L("show_reset_time_as_clock_subtitle"),
                            binding: self.$settings.resetTimesShowAbsolute)
                        PreferenceToggleRow(
                            title: L("show_provider_changelog_links_title"),
                            subtitle: L("show_provider_changelog_links_subtitle"),
                            binding: self.$settings.providerChangelogLinksEnabled)
                        PreferenceToggleRow(
                            title: L("show_credits_extra_usage_title"),
                            subtitle: L("show_credits_extra_usage_subtitle"),
                            binding: self.$settings.showOptionalCreditsAndExtraUsage)
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L("multi_account_layout_title"))
                                    .font(.body)
                                Text(L("multi_account_layout_subtitle"))
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Picker(L("multi_account_layout_title"), selection: self.$settings.multiAccountMenuLayout) {
                                ForEach(MultiAccountMenuLayout.allCases) { layout in
                                    Text(layout.label).tag(layout)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 200)
                        }
                    }
                    self.overviewProviderSelector
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .onAppear {
                self.reconcileOverviewSelection()
            }
            .onChange(of: self.settings.mergeIcons) { _, isEnabled in
                guard isEnabled else {
                    self.isOverviewProviderPopoverPresented = false
                    return
                }
                self.reconcileOverviewSelection()
            }
            .onChange(of: self.activeProvidersInOrder) { _, _ in
                if self.activeProvidersInOrder.isEmpty {
                    self.isOverviewProviderPopoverPresented = false
                }
                self.reconcileOverviewSelection()
            }
        }
    }

    private var isMidasBundle: Bool {
        Bundle.main.object(forInfoDictionaryKey: "MidasAirEnabled") as? Bool == true
    }

    private var showsLegacyControls: Bool {
        !self.isMidasBundle || self.settings.midasMenuBarMode == .legacy
    }

    private var usesMergedOverview: Bool {
        !self.showsLegacyControls || self.settings.mergeIcons
    }

    private var midasMenuBarSection: some View {
        SettingsSection(contentSpacing: 16) {
            Text("Midas menu bar")
                .font(.headline)
            Toggle("Track all connected accounts", isOn: self.$settings.midasTrackAllAccounts)
            Text("Refresh every connected account; quotas stay separate for each account.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Use OpenAI cloud token history", isOn: self.$settings.midasCloudUsageEnabled)
                .onChange(of: self.settings.midasCloudUsageEnabled) { _, _ in
                    self.store.tokenSnapshots[.codex] = nil
                    self.store.lastTokenFetchAt[.codex] = nil
                    self.store.scheduleTokenRefresh(force: true)
                }
            Text("Reads each account’s reported usage across devices. Personal accounts do not expose "
                + "input/cache/output token counts for API-rate pricing. Cloud data may be delayed.")
                .font(.caption).foregroundStyle(.secondary)
            if self.settings.midasCloudUsageEnabled {
                TextField(
                    "Optional blended USD per million tokens (0 = no dollar estimate)",
                    value: self.$settings.midasCloudUSDPerMillionTokens,
                    format: .number)
                    .onChange(of: self.settings.midasCloudUSDPerMillionTokens) { _, _ in
                        self.store.scheduleTokenRefresh(force: true)
                    }
                Text("A positive rate enables a modeled approximation, not a provider-reported cost.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Style", selection: self.$settings.midasMenuBarMode) {
                ForEach(MidasMenuBarMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 18) {
                Text(Self.menuBarPreview(self.settings.midasMenuBarMode))
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(MidasTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Illustrative menu bar preview")
                Text(Self.menuBarDescription(self.settings.midasMenuBarMode))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Previews use example values. Your saved legacy icon settings are preserved.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if self.settings.midasMenuBarMode == .focus || self.settings.midasMenuBarMode == .orbit {
                if self.activeProvidersInOrder.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(self.settings.midasMenuBarMode == .orbit ? "Orbit provider" : "Focus provider")
                        Text("\(self.providerDisplayName(self.settings.midasMenuBarFocusProvider)) (not enabled)")
                            .foregroundStyle(.secondary)
                        Text("Enable a provider in Providers to choose your favorite.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                } else {
                    Picker(
                        self.settings.midasMenuBarMode == .orbit ? "Orbit provider" : "Focus provider",
                        selection: self.$settings.midasMenuBarFocusProvider)
                    {
                        if !self.activeProvidersInOrder.contains(self.settings.midasMenuBarFocusProvider) {
                            Text("\(self.providerDisplayName(self.settings.midasMenuBarFocusProvider)) (not enabled)")
                                .tag(self.settings.midasMenuBarFocusProvider)
                                .disabled(true)
                        }
                        ForEach(self.activeProvidersInOrder, id: \.self) { provider in
                            HStack(spacing: 8) {
                                MidasProviderLogo(provider: provider, size: 16)
                                Text(self.providerDisplayName(provider))
                            }
                            .tag(provider)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            if self.settings.midasMenuBarMode != .legacy {
                PreferenceToggleRow(
                    title: "Hide spend in the menu bar",
                    subtitle: "Hide money in the status item and tooltip. Usage remains available in Midas.",
                    binding: self.$settings.midasMenuBarHideSpend)
            }
        }
    }

    static func menuBarDescription(_ mode: MidasMenuBarMode) -> String {
        switch mode {
        case .orbit: "Estimated inference spend first, with an orb for your chosen provider’s remaining capacity."
        case .ledger: "A compact estimate of usage value, with source and coverage details inside Midas."
        case .focus: "Keep one provider in view. Codex always shows weekly capacity remaining."
        case .constellation: "Up to three enabled providers, prioritizing Codex, Cursor, and Meta."
        case .legacy: "Use the original provider icons, merging, and metric controls."
        }
    }

    static func menuBarPreview(_ mode: MidasMenuBarMode) -> String {
        switch mode {
        case .orbit: "$73.20 ◉"
        case .ledger: "✦ ≈$73.20"
        case .focus: "C 72%"
        case .constellation: "C 72% · U 38% · M —"
        case .legacy: "▰ ▰"
        }
    }

    private var overviewProviderSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Text(L("overview_tab_providers_title"))
                    .font(.body)
                Spacer(minLength: 0)
                if self.showsOverviewConfigureButton {
                    Button(L("configure")) {
                        self.isOverviewProviderPopoverPresented = true
                    }
                    .offset(y: 1)
                    .popover(isPresented: self.$isOverviewProviderPopoverPresented, arrowEdge: .bottom) {
                        self.overviewProviderPopover
                    }
                }
            }

            if !self.usesMergedOverview {
                Text(L("overview_enable_merge_icons_hint"))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            } else if self.activeProvidersInOrder.isEmpty {
                Text(L("overview_no_providers_hint"))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            } else {
                Text(self.overviewProviderSelectionSummary)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
    }

    private var overviewProviderPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.overviewProviderLimitText())
                .font(.headline)
            Text(L("overview_rows_follow_order"))
                .font(.footnote)
                .foregroundStyle(.tertiary)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(self.activeProvidersInOrder, id: \.self) { provider in
                        Toggle(
                            isOn: Binding(
                                get: { self.overviewSelectedProviders.contains(provider) },
                                set: { shouldSelect in
                                    self.setOverviewProviderSelection(provider: provider, isSelected: shouldSelect)
                                })) {
                            Text(self.providerDisplayName(provider))
                                .font(.body)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(
                            !self.overviewSelectedProviders.contains(provider) &&
                                self.overviewSelectedProviders.count >= Self.maxOverviewProviders)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(12)
        .frame(width: 280)
    }

    private var activeProvidersInOrder: [UsageProvider] {
        self.store.enabledProviders()
    }

    private var overviewSelectedProviders: [UsageProvider] {
        self.settings.resolvedMergedOverviewProviders(
            activeProviders: self.activeProvidersInOrder,
            maxVisibleProviders: Self.maxOverviewProviders)
    }

    private var showsOverviewConfigureButton: Bool {
        self.usesMergedOverview && !self.activeProvidersInOrder.isEmpty
    }

    private var overviewProviderSelectionSummary: String {
        let selectedNames = self.overviewSelectedProviders.map(self.providerDisplayName)
        guard !selectedNames.isEmpty else { return L("overview_no_providers_selected") }
        return selectedNames.joined(separator: ", ")
    }

    private func providerDisplayName(_ provider: UsageProvider) -> String {
        ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
    }

    private func setOverviewProviderSelection(provider: UsageProvider, isSelected: Bool) {
        _ = self.settings.setMergedOverviewProviderSelection(
            provider: provider,
            isSelected: isSelected,
            activeProviders: self.activeProvidersInOrder,
            maxVisibleProviders: Self.maxOverviewProviders)
    }

    private func reconcileOverviewSelection() {
        _ = self.settings.reconcileMergedOverviewSelectedProviders(
            activeProviders: self.activeProvidersInOrder,
            maxVisibleProviders: Self.maxOverviewProviders)
    }
}
