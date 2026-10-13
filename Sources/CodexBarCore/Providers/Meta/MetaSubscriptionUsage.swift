import Foundation

/// Real Muse Code subscription usage, as reported by Meta's provider on every
/// Muse response and surfaced by the Muse host's MSP `usage/read` /
/// `usage/changed` payload (`SubscriptionUsage`). Percents are the provider's own
/// used percents for the current window and the rolling weekly window; Midas
/// displays what is left. `tier` is Meta's opaque tier id, kept verbatim and
/// never presented as a plan name.
public struct MetaSubscriptionUsage: Codable, Sendable, Equatable {
    public let windowUsedPercent: Double
    public let windowDurationMins: Int
    public let windowResetsAt: Date
    public let weeklyUsedPercent: Double
    public let weeklyResetsAt: Date
    public let tier: String?
    public let observedAt: Date

    public init(
        windowUsedPercent: Double,
        windowDurationMins: Int,
        windowResetsAt: Date,
        weeklyUsedPercent: Double,
        weeklyResetsAt: Date,
        tier: String?,
        observedAt: Date)
    {
        self.windowUsedPercent = windowUsedPercent
        self.windowDurationMins = windowDurationMins
        self.windowResetsAt = windowResetsAt
        self.weeklyUsedPercent = weeklyUsedPercent
        self.weeklyResetsAt = weeklyResetsAt
        self.tier = tier
        self.observedAt = observedAt
    }

    /// Percent of the current window still left (provider used may exceed 100).
    public var windowRemainingPercent: Double {
        min(100, max(0, 100 - self.windowUsedPercent))
    }

    /// Percent of the weekly window still left.
    public var weeklyRemainingPercent: Double {
        min(100, max(0, 100 - self.weeklyUsedPercent))
    }

    /// Parses one MSP `SubscriptionUsage` object (the `usage` member of a
    /// `usage/read` result or a `usage/changed` notification's params).
    public init?(mspUsage: [String: Any]) {
        guard let window = mspUsage["window"] as? [String: Any],
              let weekly = mspUsage["weekly"] as? [String: Any],
              let windowUsed = Self.number(window["usedPercent"]),
              let duration = Self.number(window["windowDurationMins"]),
              let windowResetMs = Self.number(window["resetsAtMs"]),
              let weeklyUsed = Self.number(weekly["usedPercent"]),
              let weeklyResetMs = Self.number(weekly["resetsAtMs"]),
              let observedMs = Self.number(mspUsage["observedAtMs"]),
              windowUsed.isFinite, weeklyUsed.isFinite, duration > 0
        else {
            return nil
        }
        self.init(
            windowUsedPercent: windowUsed,
            windowDurationMins: Int(duration),
            windowResetsAt: Date(timeIntervalSince1970: windowResetMs / 1000),
            weeklyUsedPercent: weeklyUsed,
            weeklyResetsAt: Date(timeIntervalSince1970: weeklyResetMs / 1000),
            tier: (mspUsage["tier"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            observedAt: Date(timeIntervalSince1970: observedMs / 1000))
    }

    public static func _parseForTesting(data: Data) -> Self? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Self(mspUsage: (json["usage"] as? [String: Any]) ?? json)
    }

    private static func number(_ raw: Any?) -> Double? {
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        return nil
    }
}

/// Persisted last probe result. The probe costs one minimal Muse request, so
/// Midas reuses this value for up to an hour instead of asking again.
public enum MetaSubscriptionUsageCache {
    public static let fileName = "meta-subscription-usage-v1.json"
    /// Minimum spacing between paid probes; explicit refreshes inside the hour reuse the cache.
    public static let freshInterval: TimeInterval = 55 * 60

    public struct Payload: Codable, Sendable, Equatable {
        public let version: Int
        public let usage: MetaSubscriptionUsage
        public let probeSessionID: String?

        public init(usage: MetaSubscriptionUsage, probeSessionID: String?) {
            self.version = 1
            self.usage = usage
            self.probeSessionID = probeSessionID
        }
    }

    public static func fileURL(cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(MidasIdentity.supportDirectoryName, isDirectory: true)
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent(self.fileName, isDirectory: false)
    }

    public static func load(cacheRoot: URL? = nil) -> Payload? {
        guard let data = try? Data(contentsOf: self.fileURL(cacheRoot: cacheRoot)),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == 1
        else {
            return nil
        }
        return payload
    }

