import AppKit
import CodexBarCore
import SwiftUI

enum PreferencesTab: String, CaseIterable, Hashable {
    case general
    case providers
    case display
    case advanced
    case about
    case debug

    static let defaultWidth: CGFloat = 1000
    static let providersWidth: CGFloat = 1000
    static let windowHeight: CGFloat = 720

    var title: String {
        switch self {
        case .general: L("tab_general")
        case .providers: L("tab_providers")
        case .display: L("tab_display")
        case .advanced: L("tab_advanced")
        case .about: L("tab_about")
        case .debug: L("tab_debug")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .providers: "square.grid.2x2"
        case .display: "paintpalette"
        case .advanced: "slider.horizontal.3"
        case .about: "sparkles"
        case .debug: "ladybug"
        }
    }

    var preferredWidth: CGFloat {
        self == .providers ? PreferencesTab.providersWidth : PreferencesTab.defaultWidth
    }

    var preferredHeight: CGFloat {
        PreferencesTab.windowHeight
    }
}

@MainActor
struct PreferencesView: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    let updater: UpdaterProviding
    @Bindable var selection: PreferencesSelection
    let managedCodexAccountCoordinator: ManagedCodexAccountCoordinator
    let codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator
    let runProviderLoginFlow: @MainActor (UsageProvider) async -> Void

    init(
        settings: SettingsStore,
        store: UsageStore,
        updater: UpdaterProviding,
        selection: PreferencesSelection,
        managedCodexAccountCoordinator: ManagedCodexAccountCoordinator = ManagedCodexAccountCoordinator(),
        codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator? = nil,
        runProviderLoginFlow: @escaping @MainActor (UsageProvider) async -> Void = { _ in })
    {
        self.settings = settings
        self.store = store
        self.updater = updater
        self.selection = selection
        self.managedCodexAccountCoordinator = managedCodexAccountCoordinator
        self.codexAccountPromotionCoordinator = codexAccountPromotionCoordinator
            ?? CodexAccountPromotionCoordinator(
                settingsStore: settings,
                usageStore: store,
                managedAccountCoordinator: managedCodexAccountCoordinator)
        self.runProviderLoginFlow = runProviderLoginFlow
    }

    private var availableHeight: CGFloat {
        min(PreferencesTab.windowHeight, max(420, (NSScreen.main?.visibleFrame.height ?? 800) - 80))
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Midas")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("Your workspace, your way.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                VStack(spacing: 6) {
                    ForEach(self.visibleTabs, id: \.self) { tab in
                        Button {
                            self.selection.tab = tab
                        } label: {
                            Label(tab.title, systemImage: tab.symbol)
                                .font(.system(size: 13, weight: self.selection.tab == tab ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 11)
                                .contentShape(Rectangle())
                                .background(
                                    self.selection.tab == tab ? MidasTheme.accent.opacity(0.13) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(self.selection.tab == tab ? .isSelected : [])
                    }
                }
                Spacer()
                Text("Made for a little more clarity.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
            .padding(16)
            .frame(width: 196)
            .background(MidasTheme.surface)

            VStack(alignment: .leading, spacing: 24) {
                Text(self.selection.tab.title)
                    .font(.system(size: 27, weight: .semibold))
                self.selectedPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(28)
            .background(MidasTheme.background)
        }
        .foregroundStyle(MidasTheme.text)
        .tint(MidasTheme.accent)
        .id(self.settings.appLanguage)
        .frame(width: PreferencesTab.defaultWidth, height: self.availableHeight)
        .onAppear {
            self.ensureValidTabSelection()
            NSApp.windows.first {
                $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
            }?.title = "Midas Settings"
        }
        .onChange(of: self.settings.debugMenuEnabled) { _, _ in
            self.ensureValidTabSelection()
        }
    }

    private var visibleTabs: [PreferencesTab] {
        PreferencesTab.allCases.filter { $0 != .debug || self.settings.debugMenuEnabled }
    }

    @ViewBuilder
    private var selectedPane: some View {
        switch self.selection.tab {
        case .general:
            GeneralPane(settings: self.settings, store: self.store)
        case .providers:
            ProvidersPane(
                settings: self.settings,
                store: self.store,
                preferencesSelection: self.selection,
                managedCodexAccountCoordinator: self.managedCodexAccountCoordinator,
                codexAccountPromotionCoordinator: self.codexAccountPromotionCoordinator,
                runProviderLoginFlow: self.runProviderLoginFlow)
        case .display:
            DisplayPane(settings: self.settings, store: self.store)
        case .advanced:
            AdvancedPane(settings: self.settings)
        case .about:
            AboutPane(updater: self.updater)
        case .debug:
            DebugPane(settings: self.settings, store: self.store)
        }
    }

    private func ensureValidTabSelection() {
        if !self.settings.debugMenuEnabled, self.selection.tab == .debug {
            self.selection.tab = .general
        }
    }
}
