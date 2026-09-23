import AppIntents
import CodexBarCore
import Foundation

/// Siri/Spotlight entry points for CodexBar.
///
/// Donated from the widget extension so the phrases reuse the same snapshot,
/// selection, and intent types as the widgets. All APIs used here predate
/// macOS 13, so no availability gates are needed for the macOS 14 floor.
struct CodexBarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CheckUsageIntent(),
            phrases: [
                "Check usage in \(.applicationName)",
                "Check \(.applicationName) usage",
            ],
            shortTitle: "Check Usage",
            systemImageName: "chart.bar")
        AppShortcut(
            intent: SwitchWidgetProviderIntent(),
            phrases: [
                "Switch provider in \(.applicationName)",
                "Switch \(.applicationName) provider",
            ],
            shortTitle: "Switch Provider",
            systemImageName: "arrow.left.arrow.right")
        AppShortcut(
            intent: OpenSpendPanelIntent(),
            phrases: [
                "Open spend panel in \(.applicationName)",
                "Show \(.applicationName) spend",
            ],
            shortTitle: "Open Spend Panel",
            systemImageName: "dollarsign.circle")
    }
}

/// Speaks a one-line usage summary for a provider from the shared snapshot.
struct CheckUsageIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Usage"
    static let description = IntentDescription("Check current AI provider usage.")

    @Parameter(title: "Provider", default: .codex)
    var provider: ProviderChoice

    static var parameterSummary: some ParameterSummary {
        Summary("Check \(\.$provider) usage")
    }

    init() {
        self.provider = .codex
    }

    init(provider: ProviderChoice) {
        self.provider = provider
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let summary = Self.summary(
            snapshot: WidgetSnapshotStore.load(),
            provider: self.provider.provider)
        return .result(dialog: "\(summary)")
    }

    /// Pure summary builder, kept free of AppIntents types for unit tests.
    static func summary(snapshot: WidgetSnapshot?, provider: UsageProvider) -> String {
        let name = ProviderDefaults.metadata[provider]?.displayName ?? provider.rawValue.capitalized
        guard let entry = snapshot?.entries.first(where: { $0.provider == provider }) else {
            return "No \(name) usage data yet. Open CodexBar to refresh."
        }
        var parts: [String] = []
        for row in WidgetUsageRow.rows(for: entry) {
            if let left = row.percentLeft {
                parts.append("\(row.title) \(Int(left.rounded())) percent left")
            }
        }
        if let credits = entry.creditsRemaining {
            parts.append("\(WidgetFormat.credits(credits)) credits left")
        }
        if let token = entry.tokenUsage {
            if let cost = token.sessionCostUSD {
                parts.append("\(token.sessionLabel) cost \(WidgetFormat.currency(cost, code: token.currencyCode))")
            }
            if let cost30 = token.last30DaysCostUSD {
                parts.append("\(token.last30DaysLabel) cost \(WidgetFormat.currency(cost30, code: token.currencyCode))")
            }
        }
        guard parts.isEmpty == false else {
            return "\(name) usage is unavailable right now."
        }
        return "\(name): \(parts.joined(separator: ", "))."
    }
}

/// Foregrounds CodexBar and speaks the 30-day spend totals.
///
/// Uses `openAppWhenRun` instead of NSWorkspace so the intent stays legal
/// under the extension's APPLICATION_EXTENSION_API_ONLY build setting.
struct OpenSpendPanelIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Spend Panel"
    static let description = IntentDescription("Open CodexBar to review spend.")

    static var openAppWhenRun: Bool {
        true
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let summary = Self.spendSummary(snapshot: WidgetSnapshotStore.load())
        return .result(dialog: "\(summary)")
    }

    /// Pure spend builder, kept free of AppIntents types for unit tests.
    static func spendSummary(snapshot: WidgetSnapshot?) -> String {
        guard let snapshot, snapshot.entries.isEmpty == false else {
            return "No spend data yet. Open CodexBar to refresh."
        }
        let costs = snapshot.entries.compactMap { $0.tokenUsage?.last30DaysCostUSD }
        guard costs.isEmpty == false else {
            return "No spend data yet. Open CodexBar to refresh."
        }
        let total = costs.reduce(0, +)
        let code = snapshot.entries.compactMap { $0.tokenUsage?.currencyCode }.first ?? "USD"
        let formatted = WidgetFormat.currency(total, code: code)
        if costs.count == 1, let only = snapshot.entries.first(where: { $0.tokenUsage?.last30DaysCostUSD != nil }) {
            let name = ProviderDefaults.metadata[only.provider]?.displayName ?? only.provider.rawValue.capitalized
            return "\(name) 30-day spend is \(formatted)."
        }
        return "Total 30-day spend is \(formatted) across \(costs.count) providers."
    }
}