    @discardableResult
    public static func save(_ payload: Payload, cacheRoot: URL? = nil) -> Bool {
        let url = self.fileURL(cacheRoot: cacheRoot)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    public static func isFresh(_ payload: Payload, now: Date = Date()) -> Bool {
        now.timeIntervalSince(payload.usage.observedAt) < self.freshInterval
            && payload.usage.weeklyResetsAt > now.addingTimeInterval(-7 * 24 * 3600)
    }
}

/// Asks Muse for its last-observed subscription usage over MSP
/// (`muse serve`). A fresh host has observed nothing, so the probe resumes
/// Midas's one dedicated check session (starting and naming it on first use)
/// and sends a single minimal prompt; the provider's response carries the
/// current usage, which the host republishes via `usage/changed`. Callers
/// must throttle probes with `MetaSubscriptionUsageCache`.
public enum MetaUsageProbe {
    public static func locateMuseBinary(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for candidate in ["\(home)/.local/bin/muse"] where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return TTYCommandRunner.which("muse")
    }

    public static func uuid7(now: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let ms = UInt64(now.timeIntervalSince1970 * 1000)
        for index in 0..<6 {
            bytes[index] = UInt8((ms >> (40 - index * 8)) & 0xFF)
        }
        for index in 6..<16 {
            bytes[index] = UInt8.random(in: .min ... .max)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [
            String(hex.prefix(8)),
            String(hex.dropFirst(8).prefix(4)),
            String(hex.dropFirst(12).prefix(4)),
            String(hex.dropFirst(16).prefix(4)),
            String(hex.dropFirst(20)),
        ]
        return parts.joined(separator: "-")
    }

    public static func fetchUsage(
        probeSessionID: String?,
        timeout: TimeInterval = 60) async throws -> (usage: MetaSubscriptionUsage, sessionID: String?)
    {
        guard let binary = self.locateMuseBinary() else {
            throw MetaUsageProbeError.binaryNotFound
        }
        let client = MetaMSPClient(executable: binary)
        do {
            let result = try await client.fetchUsage(probeSessionID: probeSessionID, timeout: timeout)
            client.shutdown()
            return result
        } catch {
            client.shutdown()
            throw error
        }
    }
}

/// Newline-delimited JSON-RPC 2.0 client for `muse serve` (MSP). Pipe
/// chunks arrive through a readability handler into an async line stream
/// (`FileHandle.readData(ofLength:)` blocks for a full buffer on pipes, so it
/// must not be used here). A watchdog terminates the host at the deadline,
/// which closes the pipes and unblocks any pending read as a timeout.
final class MetaMSPClient: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private var nextID = 1
    private let lineStream: AsyncStream<Data>
    private let lineContinuation: AsyncStream<Data>.Continuation

    private final class LineBuffer: @unchecked Sendable {
        private var buffer = Data()
        private let lock = NSLock()

        func appendAndDrainLines(_ data: Data) -> [Data] {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.buffer.append(data)
            var lines: [Data] = []
            while let newline = self.buffer.firstIndex(of: 0x0A) {
                lines.append(Data(self.buffer[..<newline]))
                self.buffer.removeSubrange(...newline)
            }
            return lines
        }
    }

    init(executable: String) {
        // Writing to a dead child's stdin must raise, not kill this process.
        #if canImport(Darwin)
        _ = Darwin.signal(SIGPIPE, SIG_IGN)
        #endif
        var continuation: AsyncStream<Data>.Continuation!
        self.lineStream = AsyncStream<Data> { continuation = $0 }
        self.lineContinuation = continuation
        self.process.environment = ProcessInfo.processInfo.environment
        self.process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        self.process.arguments = [executable, "serve"]
        self.process.standardInput = self.stdinPipe
        self.process.standardOutput = self.stdoutPipe
        // stderr goes nowhere: an undrained pipe fills during session start
        // and blocks the host before it can answer.
        self.process.standardError = FileHandle.nullDevice
        let buffer = LineBuffer()
        let lineContinuation = self.lineContinuation
        self.stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                lineContinuation.finish()
                return
            }
            for line in buffer.appendAndDrainLines(data) {
                lineContinuation.yield(line)
            }
        }
    }

    func shutdown() {
        self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        try? self.stdinPipe.fileHandleForWriting.close()
        if self.process.isRunning {
            self.process.terminate()
        }
        self.lineContinuation.finish()
    }

    private func debugStage(_ text: String) {
        if ProcessInfo.processInfo.environment["MIDAS_META_PROBE_DEBUG"] == "1" {
            FileHandle.standardError.write(Data("meta msp: \(text)\n".utf8))
        }
    }

