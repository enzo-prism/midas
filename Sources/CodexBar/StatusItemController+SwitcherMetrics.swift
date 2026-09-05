import CodexBarCore

extension StatusItemController {
    nonisolated static func switcherWeeklyMetricPercent(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?,
        showUsed: Bool) -> Double?
    {
        if provider == .codex {
            return snapshot.flatMap {
                IconRemainingResolver.resolvedRemaining(snapshot: $0, style: .codex).primary
            }
        }
        let window = snapshot?.switcherWeeklyWindow(for: provider, showUsed: showUsed)
        guard let window else { return nil }
        return showUsed ? window.usedPercent : window.remainingPercent
    }
}
