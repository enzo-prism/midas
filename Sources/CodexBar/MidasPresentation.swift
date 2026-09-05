import CodexBarCore
import Foundation
import Observation

@MainActor
@Observable
final class MidasNavigationState {
    var provider: UsageProvider?
}

struct MidasActions {
    let refresh: () -> Void
    let settings: () -> Void
    let accounts: (UsageProvider) -> Void
    let openUsage: (UsageProvider?) -> Void
    let legacyMenu: () -> Void
    let quit: () -> Void
}

struct MidasQuotaMetric: Identifiable {
    let id: String
    let title: String
    let remainingPercent: Double
    let resetText: String?
    let helpText: String?

    var valueText: String {
        "\(Int(self.remainingPercent.rounded()))% left"
    }

    var isExhausted: Bool {
        self.remainingPercent <= 0
    }

    static func make(_ metric: UsageMenuCardView.Model.Metric) -> Self? {
        guard metric.statusText == nil, metric.percent.isFinite else { return nil }
        let remaining = metric.percentStyle == .left ? metric.percent : 100 - metric.percent
        return Self(
            id: metric.id,
            title: metric.title,
            remainingPercent: min(100, max(0, remaining)),
            resetText: metric.resetText,
            helpText: metric.helpText)
    }
}

/// A value and its accounting meaning travel together, so the UI cannot imply a billing receipt.
struct MidasSpendPresentation {
    let title: String
    let value: String
    let period: String
    let detail: String
    let updatedAt: Date
    let amount: Double
    let currency: String
    let secondaryValue: String?
    let secondaryLabel: String?
    var isEstimate: Bool = false

    static func make(provider: UsageProvider, snapshot: CostUsageTokenSnapshot?) -> Self? {
        guard let snapshot else { return nil }
        let recorded = Self.valid(snapshot.last30DaysCostUSD)
        let metered = Self.valid(snapshot.meteredCostUSD)
        guard let amount = recorded ?? metered else { return nil }
        let onlyMetered = recorded == nil && metered != nil
        let provenance = onlyMetered ? CostProvenance.vendorMetered : CostProvenance.forWindow(
            snapshot: snapshot.costProvenance, hasWindowCosts: true, includesMetered: false)
        let title: String
        let detail: String
        switch provenance {
        case .listPriceEstimate:
            title = "Token spend (API rates)"
            detail = provider == .meta
                ? "Model-tier price estimate from local Muse activity; not a bill."
                : "API-rate value of recorded usage; an estimate, not a bill."
        case .vendorMetered:
            title = "Provider-metered usage"
            detail = "Consumption reported by the provider; plan deductions are not necessarily cash charges."
        case .mixed:
            title = "Recorded usage value"
            detail = "Mixed provider metering and API-rate estimates; not billed spend."
        case .unknown:
            title = "Recorded usage value"
            detail = "The source does not establish pricing provenance. This value is not a billing receipt."
        }
        let secondaryAmount: Double?
        let secondaryLabel: String?
        if provider == .meta, let equivalent = Self.valid(snapshot.last30DaysAPIEquivalentCostUSD) {
            secondaryAmount = equivalent
            secondaryLabel = "Standard API-equivalent value"
        } else if !onlyMetered, let metered {
            secondaryAmount = metered
            secondaryLabel = "Provider-metered consumption"
        } else {
            secondaryAmount = nil
            secondaryLabel = nil
        }
        let period = snapshot.historyLabel ?? (snapshot.historyDays > 0
            ? "Last \(snapshot.historyDays) days" : "Reported period")
        return Self(
            title: title,
            value: amount.formatted(.currency(code: snapshot.currencyCode)),
            period: period,
            detail: detail,
            updatedAt: snapshot.updatedAt,
            amount: amount,
            currency: snapshot.currencyCode,
            secondaryValue: secondaryAmount?.formatted(.currency(code: snapshot.currencyCode)),
            secondaryLabel: secondaryLabel,
            isEstimate: provenance == .listPriceEstimate)
    }

