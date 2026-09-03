import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
struct MetaAPIKeyUsageTrackerTests {
    @Test
    func `fingerprint redacts raw key`() {
        MetaAPIKeyUsageTracker.resetForTesting()

        #expect(MetaAPIKeyUsageTracker.fingerprint(for: nil) == MetaAPIKeyUsageTracker.localKeyFingerprint)
        #expect(MetaAPIKeyUsageTracker.fingerprint(for: "") == MetaAPIKeyUsageTracker.localKeyFingerprint)
        #expect(MetaAPIKeyUsageTracker.fingerprint(for: "   ") == MetaAPIKeyUsageTracker.localKeyFingerprint)

        let fingerprint = MetaAPIKeyUsageTracker.fingerprint(for: "metask_abcdef123456")
        #expect(!fingerprint.contains("metask_abcdef123456"))
        #expect(fingerprint.hasSuffix("3456"))
        #expect(fingerprint == MetaAPIKeyUsageTracker.fingerprint(for: "metask_abcdef123456"))
    }

    @Test
    func `recordSuccess accumulates requests and overwrites token totals`() {
        MetaAPIKeyUsageTracker.resetForTesting()
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let second = first.addingTimeInterval(60)

        MetaAPIKeyUsageTracker.recordSuccess(
            apiKey: "metask_key-one",
            usage: MetaTokenUsage(
                inputTokens: 100,
                outputTokens: 50,
                reasoningTokens: 10,
                cachedTokens: 5,
                requests: 2),
            requests: 2,
            at: first)
        MetaAPIKeyUsageTracker.recordSuccess(
            apiKey: "metask_key-one",
            usage: MetaTokenUsage(inputTokens: 300, outputTokens: 60),
            requests: 3,
            at: second)

        let entry = MetaAPIKeyUsageTracker.entry(for: "metask_key-one")
        #expect(entry?.requests == 5)
        // Token totals reflect the latest windowed snapshot; summing them
        // across overlapping fetch windows would double-count.
        #expect(entry?.inputTokens == 300)
        #expect(entry?.outputTokens == 60)
        #expect(entry?.totalTokens == 360)
        #expect(entry?.errorCount == 0)
        #expect(entry?.lastError == nil)
        #expect(entry?.firstSeenAt == first)
        #expect(entry?.lastSeenAt == second)
    }

    @Test
    func `recordFailure tracks errors and timestamps without clearing tokens`() {
        MetaAPIKeyUsageTracker.resetForTesting()
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let second = first.addingTimeInterval(120)

        MetaAPIKeyUsageTracker.recordSuccess(
            apiKey: "metask_key-two",
            usage: MetaTokenUsage(inputTokens: 40, outputTokens: 20),
            requests: 1,
            at: first)
        MetaAPIKeyUsageTracker.recordFailure(
            apiKey: "metask_key-two",
            error: MetaUsageError.noLocalData,
            at: second)

        let entry = MetaAPIKeyUsageTracker.entry(for: "metask_key-two")
        #expect(entry?.requests == 1)
        #expect(entry?.inputTokens == 40)
        #expect(entry?.errorCount == 1)
        #expect(entry?.lastError == MetaUsageError.noLocalData.localizedDescription)
        #expect(entry?.firstSeenAt == first)
        #expect(entry?.lastSeenAt == second)
    }

    @Test
    func `entries are isolated per key fingerprint`() {
        MetaAPIKeyUsageTracker.resetForTesting()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        MetaAPIKeyUsageTracker.recordSuccess(
            apiKey: "metask_alpha",
            usage: MetaTokenUsage(inputTokens: 10, outputTokens: 5),
            requests: 1,
            at: now)
        MetaAPIKeyUsageTracker.recordFailure(
            apiKey: "metask_beta1",
            error: MetaUsageError.noLocalData,
            at: now)

        #expect(MetaAPIKeyUsageTracker.entry(for: "metask_alpha")?.requests == 1)
        #expect(MetaAPIKeyUsageTracker.entry(for: "metask_alpha")?.errorCount == 0)
        #expect(MetaAPIKeyUsageTracker.entry(for: "metask_beta1")?.requests == 0)
        #expect(MetaAPIKeyUsageTracker.entry(for: "metask_beta1")?.errorCount == 1)
        #expect(MetaAPIKeyUsageTracker.allEntries().count == 2)
    }

    @Test
    func `meta provider implementation is registered`() throws {
        let implementation = try #require(ProviderCatalog.implementation(for: .meta))
        #expect(implementation.id == .meta)
    }
}
