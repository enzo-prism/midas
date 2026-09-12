import CodexBarCore
import Foundation

enum MidasOnboardingStep: Int, CaseIterable {
    case services
    case accounts
    case overview

    var label: String {
        switch self {
        case .services: "Services"
        case .accounts: "Accounts"
        case .overview: "Overview"
        }
    }
}

enum MidasOnboarding {
    static let providers: [UsageProvider] = [.codex, .cursor, .meta]

    static func canContinue(selected: Set<UsageProvider>, mode: MidasCodexEstimateMode, rate: Double?) -> Bool {
        guard !selected.isEmpty else { return false }
        guard selected.contains(.codex), mode == .custom else { return true }
        guard let rate else { return false }
        return rate.isFinite && rate > 0 && rate <= 1000
    }

    static func total(_ values: [Double?]) -> Double? {
        let known = values.compactMap(\.self).filter { $0.isFinite && $0 >= 0 }
        guard !known.isEmpty else { return nil }
        let total = known.reduce(0, +)
        return total.isFinite ? total : nil
    }

    static func availability(hasUsage: Bool, isRefreshing: Bool, hasError: Bool, isLocal: Bool) -> String {
        if hasError { return hasUsage ? "Saved usage available · refresh needed" : "Usage unavailable" }
        if hasUsage { return isLocal ? "Local usage available" : "Usage available" }
        if isRefreshing { return "Checking usage…" }
        return isLocal ? "No activity on this Mac yet" : "Connect to see usage"
    }
}