    private static func valid(_ amount: Double?) -> Double? {
        guard let amount, amount.isFinite, amount >= 0 else { return nil }
        return amount
    }
}

/// Read-only adaptation of the existing, account-sanitized card and semantic quota projection.
struct MidasProviderPresentation {
    let provider: UsageProvider
    let name: String
    let account: String
    let plan: String?
    let hero: MidasQuotaMetric?
    let metrics: [MidasQuotaMetric]
    let resetCreditsText: String?
    let resetCreditsHelp: String?
    let freshness: String
    let error: String?
    let placeholder: String?
    let notes: [String]
    let financialSummary: String?
    let financialLabel: String?
    var activitySummary: String?
    var spend: MidasSpendPresentation?
    let isRefreshing: Bool
    let isStale: Bool
    let updatedAt: Date?

    var summary: String {
        if let hero { return "\(hero.valueText) · \(hero.title)" }
        if self.provider == .codex { return "Weekly usage unavailable" }
        if self.provider == .cursor, self.financialSummary == nil,
           let mix = self.notes.first(where: { $0.hasPrefix("Model spend mix:") })
        {
            return mix
        }
        return self.activitySummary ?? self.financialSummary ?? self.placeholder ?? "Usage unavailable"
    }

    // Adapter contract keeps the existing sources explicit at the controller boundary.
    // swiftlint:disable:next function_parameter_count
    static func make(
        provider: UsageProvider,
        card: UsageMenuCardView.Model?,
        snapshot: UsageSnapshot?,
        tokenSnapshot: CostUsageTokenSnapshot?,
        isRefreshing: Bool,
        isStale: Bool) -> Self
    {
        var quotaMetrics = card?.metrics.filter { provider != .cursor || $0.id != "cursor-models" }
            .compactMap(MidasQuotaMetric.make) ?? []
        if provider == .codex, let snapshot {
            let projection = CodexConsumerProjection.make(
                surface: .menuBar,
                context: .init(
                    snapshot: snapshot,
                    rawUsageError: nil,
                    liveCredits: nil,
                    rawCreditsError: nil,
                    liveDashboard: nil,
                    rawDashboardError: nil,
                    dashboardAttachmentAuthorized: false,
                    dashboardRequiresLogin: false,
                    now: snapshot.updatedAt))
            quotaMetrics.removeAll { $0.id == "primary" }
            if let session = projection.rateWindow(for: .session), session.usedPercent.isFinite {
                quotaMetrics.insert(MidasQuotaMetric(
                    id: "primary",
                    title: "Session",
                    remainingPercent: min(100, max(0, session.remainingPercent)),
                    resetText: card?.metrics.first(where: { $0.id == "primary" })?.resetText ?? session.resetsAt.map {
                        "Resets \(UsageFormatter.resetCountdownDescription(from: $0, now: Date()))"
                    } ?? session.resetDescription,
                    helpText: session.resetsAt?.formatted(date: .complete, time: .shortened)), at: 0)
            }
        }
        let hero: MidasQuotaMetric?
        if provider == .codex,
           let snapshot,
           let weekly = IconRemainingResolver.resolvedWindows(snapshot: snapshot, style: .codex).primary,
           weekly.usedPercent.isFinite
        {
            let resetText = card?.metrics.first(where: { $0.id == "secondary" })?.resetText ?? weekly.resetsAt.map {
                "Resets \(UsageFormatter.resetCountdownDescription(from: $0, now: Date()))"
            } ?? weekly.resetDescription
            hero = MidasQuotaMetric(
                id: "secondary",
                title: "This week",
                remainingPercent: min(100, max(0, weekly.remainingPercent)),
                resetText: resetText,
                helpText: weekly.resetsAt?.formatted(date: .complete, time: .shortened))
        } else {
            hero = provider == .codex ? nil : quotaMetrics.first
        }
        // A provider's setup hint is not a measured balance or usage summary.
        let creditsText = card?.creditsText == ProviderDefaults.metadata[provider]?.creditsHint
            ? nil : card?.creditsText
        let financialSummary = card?.providerCost?.spendLine ?? creditsText
        let resetCredits = card?.metrics.first { $0.id == "codex-reset-credits" }
        let unknownQuotaNotes: [String] = provider == .codex ? (card?.metrics.compactMap { metric in
            guard metric.id != "codex-reset-credits", let status = metric.statusText else { return nil }
            return "\(metric.title): \(status)"
        } ?? []) : []
        let providerNotes = Self.supplementalNotes(provider: provider, card: card)
        let error: String? = card?.subtitleStyle == .error ? card?.subtitleText : nil
        let freshness: String = if isRefreshing {
            snapshot == nil ? "Refreshing…" : "Refreshing · showing last update"
        } else if isStale {
            "Last known usage · refresh needed"
        } else {
            card?.subtitleText ?? "Waiting for first update"
        }
        return Self(
            provider: provider,
            name: card?.providerName ?? ProviderDefaults.metadata[provider]?.displayName ?? provider.rawValue,
            account: card?.email ?? "",
            plan: card?.planText,
            hero: hero,
            metrics: quotaMetrics.filter { $0.id != hero?.id },
            resetCreditsText: resetCredits?.statusText,
            resetCreditsHelp: resetCredits?.helpText,
            freshness: freshness,
            error: error,
            placeholder: provider == .codex ? "Weekly usage unavailable" : card?.placeholder,
            notes: (card?.usageNotes ?? []) + unknownQuotaNotes + providerNotes,
            financialSummary: financialSummary,
            financialLabel: card?.providerCost?.title ?? (creditsText == nil ? nil : "Credits"),
            activitySummary: provider == .meta
                ? Self.activitySummary(tokenSnapshot) ?? Self.metaSnapshotActivity(snapshot) : nil,
            spend: MidasSpendPresentation.make(provider: provider, snapshot: tokenSnapshot),
            isRefreshing: isRefreshing,
            isStale: isStale,
            updatedAt: snapshot?.updatedAt)
    }

