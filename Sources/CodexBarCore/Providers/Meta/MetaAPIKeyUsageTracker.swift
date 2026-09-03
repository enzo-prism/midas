import Foundation

/// Observed usage for one Meta (Muse Code) API key.
///
/// The Meta provider's usage source of truth is the local Muse session log;
/// the optional `META_API_KEY` is reserved for Meta Model API calls. Entries are
/// keyed by fingerprint (never the raw key) and record how often the key was
/// observed in use, the latest windowed token totals when available, and any
/// errors seen, with first/last-seen timestamps.
public struct MetaAPIKeyUsageEntry: Sendable, Equatable {
    public let keyFingerprint: String
    public let requests: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int
    public let cachedTokens: Int
    public let errorCount: Int
    public let lastError: String?
    public let firstSeenAt: Date
    public let lastSeenAt: Date

    public init(
        keyFingerprint: String,
        requests: Int,
        inputTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int,
        cachedTokens: Int,
        errorCount: Int,
        lastError: String?,
        firstSeenAt: Date,
        lastSeenAt: Date)
    {
        self.keyFingerprint = keyFingerprint
        self.requests = requests
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cachedTokens = cachedTokens
        self.errorCount = errorCount
        self.lastError = lastError
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
    }

    public var totalTokens: Int {
        self.inputTokens + self.outputTokens + self.reasoningTokens
    }
}

/// In-memory per-key usage ledger for the Meta (Muse Code) API key.
///
/// `requests` accumulates every successfully observed response count. Token
/// totals are overwritten with the latest windowed snapshot because they
/// already cover a rolling window, so summing them across fetches would
/// double-count. Failures increment `errorCount` and refresh
/// `lastError`/`lastSeenAt` without touching token totals.
public enum MetaAPIKeyUsageTracker: Sendable {
    /// Fingerprint used when no API key is configured (local-log usage).
    public static let localKeyFingerprint = "local"
    static let maxErrorLength = 240

    private final class Store: @unchecked Sendable {
        var entries: [String: MetaAPIKeyUsageEntry] = [:]
    }

    private static let lock = NSLock()
    private static let store = Store()

    /// Redacted key identifier: last 4 characters, or `"local"` when no key is set.
    public static func fingerprint(for apiKey: String?) -> String {
        guard let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return self.localKeyFingerprint
        }
        return "…" + key.suffix(4)
    }

    public static func recordSuccess(
        apiKey: String?,
        usage: MetaTokenUsage,
        requests: Int,
        at date: Date = Date())
    {
        let id = self.fingerprint(for: apiKey)
        self.lock.lock()
        defer { self.lock.unlock() }
        let previous = self.store.entries[id]
        self.store.entries[id] = MetaAPIKeyUsageEntry(
            keyFingerprint: id,
            requests: (previous?.requests ?? 0) + max(0, requests),
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            reasoningTokens: usage.reasoningTokens,
            cachedTokens: usage.cachedTokens,
            errorCount: previous?.errorCount ?? 0,
            lastError: previous?.lastError,
            firstSeenAt: previous?.firstSeenAt ?? date,
            lastSeenAt: date)
    }

    public static func recordFailure(apiKey: String?, error: Error, at date: Date = Date()) {
        let id = self.fingerprint(for: apiKey)
        self.lock.lock()
        defer { self.lock.unlock() }
        let previous = self.store.entries[id]
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        self.store.entries[id] = MetaAPIKeyUsageEntry(
            keyFingerprint: id,
            requests: previous?.requests ?? 0,
            inputTokens: previous?.inputTokens ?? 0,
            outputTokens: previous?.outputTokens ?? 0,
            reasoningTokens: previous?.reasoningTokens ?? 0,
            cachedTokens: previous?.cachedTokens ?? 0,
            errorCount: (previous?.errorCount ?? 0) + 1,
            lastError: String(message.prefix(self.maxErrorLength)),
            firstSeenAt: previous?.firstSeenAt ?? date,
            lastSeenAt: date)
    }

    public static func entry(for apiKey: String?) -> MetaAPIKeyUsageEntry? {
        let id = self.fingerprint(for: apiKey)
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.store.entries[id]
    }

    public static func allEntries() -> [MetaAPIKeyUsageEntry] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.store.entries.values.sorted { $0.keyFingerprint < $1.keyFingerprint }
    }

    public static func resetForTesting() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.store.entries = [:]
    }
}
