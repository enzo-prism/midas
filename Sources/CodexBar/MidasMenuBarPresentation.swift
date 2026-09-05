import CodexBarCore
import Foundation

enum MidasMenuBarMode: String, CaseIterable, Identifiable {
    case ledger, focus, constellation, legacy

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .ledger: "Ledger"
        case .focus: "Focus"
        case .constellation: "Constellation"
        case .legacy: "Legacy"
        }
    }
}

/// Pure menu-bar projection; movement and state never stand in for measured data.
struct MidasMenuBarPresentation: Equatable {
    let title: String
    let accessibilityLabel: String
    let tooltip: String
    let isRefreshing: Bool
    let attention: Bool
    let isStale: Bool
    let isPartial: Bool
    let width: CGFloat

    init(
        title: String,
        accessibilityLabel: String,
        tooltip: String,
        isRefreshing: Bool,
        attention: Bool,
        isStale: Bool,
        width: CGFloat,
        isPartial: Bool = false)
    {
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.tooltip = tooltip
        self.isRefreshing = isRefreshing
        self.attention = attention
        self.isStale = isStale
        self.isPartial = isPartial
        self.width = width
    }

    init(
        mode: MidasMenuBarMode,
        presentations: [MidasProviderPresentation],
        focusProvider: UsageProvider,
        refreshingProviders: Set<UsageProvider>,
        hideSpend: Bool,
        now: Date = Date(),
        incidentDescriptions: [String] = [])
    {
        var seen = Set<UsageProvider>()
        let unique = presentations.filter { seen.insert($0.provider).inserted }
        let displayed: [MidasProviderPresentation]
        switch mode {
        case .focus:
            displayed = unique.filter { $0.provider == focusProvider }
        case .constellation:
            let priority: [UsageProvider] = [.codex, .cursor, .meta]
            let ordered = priority.compactMap { provider in unique.first { $0.provider == provider } }
                + unique.filter { !priority.contains($0.provider) }
            displayed = Array(ordered.prefix(3))
        case .ledger, .legacy:
            displayed = unique
        }
        self.isRefreshing = displayed.contains { refreshingProviders.contains($0.provider) }
        self.attention = !incidentDescriptions.isEmpty || displayed.contains { item in
            item.error != nil || Self.quota(item).map { $0.remainingPercent <= 10 } == true
                || item.metrics.contains { metric in
                    item.provider != .meta && metric.id != "cursor-models" && metric.remainingPercent <= 10
                }
        }
        let total = MidasTotalSpend(presentations: unique)
        self.isStale = displayed.contains { Self.stale($0, now: now, includeSpend: !hideSpend) }
        self.isPartial = mode == .ledger && !hideSpend && total.includedProviderCount > 0
            && total.excludedProviderCount > 0
        switch mode {
        case .ledger:
            self.width = 130
            if hideSpend {
                self.title = "••••"
            } else if total.totals.isEmpty {
                self.title = "—"
            } else {
                self.title = total.totals.count > 1 ? "≈\(total.totals.count) FX"
                    : "≈" + Self.compactMoney(total.totals[0].amount, currency: total.totals[0].currency)
            }
        case .focus:
            self.width = 120
            let item = displayed.first
            let quota = item.flatMap(Self.quota)
            let remaining = quota.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "—"
            self.title = "\(Self.initial(focusProvider)) \(remaining)"
        case .constellation:
            self.width = 190
            self.title = displayed.isEmpty ? "—" : displayed.map { item in
                let quota = Self.quota(item).map { "\(Int($0.remainingPercent.rounded()))%" } ?? "—"
                return "\(Self.initial(item.provider)) \(quota)"
            }.joined(separator: "  ")
        case .legacy:
            self.width = 24
            self.title = ""
        }
        var descriptions = displayed.map { Self.describe($0, hideSpend: hideSpend, now: now) }
        if displayed.isEmpty {
            descriptions.append(mode == .focus
                ? "\(ProviderDefaults.metadata[focusProvider]?.displayName ?? focusProvider.rawValue): unavailable"
                : "No enabled providers")
        }
        if mode == .constellation, unique.count > displayed.count {
            descriptions.append("\(unique.count - displayed.count) more providers in Midas")
        }
        if !hideSpend, mode == .ledger {
            let amounts = total.totals.map { "\($0.value) \($0.currency)" }.joined(separator: ", ")
            descriptions.insert(amounts.isEmpty ? "Estimated spend unavailable" : "Estimated spend: \(amounts)", at: 0)
            descriptions.append(total.periodText)
            descriptions.append(total.coverageText)
        }
        descriptions.append(contentsOf: incidentDescriptions)
        if self.isRefreshing { descriptions.append("Refreshing; displaying available recorded values") }
        self.accessibilityLabel = "Midas. " + descriptions.joined(separator: ". ")
        self.tooltip = descriptions.joined(separator: "\n")
    }