    private static func supplementalNotes(provider: UsageProvider, card: UsageMenuCardView.Model?) -> [String] {
        guard provider == .cursor else { return [] }
        var notes = card?.metrics.compactMap { metric in
            metric.detailText.map { "\(metric.title): \($0)" }
        } ?? []
        if let mix = card?.metrics.first(where: { $0.id == "cursor-models" }),
           mix.statusText == nil, mix.percent.isFinite
        {
            let share = min(100, max(0, mix.percentStyle == .used ? mix.percent : 100 - mix.percent))
            let cursor = Int(share.rounded())
            notes.append("Model spend mix: \(cursor)% Cursor Models · \(100 - cursor)% Other Models")
        }
        return notes
    }

    private static func activitySummary(_ snapshot: CostUsageTokenSnapshot?) -> String? {
        guard let snapshot else { return nil }
        if let tokens = snapshot.last30DaysTokens, tokens >= 0 {
            let period = snapshot.historyLabel ?? (snapshot.historyDays > 0
                ? "Last \(snapshot.historyDays) days" : "Reported period")
            return "\(UsageFormatter.tokenCountString(tokens)) tokens · \(period)"
        }
        if let tokens = snapshot.sessionTokens, tokens >= 0 {
            return "\(UsageFormatter.tokenCountString(tokens)) tokens · Session"
        }
        return nil
    }

    /// Meta's quota-shaped legacy windows carry token descriptions, never percentages.
    private static func metaSnapshotActivity(_ snapshot: UsageSnapshot?) -> String? {
        if let text = snapshot?.secondary?.resetDescription, text.hasSuffix(" last 7d") {
            return "\(text.dropLast(" last 7d".count)) tokens · Last 7 days"
        }
        if let text = snapshot?.primary?.resetDescription, text.hasSuffix(" today") {
            return "\(text.dropLast(" today".count)) tokens · Today"
        }
        return nil
    }
}