    func fetchUsage(
        probeSessionID: String?,
        timeout: TimeInterval) async throws -> (usage: MetaSubscriptionUsage, sessionID: String?)
    {
        do {
            try self.process.run()
        } catch {
            throw MetaUsageProbeError.hostError(error.localizedDescription)
        }
        let client = self
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            client.shutdown()
        }
        defer {
            watchdog.cancel()
            self.shutdown()
        }

        var messages = self.lineStream
            .map { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            .compactMap(\.self)
            .makeAsyncIterator()

        func nextMessage() async -> [String: Any]? {
            let message = await messages.next()
            if let message {
                self.debugStage("method=\(message["method"] as? String ?? "-") id=\(message["id"] ?? "-" as Any)")
            }
            return message
        }

        func waitFor(id targetID: Int) async throws -> [String: Any] {
            while let message = await nextMessage() {
                if (message["id"] as? NSNumber)?.intValue == targetID {
                    if let error = message["error"] as? [String: Any] {
                        throw MetaUsageProbeError.hostError(
                            (error["message"] as? String) ?? "MSP request failed")
                    }
                    return message
                }
            }
            throw MetaUsageProbeError.timedOut
        }

        func readUsage() async throws -> MetaSubscriptionUsage? {
            let read = try await waitFor(id: self.request(method: "usage/read", params: [String: Any]()))
            guard let usageDict = (read["result"] as? [String: Any])?["usage"] as? [String: Any] else {
                return nil
            }
            return MetaSubscriptionUsage(mspUsage: usageDict)
        }

        _ = try await waitFor(id: self.request(
            method: "initialize",
            params: ["clientInfo": ["name": "midas", "version": "1"]]))
        self.send(["jsonrpc": "2.0", "method": "initialized", "params": [String: Any]()])

        var sessionID: String?
        if let probeSessionID {
            if let resumed = try? await waitFor(id: self.request(
                method: "session/resume",
                params: ["commandId": MetaUsageProbe.uuid7(), "sessionId": probeSessionID])),
                let session = (resumed["result"] as? [String: Any])?["session"] as? [String: Any]
            {
                sessionID = (session["sessionId"] as? String) ?? probeSessionID
            }
        }
        if sessionID == nil {
            let started = try await waitFor(id: self.request(
                method: "session/start",
                params: ["commandId": MetaUsageProbe.uuid7()]))
            sessionID = ((started["result"] as? [String: Any])?["session"] as? [String: Any])?["sessionId"]
                as? String
            if let sessionID {
                _ = try? await waitFor(id: self.request(
                    method: "session/rename",
                    params: [
                        "commandId": MetaUsageProbe.uuid7(),
                        "sessionId": sessionID,
                        "name": "Midas usage check",
                    ]))
            }
        }

        // A host that has already observed usage answers without a model call.
        if let usage = try await readUsage() {
            return (usage, sessionID)
        }

        guard let sessionID else { throw MetaUsageProbeError.noUsageObserved }
        _ = self.request(
            method: "turn/start",
            params: [
                "commandId": MetaUsageProbe.uuid7(),
                "sessionId": sessionID,
                "input": [["type": "text", "text": "Reply with exactly: ok"]],
                "reasoningEffort": "minimal",
            ])
        while let message = await nextMessage() {
            if message["method"] as? String == "usage/changed",
               let params = message["params"] as? [String: Any],
               let usage = MetaSubscriptionUsage(mspUsage: params)
            {
                return (usage, sessionID)
            }
            if message["method"] as? String == "turn/completed" {
                if let usage = try await readUsage() {
                    return (usage, sessionID)
                }
                throw MetaUsageProbeError.noUsageObserved
            }
        }
        throw MetaUsageProbeError.timedOut
    }

    private func send(_ object: [String: Any]) {
        self.debugStage("send \(object["method"] as? String ?? "?")")
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var line = data
        line.append(0x0A)
        try? self.stdinPipe.fileHandleForWriting.write(contentsOf: line)
    }

    @discardableResult
    private func request(method: String, params: [String: Any]) -> Int {
        let id = self.nextID
        self.nextID += 1
        self.send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return id
    }
}

public enum MetaUsageProbeError: LocalizedError, Sendable {
    case binaryNotFound
    case timedOut
    case noUsageObserved
    case hostError(String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            "The `muse` CLI was not found, so Muse Code plan usage cannot be checked."
        case .timedOut:
            "Timed out while asking Muse for plan usage."
        case .noUsageObserved:
            "Muse did not report subscription usage."
        case let .hostError(message):
            "Muse usage check failed: \(message)"
        }
    }
}
