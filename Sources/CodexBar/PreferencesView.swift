import AppKit
import CodexBarCore
import SwiftUI

enum PreferencesTab: String, CaseIterable, Hashable {
    case general
    case providers
    case sync
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
        case .sync: "Sync"
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
        case .sync: "icloud"
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
    @State private var showsSpendSetup = false
    @State private var spendSetupProvider: UsageProvider?
    @State private var finishesSpendSetup = false
    @State private var defersSpendSetup = false
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    let updater: UpdaterProviding
    @Bindable var selection: PreferencesSelection
    let managedCodexAccountCoordinator: ManagedCodexAccountCoordinator
    let codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator
    let runProviderLoginFlow: @MainActor (UsageProvider) async -> Void
    let openMidas: @MainActor () -> Void

    init(
        settings: SettingsStore,
        store: UsageStore,
        updater: UpdaterProviding,
        selection: PreferencesSelection,
        managedCodexAccountCoordinator: ManagedCodexAccountCoordinator = ManagedCodexAccountCoordinator(),
        codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator? = nil,
        runProviderLoginFlow: @escaping @MainActor (UsageProvider) async -> Void = { _ in },
        openMidas: @escaping @MainActor () -> Void = {})
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
        self.openMidas = openMidas
    }

    private var availableHeight: CGFloat {
        min(PreferencesTab.windowHeight, max(420, (NSScreen.main?.visibleFrame.height ?? 800) - 80))
    }

    private var tabSelection: Binding<PreferencesTab?> {
        Binding(
            get: { self.selection.tab },
            set: { tab in
                guard let tab, self.visibleTabs.contains(tab) else { return }
                self.selection.tab = tab
            })
    }

    var body: some View {
        NavigationSplitView {
            self.sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 196, max: 260)
        } detail: {
            self.selectedPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
                .background(MidasTheme.background)
                .navigationTitle(self.selection.tab.title)
        }
        .navigationSplitViewStyle(.balanced)
        .foregroundStyle(MidasTheme.text)
        .tint(MidasTheme.accent)
        .id(self.settings.appLanguage)
        .frame(width: PreferencesTab.defaultWidth, height: self.availableHeight)
        .sheet(isPresented: self.$showsSpendSetup, onDismiss: self.finishSpendSetup) {
            MidasSpendSetupView(
                settings: self.settings,
                store: self.store,
                coordinator: self.managedCodexAccountCoordinator,
                openProvider: {
                    self.spendSetupProvider = $0
                    self.selection.spendSetupStep = .accounts
                    self.selection.spendSetupPending = true
                    self.showsSpendSetup = false
                },
                onFinish: {
                    self.finishesSpendSetup = true
                    self.showsSpendSetup = false
                },
                initialStep: self.selection.spendSetupStep,
                runProviderLoginFlow: self.runProviderLoginFlow,
                onStepChange: { self.selection.spendSetupStep = $0 },
                onDefer: { self.defersSpendSetup = true; self.showsSpendSetup = false })
                .onAppear {
                    self.settings.userDefaults.set(true, forKey: MidasOnboardingLaunch.presentedKey)
                    self.settings.userDefaults.removeObject(forKey: MidasOnboardingLaunch.pendingKey)
                    self.selection.spendSetupPending = true
                }
        }
        .onAppear {
            self.consumeSetupRequest()
            self.ensureValidTabSelection()
        }
        .onChange(of: self.selection.requestsSpendSetup) { _, _ in
            self.consumeSetupRequest()
        }
        .onChange(of: self.settings.debugMenuEnabled) { _, _ in
            self.ensureValidTabSelection()
        }
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
            List(selection: self.tabSelection) {
                ForEach(self.visibleTabs, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.symbol)
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button(self.selection.spendSetupPending ? "Continue setup" : "Set up Midas") {
                    if !self.selection.spendSetupPending { self.selection.spendSetupStep = .services }
                    self.showsSpendSetup = true
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .padding(16)
            }
        }
    }

    private func consumeSetupRequest() {
        guard self.selection.requestsSpendSetup else { return }
        self.selection.requestsSpendSetup = false
        self.selection.spendSetupStep = .services
        self.showsSpendSetup = true
    }

    private func finishSpendSetup() {
        if self.finishesSpendSetup || self.defersSpendSetup {
            if self.finishesSpendSetup {
                self.selection.spendSetupPending = false
                self.selection.spendSetupStep = .services
            }
            self.finishesSpendSetup = false
            self.defersSpendSetup = false
            NSApp.windows.first { $0.identifier == SettingsWindowIdentity.identifier }?.close()
            self.openMidas()
            return
        }
        if let provider = self.spendSetupProvider {
            self.spendSetupProvider = nil
            self.selection.showProvider(provider)
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
        case .sync:
            PreferencesSyncPane(coordinator: self.store.midasUsageSync)
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