    private static func quota(_ item: MidasProviderPresentation) -> MidasQuotaMetric? {
        guard item.provider != .meta, let hero = item.hero, hero.remainingPercent.isFinite else { return nil }
        if item.provider == .codex, hero.id != "secondary" { return nil }
        if item.provider == .cursor, hero.id == "cursor-models" { return nil }
        return hero
    }

    private static func stale(_ item: MidasProviderPresentation, now: Date, includeSpend: Bool) -> Bool {
        let updated = [item.updatedAt, includeSpend ? item.spend?.updatedAt : nil].compactMap(\.self).min()
        return item.isStale || updated.map { now.timeIntervalSince($0) > 15 * 60 } == true
    }

    private static func describe(_ item: MidasProviderPresentation, hideSpend: Bool, now: Date) -> String {
        var text = item.name + ": "
        if let quota = Self.quota(item) {
            text += "\(quota.remainingPercent.formatted()) percent remaining, \(quota.title)"
            if let reset = quota.resetText { text += "; \(reset)" }
        } else {
            text += item.provider == .codex ? "weekly quota unavailable" : "quota unavailable"
            if let activity = item.activitySummary { text += "; \(activity)" }
        }
        for metric in item.metrics where item.provider != .meta && metric.id != "cursor-models"
            && metric.remainingPercent.isFinite
        {
            text += "; \(metric.title): \(metric.remainingPercent.formatted()) percent remaining"
        }
        if !hideSpend, let spend = item.spend {
            text += "; \(spend.title): \(spend.value) \(spend.currency), \(spend.period)"
        }
        if item.error != nil { text += "; refresh failed" }
        if Self.stale(item, now: now, includeSpend: !hideSpend) { text += "; last known data" }
        if let updated = [item.updatedAt, hideSpend ? nil : item.spend?.updatedAt].compactMap(\.self).min() {
            text += "; updated \(updated.formatted(date: .abbreviated, time: .shortened))"
        }
        return text
    }

    private static func initial(_ provider: UsageProvider) -> String {
        switch provider {
        case .codex: "C"
        case .cursor: "U"
        case .meta: "M"
        default: String((ProviderDefaults.metadata[provider]?.displayName ?? provider.rawValue).prefix(2))
        }
    }

    private static func compactMoney(_ amount: Double, currency: String) -> String {
        let magnitude: Double
        let suffix: String
        if amount >= 1_000_000_000 {
            magnitude = 1_000_000_000
            suffix = "B"
        } else if amount >= 1_000_000 {
            magnitude = 1_000_000
            suffix = "M"
        } else if amount >= 1000 {
            magnitude = 1000
            suffix = "k"
        } else {
            magnitude = 1
            suffix = ""
        }
        let number = (amount / magnitude).formatted(.number.precision(.fractionLength(0...(magnitude == 1 ? 2 : 1))))
        let symbol: String = switch currency {
        case "USD": "$"
        case "EUR": "€"
        case "GBP": "£"
        case "JPY": "¥"
        default: currency + " "
        }
        return symbol + number + suffix
    }
}
