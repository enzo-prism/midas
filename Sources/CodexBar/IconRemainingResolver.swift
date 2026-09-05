import CodexBarCore

enum IconRemainingResolver {
    private static func codexProjection(snapshot: UsageSnapshot) -> CodexConsumerProjection {
        CodexConsumerProjection.make(
            surface: .menuBar,
            context: CodexConsumerProjection.Context(
                snapshot: snapshot,
                rawUsageError: nil,
                liveCredits: nil,
                rawCreditsError: nil,
                liveDashboard: nil,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false,
                now: snapshot.updatedAt))
    }

    static func resolvedWindows(
        snapshot: UsageSnapshot,
        style: IconStyle)
        -> (primary: RateWindow?, secondary: RateWindow?)
    {
        if style == .perplexity {
            let windows = snapshot.orderedPerplexityDisplayWindows()
            return (
                primary: windows.first,
                secondary: windows.dropFirst().first)
        }
        if style == .antigravity {
            let windows = [snapshot.primary, snapshot.secondary, snapshot.tertiary].compactMap(\.self)
            return (
                primary: windows.first,
                secondary: windows.dropFirst().first)
        }
        if style == .codex {
            // Midas previews only the weekly quota; never substitute session usage or credits.
            return (primary: self.codexProjection(snapshot: snapshot).rateWindow(for: .weekly), secondary: nil)
        }
        return (
            primary: snapshot.primary,
            secondary: snapshot.secondary)
    }

    static func resolvedRemaining(
        snapshot: UsageSnapshot,
        style: IconStyle)
        -> (primary: Double?, secondary: Double?)
    {
        if style == .perplexity {
            let windows = snapshot.orderedPerplexityDisplayWindows()
            return (
                primary: windows.first?.remainingPercent,
                secondary: windows.dropFirst().first?.remainingPercent)
        }
        if style == .antigravity {
            let windows = [snapshot.primary, snapshot.secondary, snapshot.tertiary].compactMap(\.self)
            return (
                primary: windows.first?.remainingPercent,
                secondary: windows.dropFirst().first?.remainingPercent)
        }
        if style == .codex {
            let windows = self.resolvedWindows(snapshot: snapshot, style: style)
            return (primary: windows.primary?.remainingPercent, secondary: nil)
        }
        return (
            primary: snapshot.primary?.remainingPercent,
            secondary: snapshot.secondary?.remainingPercent)
    }

    static func resolvedPercents(
        snapshot: UsageSnapshot,
        style: IconStyle,
        showUsed: Bool)
        -> (primary: Double?, secondary: Double?)
    {
        let windows = Self.resolvedWindows(snapshot: snapshot, style: style)
        if style == .codex {
            return (primary: windows.primary?.remainingPercent, secondary: nil)
        }
        return (
            primary: showUsed ? windows.primary?.usedPercent : windows.primary?.remainingPercent,
            secondary: showUsed ? windows.secondary?.usedPercent : windows.secondary?.remainingPercent)
    }
}
