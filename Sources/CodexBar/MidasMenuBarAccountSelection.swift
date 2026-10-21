import CodexBarCore

/// The menu-bar quota is account-owned; its spend remains the provider's aggregate history.
enum MidasMenuBarAccountSelection {
    static func selectedAccount(
        accounts: [MidasAccountPresentation],
        selectedAccountID: String?) -> MidasAccountPresentation?
    {
        if let selectedAccountID {
            return accounts.first { $0.id == selectedAccountID }
        }
        return accounts.first { $0.isPrimary } ?? accounts.first
    }

    static func project(
        providerPresentation: MidasProviderPresentation,
        accounts: [MidasAccountPresentation],
        selectedAccountID: String?,
        hidePersonalInfo: Bool) -> MidasProviderPresentation
    {
        let provider = providerPresentation.provider
        let matchingAccounts = accounts.filter { $0.presentation.provider == provider }
        guard selectedAccountID != nil || !matchingAccounts.isEmpty else { return providerPresentation }
        let selected = self.selectedAccount(accounts: matchingAccounts, selectedAccountID: selectedAccountID)
        let quota = selected?.presentation
        let label: String = if selected == nil {
            "Selected account unavailable"
        } else if hidePersonalInfo {
            "Account \((matchingAccounts.firstIndex { $0.id == selected?.id } ?? 0) + 1)"
        } else {
            selected?.displayName ?? ((quota?.account.isEmpty == false) ? quota?.account : nil) ?? "Account"
        }
        return MidasProviderPresentation(
            provider: provider,
            name: "\(providerPresentation.name) (\(label))",
            account: hidePersonalInfo ? "" : quota?.account ?? "",
            plan: quota?.plan,
            hero: quota?.hero,
            metrics: quota?.metrics ?? [],
            activityMetrics: quota?.activityMetrics ?? [],
            orbitQuota: quota?.orbitQuota,
            resetCreditsText: quota?.resetCreditsText,
            resetCreditsHelp: quota?.resetCreditsHelp,
            freshness: quota?.freshness ?? "Selected account unavailable",
            error: quota?.error ?? (selected == nil ? "Selected account unavailable" : nil),
            placeholder: quota?.placeholder ?? "Usage unavailable",
            notes: quota?.notes ?? [],
            financialSummary: quota?.financialSummary,
            financialLabel: quota?.financialLabel,
            activitySummary: providerPresentation.activitySummary,
            cloudUsage: providerPresentation.cloudUsage,
            spend: providerPresentation.spend,
            spendUnavailableReason: providerPresentation.spendUnavailableReason,
            dgxSpark: providerPresentation.dgxSpark,
            isRefreshing: quota?.isRefreshing ?? providerPresentation.isRefreshing,
            isStale: quota?.isStale ?? true,
            updatedAt: quota?.updatedAt)
    }
}
