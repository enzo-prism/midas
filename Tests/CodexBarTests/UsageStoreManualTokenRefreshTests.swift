import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

private actor TokenRefreshGate {
    private var didStart = false
    private var didFinish = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var calls: [(provider: UsageProvider, force: Bool)] = []

    func start(provider: UsageProvider, force: Bool) {
        self.didStart = true
        self.calls.append((provider, force))
        let waiters = self.startWaiters
        self.startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForStart() async {
        if self.didStart { return }
        await withCheckedContinuation { continuation in
            self.startWaiters.append(continuation)
        }
    }

    func waitForRelease() async {
        if self.released { return }
        await withCheckedContinuation { continuation in
            self.releaseWaiters.append(continuation)
        }
    }

    func release() {
        self.released = true
        let waiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func finish() {
        self.didFinish = true
    }

    func hasFinished() -> Bool {
        self.didFinish
    }
}

private actor CompletionFlag {
    private var completed = false

    func markCompleted() {
        self.completed = true
    }

    func isCompleted() -> Bool {
        self.completed
    }
}

private actor ProviderRefreshGate {
    private var started = 0
    private var released = 0
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        self.started += 1
        let startID = self.started
        self.resumeSatisfiedStartWaiters()
        if self.released < startID {
            await withCheckedContinuation { continuation in
                self.releaseWaiters.append(continuation)
            }
        }
    }

    func waitUntilStarted(count: Int) async {
        if self.started >= count { return }
        await withCheckedContinuation { continuation in
            self.startWaiters.append((count, continuation))
        }
    }

    func releaseNext() {
        self.released += 1
        if !self.releaseWaiters.isEmpty {
            self.releaseWaiters.removeFirst().resume()
        }
    }

    func startedCount() -> Int {
        self.started
    }

    private func resumeSatisfiedStartWaiters() {
        var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in self.startWaiters {
            if self.started >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        self.startWaiters = remaining
    }
}

private actor TokenRefreshRecorder {
    private(set) var calls: [(provider: UsageProvider, force: Bool)] = []

    func record(provider: UsageProvider, force: Bool) {
        self.calls.append((provider, force))
    }
}

@MainActor
@Suite(.serialized)
struct UsageStoreManualTokenRefreshTests {
    @Test
    func `manual refresh waits for token-cost refresh before completing`() async {
        let store = Self.makeStore()
        let gate = TokenRefreshGate()
        let completion = CompletionFlag()
        store._test_providerRefreshOverride = { _ in }
        store._test_tokenUsageRefreshOverride = { provider, force in
            await gate.start(provider: provider, force: force)
            await gate.waitForRelease()
            await gate.finish()
        }

        let task = Task { @MainActor in
            await store.refresh(forceTokenUsage: true)
            await completion.markCompleted()
        }

        await gate.waitForStart()
        #expect(await completion.isCompleted() == false)
        #expect(await gate.hasFinished() == false)

        await gate.release()
        await task.value

        #expect(await completion.isCompleted())
        #expect(await gate.hasFinished())
        #expect(await gate.calls.map(\.provider) == [.codex])
        #expect(await gate.calls.map(\.force) == [true])
    }

    @Test
    func `manual refresh drains scheduled token-cost refresh before forced pass`() async {
        let store = Self.makeStore()
        let scheduledGate = TokenRefreshGate()
        let forcedGate = TokenRefreshGate()
        let recorder = TokenRefreshRecorder()
        let completion = CompletionFlag()
        store._test_providerRefreshOverride = { _ in }
        store._test_tokenUsageRefreshOverride = { provider, force in
            await recorder.record(provider: provider, force: force)
            if force {
                await forcedGate.start(provider: provider, force: force)
                await forcedGate.waitForRelease()
                await forcedGate.finish()
            } else {
                await scheduledGate.start(provider: provider, force: force)
                await scheduledGate.waitForRelease()
                await scheduledGate.finish()
            }
        }

        await store.refresh(forceTokenUsage: false)
        await scheduledGate.waitForStart()

        let task = Task { @MainActor in
            await store.refresh(forceTokenUsage: true)
            await completion.markCompleted()
        }

        try? await Task.sleep(for: .milliseconds(50))
        #expect(await completion.isCompleted() == false)

        await scheduledGate.release()
        await forcedGate.waitForStart()
        #expect(await completion.isCompleted() == false)

        await forcedGate.release()
        await task.value

        #expect(await completion.isCompleted())
        #expect(await scheduledGate.hasFinished())
        #expect(await forcedGate.hasFinished())
        #expect(await recorder.calls.map(\.provider) == [.codex, .codex])
        #expect(await recorder.calls.map(\.force) == [false, true])
    }

    @Test
    func `regular refresh schedules token-cost refresh without waiting`() async {
        let store = Self.makeStore()
        let gate = TokenRefreshGate()
        store._test_providerRefreshOverride = { _ in }
        store._test_tokenUsageRefreshOverride = { provider, force in
            await gate.start(provider: provider, force: force)
            await gate.waitForRelease()
            await gate.finish()
        }

        await store.refresh(forceTokenUsage: false)
        #expect(await gate.hasFinished() == false)

        await gate.release()
        try? await Task.sleep(for: .milliseconds(50))
        let calls = await gate.calls
        if !calls.isEmpty {
            #expect(calls.map(\.provider) == [.codex])
            #expect(calls.map(\.force) == [false])
            #expect(await gate.hasFinished())
        }
    }

    @Test
    func `manual forced refresh queues behind active background refresh`() async {
        let store = Self.makeStore()
        let providerGate = ProviderRefreshGate()
        let completion = CompletionFlag()
        store._test_providerRefreshOverride = { _ in
            await providerGate.block()
        }
        defer { store._test_providerRefreshOverride = nil }
        store._test_tokenUsageRefreshOverride = { _, _ in }
        defer { store._test_tokenUsageRefreshOverride = nil }

        let backgroundTask = Task { @MainActor in
            await store.refresh(forceTokenUsage: false)
        }
        await providerGate.waitUntilStarted(count: 1)

        let forcedTask = Task { @MainActor in
            await store.refresh(forceTokenUsage: true)
            await completion.markCompleted()
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await completion.isCompleted() == false)
        #expect(await providerGate.startedCount() == 1)

        await providerGate.releaseNext()
        await providerGate.waitUntilStarted(count: 2)
        #expect(await completion.isCompleted() == false)

        await providerGate.releaseNext()
        await backgroundTask.value
        await forcedTask.value

        #expect(await completion.isCompleted())
        #expect(await providerGate.startedCount() == 2)
    }

    private static func makeStore() -> UsageStore {
        let suite = "UsageStoreManualTokenRefreshTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        settings.openAIWebAccessEnabled = false
        settings.codexCookieSource = .off
        settings.providerDetectionCompleted = true

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }

        return UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }
}
