import CodexBarCore
import Foundation

extension UsageStore {
    nonisolated static let cursorGrokBotWindowID = "cursor-grok-bot"
    nonisolated static let cursorGrokBotLastKnownSuffix = " (last known)"

    /// Keeps the last Grok Bot reading through a refresh where Cursor did not return it, until that week resets.
    ///
    /// Only an unavailable reading is replaced, never a fresh one or a plan without Grok Bot. The previous
    /// reading must belong to the same Cursor account and still be inside its weekly window; trials, which have
    /// no weekly reset to bound them, are not carried forward.
    nonisolated static func retainingCursorGrokBot(
        _ current: UsageSnapshot,
        previous: UsageSnapshot?,
        now: Date = Date()) -> UsageSnapshot
    {
        let id = Self.cursorGrokBotWindowID
        guard var windows = current.extraRateWindows,
              let index = windows.firstIndex(where: { $0.id == id }),
              !windows[index].usageKnown,
              let last = previous?.extraRateWindows?.first(where: { $0.id == id && $0.usageKnown }),
              let resetsAt = last.window.resetsAt, resetsAt > now,
              let account = Self.cursorAccountKey(current),
              account == Self.cursorAccountKey(previous)
        else { return current }
        let title = last.title.hasSuffix(Self.cursorGrokBotLastKnownSuffix)
            ? last.title : last.title + Self.cursorGrokBotLastKnownSuffix
        windows[index] = NamedRateWindow(id: id, title: title, window: last.window)
        return current.withExtraRateWindows(windows)
    }

    private nonisolated static func cursorAccountKey(_ snapshot: UsageSnapshot?) -> String? {
        let email = snapshot?.identity?.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return email.flatMap { $0.isEmpty ? nil : $0 }
    }
}
