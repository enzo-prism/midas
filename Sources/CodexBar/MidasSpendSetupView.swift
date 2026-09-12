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
    @Environment(\.dismiss) private var dismiss
    @State private var rateText = ""
    @State private var estimateMode: MidasCodexEstimateMode = .automatic
    @State private var message: String?
    @State private var isWorking = false

    private var accounts: [CodexVisibleAccount] {
        self.settings.codexVisibleAccountProjection.visibleAccounts
    }

    private var rate: Double? {
        MidasSpendSetupRate.parse(self.rateText)
    }

    private var isRateValid: Bool {
        self.estimateMode != .custom || (self.rate.map { $0 > 0 } ?? false)
    }

    private var previewRate: Double? {
        switch self.estimateMode {
        case .automatic: self.store.midasCodexAutomaticEstimate?.rate
        case .custom: self.rate.flatMap { $0 > 0 ? $0 : nil }
        case .tokensOnly: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Set up accounts & spend").font(.title2.bold())
                Spacer()
                Button("Done") { self.dismiss() }
                    .disabled(self.coordinator.isAuthenticatingManagedAccount)
            }
            Text("Connect once on each Mac. Midas combines available dollar estimates across your accounts.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    self.accountsSection
                    Divider()
                    self.pricingSection
                    Divider()
                    self.otherProvidersSection
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let message = self.message {
                Text(message).font(.callout).textSelection(.enabled)
            }
            HStack {
                if self.isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button(self.isWorking ? "Working…" : "Save and refresh") {
                    Task { await self.saveAndRefresh() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(self.isWorking || !self.isRateValid || self.accounts.isEmpty
                    || self.coordinator.hasConflictingManagedAccountOperationInFlight)
            }
        }
        .padding(24)
        .frame(width: 600, height: 650)
        .onAppear {
            self.estimateMode = self.settings.midasCodexEstimateMode
            let rate = self.settings.midasCloudUSDPerMillionTokens
            self.rateText = rate > 0 ? rate.formatted(.number.grouping(.never)) : ""
        }
        .interactiveDismissDisabled(self.coordinator.isAuthenticatingManagedAccount)
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1. Connect your Codex accounts").font(.headline)
            Text("Sign in with OpenAI in your browser. Repeat for each account you use.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(self.accounts) { account in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.displayName).fontWeight(.medium)
                        TextField("Short name (optional)", text: Binding(
                            get: { self.settings.midasAccountAliases["codex:" + account.id] ?? "" },
                            set: { value in
                                self.settings.midasAccountAliases["codex:" + account.id] =
                                    String(value.prefix(40))
                            }))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Short name for " + account.displayName)
                        Text(self.accountStatus(account)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let id = account.storedAccountID {
                        Button("Reconnect") { Task { await self.connect(existingID: id) } }
                            .disabled(self.isWorking || self.coordinator.hasConflictingManagedAccountOperationInFlight)
                    }
                }
            }
            Button(self.accounts.isEmpty ? "Connect OpenAI account" : "Connect another OpenAI account") {
                Task { await self.connect() }
            }
            .disabled(self.isWorking || self.coordinator.hasConflictingManagedAccountOperationInFlight
                || self.settings.codexVisibleAccountProjection.hasUnreadableAddedAccountStore)
            Text("Your default Codex login stays unchanged. A separate Midas connection keeps each account available.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var pricingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("2. Estimate Codex dollars").font(.headline)
            Picker("Estimate method", selection: self.$estimateMode) {
                ForEach(MidasCodexEstimateMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            switch self.estimateMode {
            case .automatic:
                Text("Uses an observed pricing mix to estimate usage across devices.")
                    .font(.callout).foregroundStyle(.secondary)
                if self.store.midasCodexAutomaticEstimate == nil {
                    Text("Waiting for a priced local or shared sample.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                MidasCalibrationSharingView(settings: self.settings, store: self.store)
            case .custom:
                HStack {
                    Text("USD per million tokens")
                    TextField("Rate", text: self.$rateText)
                        .textFieldStyle(.roundedBorder).frame(width: 130)
                }
                if !self.isRateValid {
                    Text("Enter a rate greater than 0 and up to 1,000.")
                        .font(.caption).foregroundStyle(.red)
                }
            case .tokensOnly:
                Text("Codex dollars are excluded from your total.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let rate = self.previewRate {
                let snapshot = UsageStore.cloudTokenSnapshot(
                    accounts: self.accounts.compactMap { self.store.midasCloudAccounts[$0.id] },
                    rate: rate,
                    now: Date())
                Text(snapshot.last30DaysCostUSD.map {
                    "Codex preview: " + $0.formatted(.currency(code: "USD")) + " over 30 days"
                } ?? "Refresh connected accounts to preview your estimate.")
                Text("Estimate, not a bill. Missing histories are excluded.")
                    .font(.caption).foregroundStyle(.secondary)
                if self.estimateMode == .automatic, let estimate = self.store.midasCodexAutomaticEstimate {
                    DisclosureGroup("Estimate details") {
                        Text(estimate.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var otherProvidersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("3. Review provider coverage").font(.headline)
            self.providerRow(.cursor, title: "Cursor", detail: "Uses connected account history for dollar estimates.")
            self.providerRow(
                .meta,
                title: "Meta",
                detail: "Uses this Mac’s Muse history. Other computers are not included.")
            Text(
                "Available provider estimates are added once. "
                    + "Unavailable accounts and providers remain marked as missing.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func providerRow(_ provider: UsageProvider, title: String, detail: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                Text(self.store.isEnabled(provider) ? "Enabled" : "Not enabled")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Manage") { self.dismiss(); self.openProvider(provider) }.disabled(self.isWorking)
        }
    }

    private func accountStatus(_ account: CodexVisibleAccount) -> String {
        if let error = self.store.midasCloudErrors[account.id] { return error }
        if let total = self.store.midasCloudAccounts[account.id]?.totalTokens {
            return total.formatted() + " reported tokens · 30 days"
        }
        return account.storedAccountID == nil
            ? "Detected on this Mac — connect separately to keep tracking when you switch accounts."
            : "Connected · token history pending or not yet refreshed"
    }

    private func enableTracking() {
        self.settings.costUsageEnabled = true
        self.settings.midasTrackAllAccounts = true
        self.settings.midasCloudUsageEnabled = true
        if let metadata = ProviderDefaults.metadata[.codex] {
            self.settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: true)
        }
        self.store.lastTokenFetchAt[.codex] = nil
    }

    private func connect(existingID: UUID? = nil) async {
        self.isWorking = true
        self.message = "Finish signing in in your browser. This can take a few minutes."
        defer { self.isWorking = false }
        do {
            _ = try await self.coordinator.authenticateManagedAccount(existingAccountID: existingID, timeout: 300)
            self.settings.invalidateCodexAccountReconciliationSnapshotCache()
            self.enableTracking()
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await self.store.refreshCodexAccountScopedState(allowDisabled: true)
            }
            await self.store.refreshMidasCloudUsage(force: true)
            self.message = "Account connected. Add another account or choose your dollar estimate below."
        } catch {
            self.message = (error as? ManagedCodexAccountServiceError)?.userFacingMessage ?? error.localizedDescription
        }
    }

    private func saveAndRefresh() async {
        guard self.isRateValid else { return }
        self.isWorking = true
        defer { self.isWorking = false }
        self.enableTracking()
        self.settings.midasCodexEstimateMode = self.estimateMode
        if self.estimateMode == .custom, let rate = self.rate {
            self.settings.midasCloudUSDPerMillionTokens = rate
        }
        self.store.repriceMidasCloudUsage()
        self.message = "Refreshing connected accounts…"
        await self.store.refreshMidasCloudUsage(force: true)
        self.message = "Settings saved. Available estimates are included in your total; review account coverage above."
    }
}
