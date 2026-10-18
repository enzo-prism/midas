import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageScannerWarmCacheTests {
    private func options(for env: CostUsageTestEnvironment) -> CostUsageScanner.Options {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        options.retainSyncRows = true
        return options
    }

    private func usageLine(env: CostUsageTestEnvironment, day: Date, input: Int) throws -> String {
        try env.jsonl([[
            "type": "event_msg",
            "timestamp": env.isoString(for: day),
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": input,
                        "cached_input_tokens": 0,
                        "output_tokens": 10,
                    ],
                ],
            ],
        ]])
    }

    private func writeSession(env: CostUsageTestEnvironment, day: Date) throws -> URL {
        let header = try env.jsonl([
            ["type": "session_meta", "payload": ["session_id": "warm-cache-session"]],
            ["type": "turn_context", "payload": ["model": "gpt-5.2-codex"]],
        ])
        return try env.writeCodexSessionFile(
            day: day,
            filename: "warm-cache.jsonl",
            contents: header + self.usageLine(env: env, day: day, input: 100))
    }

    @Test
    func `unchanged Codex sync cache is not serialized again`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        _ = try self.writeSession(env: env, day: day)
        let options = self.options(for: env)
        let first = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(first.summary?.totalTokens == 110)

        let cacheURL = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: env.cacheRoot)
        let original = try Data(contentsOf: cacheURL)
        let sentinel = Date(timeIntervalSince1970: 978_307_200)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: cacheURL.path)

        let repeated = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(120),
            options: options)
        #expect(repeated.summary?.totalTokens == first.summary?.totalTokens)
        #expect(repeated.summary?.totalCostUSD == first.summary?.totalCostUSD)
        #expect(try Data(contentsOf: cacheURL) == original)
        #expect(try cacheURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == sentinel)
    }

    @Test
    func `Codex changed and deleted files still persist after clean refresh`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let session = try self.writeSession(env: env, day: day)
        let options = self.options(for: env)
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)

        let handle = try FileHandle(forWritingTo: session)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(self.usageLine(env: env, day: day, input: 200).utf8))
        try handle.close()
        let changed = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        #expect(changed.summary?.totalTokens == 210)
        let persisted = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        // Match the scanner's directory-enumerated URL. On macOS Foundation can
        // enumerate /private/var even when resolving the original URL keeps /var.
        let enumeratedFiles = try FileManager.default.contentsOfDirectory(
            at: session.deletingLastPathComponent(),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        let enumeratedSession = try #require(enumeratedFiles.first {
            $0.lastPathComponent == session.lastPathComponent
        })
        let persistedFile = try #require(
            persisted.files[enumeratedSession.path],
            "Expected fixture path \(enumeratedSession.path); persisted keys: \(persisted.files.keys.sorted())")
        #expect(persisted.files.count == 1)
        #expect(persistedFile.sessionId == "warm-cache-session")
        #expect(persistedFile.codexSyncRows?.count == 2)
        #expect(persistedFile.lastCountedTotals?.input == 200)

        try FileManager.default.removeItem(at: session)
        let deleted = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(3),
            options: options)
        #expect(deleted.data.isEmpty)
        #expect(CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot).files.isEmpty)
    }

    @Test
    func `clean Codex refresh advances throttle without writing and explicit refresh bypasses it`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let session = try self.writeSession(env: env, day: day)
        var options = self.options(for: env)
        options.refreshMinIntervalSeconds = 60
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(61),
            options: options)

        let handle = try FileHandle(forWritingTo: session)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(self.usageLine(env: env, day: day, input: 200).utf8))
        try handle.close()
        let throttled = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(62),
            options: options)
        #expect(throttled.summary?.totalTokens == 110)

        options.refreshMinIntervalSeconds = 0
        let refreshed = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(62),
            options: options)
        #expect(refreshed.summary?.totalTokens == 210)
    }

    @Test
    func `atomic cache replacement with the same persisted stamp invalidates clean freshness`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let session = try self.writeSession(env: env, day: day)
        var options = self.options(for: env)
        options.refreshMinIntervalSeconds = 60
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let cacheURL = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: env.cacheRoot)
        let modifiedAt = Date(timeIntervalSince1970: 978_307_200)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: cacheURL.path)
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(61),
            options: options)

        let identity = CostUsageScanner.codexFileMetadata(fileURL: cacheURL)
        let original = try Data(contentsOf: cacheURL)
        try original.write(to: cacheURL, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: cacheURL.path)
        let replacement = CostUsageScanner.codexFileMetadata(fileURL: cacheURL)
        #expect(replacement.fileId != identity.fileId)
        #expect(replacement.mtimeUnixMs == identity.mtimeUnixMs)
        #expect(replacement.size == identity.size)

        let handle = try FileHandle(forWritingTo: session)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(self.usageLine(env: env, day: day, input: 200).utf8))
        try handle.close()
        let refreshed = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(62),
            options: options)
        #expect(refreshed.summary?.totalTokens == 210)
    }
}
