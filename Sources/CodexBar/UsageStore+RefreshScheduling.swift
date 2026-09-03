import CodexBarCore
import Foundation

/// Refresh scheduling: background timers, the token-usage refresh sequence, and the queue that
/// defers a manual forced refresh until an in-flight background refresh finishes. Split out of
/// UsageStore.swift to keep that core file within its length budget.
extension UsageStore {
    func startTimer() {
        self.timerTask?.cancel()
        guard let wait = self.settings.refreshFrequency.seconds else { return }

        // Background poller so the menu stays responsive; canceled when settings change or store deallocates.
        self.timerTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(wait))
                await self?.refresh()
            }
        }
    }

    func startTokenTimer() {
        self.tokenTimerTask?.cancel()
        let wait = self.tokenFetchTTL
        self.tokenTimerTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(wait))
                await self?.scheduleTokenRefresh(force: false)
            }
        }
    }

    func scheduleTokenRefresh(force: Bool) {
        if force {
            self.tokenRefreshSequenceTask?.cancel()
            self.tokenRefreshSequenceTask = nil
        } else if self.tokenRefreshSequenceTask != nil {
            return
        }

        self.tokenRefreshSequenceTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor [weak self] in
                    self?.tokenRefreshSequenceTask = nil
                }
            }
            await self.refreshTokenUsageSequence(force: force)
        }
    }

    func refreshTokenUsageSequenceNow(force: Bool) async {
        if force, let existing = self.tokenRefreshSequenceTask {
            existing.cancel()
            await existing.value
            self.tokenRefreshSequenceTask = nil
        }

        await self.refreshTokenUsageSequence(force: force)
    }

    func refreshTokenUsageSequence(force: Bool) async {
        let providers = self.enabledProvidersForBackgroundWork()
        for provider in providers {
            if Task.isCancelled { break }
            await self.refreshTokenUsage(provider, force: force)
        }
        // Prior-period spend rides along with the token sequence so the Overview
        // comparison is ready without extra timers; each provider refetches at
        // most twice a day behind its own TTL.
        await self.refreshPriorSpendSequence(providers: providers, force: force)
        self.scheduleMemoryPressureRelief()
    }

    func enqueueForcedRefreshAfterCurrentRefresh() async {
        self.pendingForcedRefreshAfterCurrentRefresh = true
        await withCheckedContinuation { continuation in
            self.pendingForcedRefreshWaiters.append(continuation)
        }
    }

    func drainPendingForcedRefreshes() async {
        guard self.pendingForcedRefreshAfterCurrentRefresh else {
            self.completePendingForcedRefreshWaiters()
            return
        }
        self.pendingForcedRefreshAfterCurrentRefresh = false
        await self.runRefresh(
            forceTokenUsage: true,
            startupConnectivityRetryAttempt: nil,
            coalesceProviderRefreshesOverride: false)
        self.completePendingForcedRefreshWaiters()
    }

    func completePendingForcedRefreshWaiters() {
        let waiters = self.pendingForcedRefreshWaiters
        self.pendingForcedRefreshWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
