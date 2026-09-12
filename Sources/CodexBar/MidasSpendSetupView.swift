import CodexBarCore
import SwiftUI

enum MidasSpendSetupRate {
    static func parse(_ text: String, locale: Locale = .current) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.isLenient = false
        // Validate the entire string rather than accepting a numeric prefix.
        let separator = locale.decimalSeparator ?? "."
        let parts = trimmed.components(separatedBy: separator)
        guard parts.count <= 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let value = formatter.number(from: trimmed)?.doubleValue,
              value.isFinite, value >= 0, value <= 1000 else { return nil }
        return value
    }
}

@MainActor
struct MidasSpendSetupView: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    let coordinator: ManagedCodexAccountCoordinator
    let openProvider: (UsageProvider) -> Void
    var onFinish: () -> Void = {}
    var initialStep: MidasOnboardingStep = .services
    var runProviderLoginFlow: @MainActor (UsageProvider) async -> Void = { _ in }
    var onStepChange: (MidasOnboardingStep) -> Void = { _ in }
    var onDefer: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var step: MidasOnboardingStep = .services
    @State private var selected: Set<UsageProvider> = []
    @State private var rateText = ""
    @State private var estimateMode: MidasCodexEstimateMode = .automatic
    @State private var message: String?
    @State private var isWorking = false
    @State private var showsPricingOptions = false

    private var accounts: [CodexVisibleAccount] {
        self.settings.codexVisibleAccountProjection.visibleAccounts
    }

    private var rate: Double? {
        MidasSpendSetupRate.parse(self.rateText)
    }

    private var providers: [UsageProvider] {
        MidasOnboarding.providers.filter { self.selected.contains($0) }
    }

    private var canContinue: Bool {
        !self.selected.isEmpty && !self.isWorking && !self.coordinator.hasConflictingManagedAccountOperationInFlight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            self.header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch self.step {
                    case .services: self.services
                    case .accounts: self.connections
                    case .overview: self.overview
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            if let message = self.message {
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            self.footer
        }
        .padding(28)
        .frame(width: 600, height: min(650, max(430, (NSScreen.main?.visibleFrame.height ?? 800) - 100)))
        .tint(MidasTheme.accent)
        .onAppear {
            self.step = self.initialStep
            self.selected = Set(MidasOnboarding.providers.filter { self.store.isEnabled($0) })
            self.estimateMode = self.settings.midasCodexEstimateMode
            let rate = self.settings.midasCloudUSDPerMillionTokens
            self.rateText = rate > 0 ? rate.formatted(.number.grouping(.never)) : ""
            self.revealInvalidPricing()
        }
        .onChange(of: self.step) { _, value in
            self.onStepChange(value)
            self.revealInvalidPricing()
        }
        .interactiveDismissDisabled(self.isWorking || self.coordinator.isAuthenticatingManagedAccount)
    }

    private func revealInvalidPricing() {
        if self.step == .overview, !MidasOnboarding.canContinue(
            selected: self.selected,
            mode: self.estimateMode,
            rate: MidasSpendSetupRate.parse(self.rateText))
        {
            self.showsPricingOptions = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Midas").font(.title2.bold())
                Spacer()
                Button("Set up later") { self.onDefer(); self.dismiss() }.disabled(self.isWorking)
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(MidasOnboardingStep.allCases, id: \.rawValue) { item in
                    Text(item.label)
                        .font(.caption.weight(self.step == item ? .semibold : .regular))
                        .foregroundStyle(self.step == item ? .primary : .secondary)
                        .accessibilityAddTraits(self.step == item ? .isSelected : [])
                    if item !=
                        .overview { Image(systemName: "chevron.right").font(.caption2).accessibilityHidden(true) }
                }
            }
        }
    }

    private var services: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your AI usage, in one place.").font(.system(size: 28, weight: .semibold))
            Text("Estimated dollars. Usage left. Time until reset.").foregroundStyle(.secondary)
            Text("Which services do you use?").font(.headline).padding(.top, 8)
            ForEach(MidasOnboarding.providers, id: \.self) { provider in
                MidasOnboardingServiceRow(provider: provider, isSelected: self.selected.contains(provider)) {
                    if self.selected.contains(provider) {
                        self.selected.remove(provider)
                    } else {
                        self.selected.insert(provider)
                    }
                }
            }
            Text("You can change these anytime.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var connections: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect your accounts.").font(.system(size: 28, weight: .semibold))
            Text("Start with one. Add more whenever you like.").foregroundStyle(.secondary)
            ForEach(self.providers, id: \.self) { provider in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(self.name(provider)).font(.headline)
                        Spacer()
                        if self
                            .hasUsage(provider) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    }
                    if provider == .codex { self.codexConnections } else { self.otherConnection(provider) }
                }
                .padding(16)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
            }
            Text("Missing usage never counts as $0.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var codexConnections: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(self.accounts) { account in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(self.accountName(account)).font(.callout.weight(.medium)).textSelection(.enabled)
                        Text(self.accountStatus(account)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let id = account.storedAccountID,
                       self.store.midasCloudErrors[account.id] != nil || account.authFingerprint == nil
                    {
                        Button("Reconnect") { Task { await self.connectCodex(existingID: id) } }
                            .disabled(self.isWorking)
                    }
                }
            }
            Button(self.accounts.contains { $0.storedAccountID != nil } ? "Add another account" : "Connect Codex") {
                Task { await self.connectCodex() }
            }
            .disabled(self.isWorking || self.coordinator.hasConflictingManagedAccountOperationInFlight
                || self.settings.codexVisibleAccountProjection.hasUnreadableAddedAccountStore)
            Text("Sign in with OpenAI. Midas keeps a separate connection for each account.")
                .font(.caption).foregroundStyle(.secondary)
            if self.settings.codexVisibleAccountProjection.hasUnreadableAddedAccountStore {
                Text("Saved accounts could not be read. Open Codex settings to recover them.")
                    .font(.caption).foregroundStyle(.orange)
                Button("Open Codex settings") { self.openProvider(.codex) }
            }
            if !self.accounts.isEmpty, !self.settings.hidePersonalInfo {
                DisclosureGroup("Account names") {
                    ForEach(self.accounts) { account in
                        TextField(account.displayName, text: Binding(
                            get: { self.settings.midasAccountAliases["codex:" + account.id] ?? "" },
                            set: { self.settings.midasAccountAliases["codex:" + account.id] = String($0.prefix(40)) }))
                            .textFieldStyle(.roundedBorder).accessibilityLabel("Short name for " + account.displayName)
                    }
                }.font(.caption)
            }
        }
    }

    private func otherConnection(_ provider: UsageProvider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(MidasOnboarding.availability(
                hasUsage: self.hasUsage(provider),
                isRefreshing: self.store.tokenRefreshInFlight.contains(provider),
                hasError: self.store.errors[provider] != nil || self.store.tokenErrors[provider] != nil,
                isLocal: provider == .meta))
                .font(.callout).foregroundStyle(.secondary)
            if provider == .cursor {
                Button(self.hasUsage(provider) ? "Reconnect Cursor" : "Connect Cursor") {
                    Task {
                        self.isWorking = true
                        self.message = "Finish the Cursor connection in your browser."
                        defer { self.isWorking = false }
                        await self.runProviderLoginFlow(.cursor)
                        self.store.scheduleTokenRefresh(force: true)
                        self.message = self.hasUsage(.cursor)
                            ? "Cursor usage is available." : "Usage is still pending. You can continue."
                    }
                }.disabled(self.isWorking)
            } else {
                Text("Reads Muse activity on this Mac. Other Macs are not included.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Set up Meta") { self.openProvider(.meta) }.disabled(self.isWorking)
            }
            DisclosureGroup("Connection help") {
                Text(provider == .cursor ? "Connect the Cursor account whose usage you want to track." :
                    "Use Muse on this Mac, then refresh Midas.")
                Button("Open provider settings") { self.openProvider(provider) }.disabled(self.isWorking)
            }.font(.caption)
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your overview.").font(.system(size: 28, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                Text("Estimated inference spend · " +
                    MidasSpendPeriod(selection: self.settings.midasSpendPeriodSelection).label)
                    .font(.callout).foregroundStyle(.secondary)
                Text(MidasOnboarding.total(self.providers.map { self.amount($0) })?
                    .formatted(.currency(code: "USD")) ?? "Waiting for usage")
                    .font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit()
                ForEach(self.providers, id: \.self) { provider in
                    HStack {
                        Text(self.name(provider))
                        Spacer()
                        Text(self.amount(provider)?.formatted(.currency(code: "USD")) ?? "Not available yet")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }.font(.callout)
                }
                Text("Available history only. An estimate, not a bill.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(18)
            .background(MidasTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            Text("Find Midas in your menu bar for dollars, usage left and reset times.").foregroundStyle(.secondary)
            if self.selected.contains(.codex) {
                DisclosureGroup("Codex estimate options", isExpanded: self.$showsPricingOptions) { self.pricingOptions }
            }
            Button("Refresh usage") { self.refreshUsage() }
        }
    }

    private var pricingOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Estimate method", selection: self.$estimateMode) {
                ForEach(MidasCodexEstimateMode.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
            switch self.estimateMode {
            case .automatic:
                Text("Uses an observed pricing mix. No rate to enter.").font(.caption).foregroundStyle(.secondary)
                if self.store.midasCodexAutomaticEstimate == nil {
                    Text("Waiting for priced local activity or a shared sample from another Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                MidasCalibrationSharingView(settings: self.settings, store: self.store)
            case .custom:
                TextField("USD per million tokens", text: self.$rateText).textFieldStyle(.roundedBorder)
                if !MidasOnboarding.canContinue(selected: self.selected, mode: self.estimateMode, rate: self.rate) {
                    Text("Enter a rate greater than 0 and up to 1,000.").font(.caption).foregroundStyle(.orange)
                }
            case .tokensOnly:
                Text("Codex dollars are excluded from your total.").font(.caption).foregroundStyle(.secondary)
            }
            if let estimate = self.store.midasCodexAutomaticEstimate, self.estimateMode == .automatic {
                DisclosureGroup("Calculation details") {
                    Text(estimate.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.top, 8)
    }

    private var footer: some View {
        HStack {
            if self.step != .services {
                Button("Back") { self.step = self.step == .overview ? .accounts : .services; self.message = nil }
                    .disabled(self.isWorking)
            }
            if self.isWorking { ProgressView().controlSize(.small) }
            Spacer()
            Button(self.step == .overview ? "Open Midas" : "Continue") {
                self.applyChoices()
                self.message = nil
                switch self.step {
                case .services: self.step = .accounts
                case .accounts: self.step = .overview; self.refreshUsage()
                case .overview: self.onFinish(); self.dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!self.canContinue || (self.step == .overview
                    && !MidasOnboarding.canContinue(selected: self.selected, mode: self.estimateMode, rate: self.rate)))
        }
    }

    private func name(_ provider: UsageProvider) -> String {
        ProviderDefaults.metadata[provider]?
            .displayName ?? provider.rawValue
    }

    private func hasUsage(_ provider: UsageProvider) -> Bool {
        self.store.snapshots[provider] != nil || self.store.tokenSnapshots[provider]?.last30DaysTokens != nil
    }

    private func accountName(_ account: CodexVisibleAccount) -> String {
        let names = MidasAccountNames.resolve(
            identities: self.accounts.map { ($0.id, $0.displayName) },
            provider: .codex,
            aliases: self.settings.midasAccountAliases,
            hidePersonalInfo: self.settings.hidePersonalInfo)
        return names[account.id] ?? "Account"
    }

    private func accountStatus(_ account: CodexVisibleAccount) -> String {
        if self.store.midasCloudErrors[account.id] != nil { return "History unavailable · refresh or reconnect" }
        if self.store.midasCloudAccounts[account.id]?.totalTokens != nil { return "Cloud history available" }
        return account.storedAccountID == nil
            ? "Detected on this Mac · connect to keep tracking" : "Connected · history pending"
    }

    private func amount(_ provider: UsageProvider) -> Double? {
        var snapshot = self.store.tokenSnapshots[provider]
        if provider == .codex, self.settings.midasCloudUsageEnabled {
            let rate = self.estimateMode == .automatic ? self.store.midasCodexAutomaticEstimate?.rate
                : (self.estimateMode == .custom ? self.rate : nil)
            snapshot = UsageStore.cloudTokenSnapshot(
                accounts: self.accounts.compactMap { self.store.midasCloudAccounts[$0.id] },
                rate: rate ?? 0,
                now: Date())
        } else if snapshot?.costProvenance != .listPriceEstimate { return nil }
        guard let snapshot else { return nil }
        return MidasSpendPeriod(selection: self.settings.midasSpendPeriodSelection).amount(snapshot: snapshot)?.dollars
    }

    private func applyChoices() {
        for provider in MidasOnboarding.providers {
            if let metadata = ProviderDefaults.metadata[provider] {
                self.settings.setProviderEnabled(
                    provider: provider,
                    metadata: metadata,
                    enabled: self.selected.contains(provider))
            }
        }
        self.settings.costUsageEnabled = true
        if self.selected.contains(.codex) {
            self.settings.midasTrackAllAccounts = true
            self.settings.midasCloudUsageEnabled = true
            self.settings.midasCodexEstimateMode = self.estimateMode
            if self.estimateMode == .custom, let rate = self.rate,
               rate > 0 { self.settings.midasCloudUSDPerMillionTokens = rate }
            self.store.repriceMidasCloudUsage()
        }
    }

    private func refreshUsage() {
        self.store.scheduleTokenRefresh(force: true)
        if self.selected.contains(.codex) { Task { await self.store.refreshMidasCloudUsage(force: true) } }
    }

    private func connectCodex(existingID: UUID? = nil) async {
        self.isWorking = true
        self.message = "Finish signing in with OpenAI in your browser."
        defer { self.isWorking = false }
        do {
            _ = try await self.coordinator.authenticateManagedAccount(existingAccountID: existingID, timeout: 300)
            self.settings.invalidateCodexAccountReconciliationSnapshotCache()
            self.applyChoices()
            self.refreshUsage()
            self.message = "Account connected. Add another, or continue."
        } catch {
            self.message = self.settings.hidePersonalInfo
                ? "Could not connect. Try again or open Codex settings."
                : ((error as? ManagedCodexAccountServiceError)?.userFacingMessage ?? error.localizedDescription)
        }
    }
}
