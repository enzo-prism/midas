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
    @State private var message: String?
    @State private var isWorking = false

    private var accounts: [CodexVisibleAccount] {
        self.settings.codexVisibleAccountProjection.visibleAccounts
    }

    private var rate: Double? {
        MidasSpendSetupRate.parse(self.rateText)
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
                .disabled(self.isWorking || self.rate == nil || self.accounts.isEmpty
                    || self.coordinator.hasConflictingManagedAccountOperationInFlight)
            }
        }
        .padding(24)
        .frame(width: 600, height: 650)
        .onAppear {
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
            Text("2. Choose how to estimate Codex dollars").font(.headline)
            Text(
                "OpenAI reports cloud token totals, but not the input, cached and output split "
                    + "needed for exact pricing. "
                    + "Choose a blended rate for a budgeting estimate, or leave it blank to track tokens only.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("USD per million tokens")
                TextField("Optional", text: self.$rateText).textFieldStyle(.roundedBorder).frame(width: 130)
            }
            if let rate = self.rate {
                if rate > 0 {
                    let snapshot = UsageStore.cloudTokenSnapshot(
                        accounts: self.accounts.compactMap { self.store.midasCloudAccounts[$0.id] },
                        rate: rate,
                        now: Date())
                    Text(snapshot.last30DaysCostUSD.map {
                        "Codex preview: " + $0.formatted(.currency(code: "USD")) + " over 30 days"
                    } ?? "Connect and refresh to preview your estimate.")
                    Text("A modeled estimate, not a bill. Missing histories are excluded.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Tokens only: Codex dollars will be excluded from the total.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Enter a number from 0 to 1,000, without a currency symbol.")
                    .font(.caption).foregroundStyle(.red)
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
        guard let rate = self.rate else { return }
        self.isWorking = true
        defer { self.isWorking = false }
        self.enableTracking()
        self.settings.midasCloudUSDPerMillionTokens = rate
        self.message = "Refreshing connected accounts…"
        await self.store.refreshMidasCloudUsage(force: true)
        self.message = "Settings saved. Available estimates are included in your total; review account coverage above."
    }
}
