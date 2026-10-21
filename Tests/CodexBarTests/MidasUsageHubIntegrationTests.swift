import Foundation
import Testing
@testable import CodexBarCore

/// Opt-in because this runs a real Python hub and transfers two complete 75k histories.
/// It never reads provider files or invokes the user's service.
@Suite(.serialized)
struct MidasUsageHubIntegrationTests {
    private struct Fixture: Decodable {
        let connections: [MidasUsageHubConnection]
        let workspace: MidasUsageSyncWorkspace
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIDAS_RUN_HUB_INTEGRATION"] == "1"))
    func realPythonHubPreservesLargeHistoriesAcrossFaultsAndCacheRestore() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("midas-swift-wire-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            ProcessInfo.processInfo.environment["MIDAS_TEST_PYTHON"] ?? "python3",
            "-B",
            repository.appendingPathComponent("Scripts/usage-hub/swift_integration_fixture.py").path,
            root.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let ready = root.appendingPathComponent("ready.json")
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try #require(process.isRunning)
            try await Task.sleep(for: .milliseconds(20))
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: ready))
        let one = fixture.connections[0]
        let two = fixture.connections[1]
        let cacheOne = root.appendingPathComponent("one")
        let cacheTwo = root.appendingPathComponent("two")
        let now = Date()
        let first = self.publication(fixture.workspace, one, count: 75000, offset: 0, now: now)
        let second = self.publication(fixture.workspace, two, count: 75000, offset: 75000, now: now)
        let fault = root.appendingPathComponent("fault.txt")
        // The server commits successfully but drops the HTTP response. Retry must recover its receipt.
        try Data("drop-commit".utf8).write(to: fault)
        do {
            _ = try await MidasUsageHubClient.exchange(
                connection: one, workspace: fixture.workspace, local: first, stateRoot: cacheOne)
        } catch { /* Deliberate lost response; retry must recover the committed publication. */ }
        #expect(!FileManager.default.fileExists(atPath: fault.path))
        let retry = try await MidasUsageHubClient.exchange(
            connection: one, workspace: fixture.workspace, local: first, stateRoot: cacheOne)
        #expect(retry.syncState?.acceptedLocalRevision == 1)
        let uploaded = try await MidasUsageHubClient.exchange(
            connection: two, workspace: fixture.workspace, local: second, stateRoot: cacheTwo)
        #expect(uploaded.publications.reduce(0) { $0 + $1.events.count } == 150_000)
        #expect(uploaded.publications.count == 3) // Includes a real v1 publisher.
        let stateTwo = try #require(uploaded.syncState)
        // Simulate the caller's durable state write before acknowledging application.
        try JSONEncoder().encode(uploaded).write(to: root.appendingPathComponent("durable-two.json"), options: .atomic)
        try Data("drop-receipt".utf8).write(to: fault)
        do {
            _ = try await MidasUsageHubClient.acknowledgeApplied(
                connection: two, workspace: fixture.workspace, state: stateTwo, stateRoot: cacheTwo)
        } catch { /* Receipt was stored; its retry is idempotent. */ }
        _ = try await MidasUsageHubClient.acknowledgeApplied(
            connection: two, workspace: fixture.workspace, state: stateTwo, stateRoot: cacheTwo)
        #expect(!FileManager.default.fileExists(atPath: fault.path))
        // Restoring an older cache must fetch immutable pages and never lose canonical history.
        try FileManager.default.removeItem(at: cacheOne)
        try Data("truncate-page".utf8).write(to: fault)
        do {
            _ = try await MidasUsageHubClient.exchange(
                connection: one, workspace: fixture.workspace, local: first, stateRoot: cacheOne)
        } catch { /* A partial page cannot be accepted as a checkpoint. */ }
        #expect(!FileManager.default.fileExists(atPath: fault.path))
        try Data("slow-page".utf8).write(to: fault)
        let recovered = try await MidasUsageHubClient.exchange(
            connection: one, workspace: fixture.workspace, local: first, stateRoot: cacheOne)
        #expect(recovered.publications.reduce(0) { $0 + $1.events.count } == 150_000)
        #expect(recovered.syncState?.acceptedLocalRevision == 1)
        let stateOne = try #require(recovered.syncState)
        try JSONEncoder().encode(recovered).write(to: root.appendingPathComponent("durable-one.json"), options: .atomic)
        let peers = try await MidasUsageHubClient.acknowledgeApplied(
            connection: one, workspace: fixture.workspace, state: stateOne, stateRoot: cacheOne)
        #expect(peers.count == 2)
        #expect(peers.allSatisfy { $0.appliedRevisions[one.deviceID.uuidString] == 1 })
        #expect(peers.allSatisfy { $0.appliedRevisions[two.deviceID.uuidString] == 1 })
        let unchanged = try await MidasUsageHubClient.exchange(
            connection: one, workspace: fixture.workspace, local: first, stateRoot: cacheOne)
        #expect(unchanged.syncState?.downloadedPages == 0)
        #expect(unchanged.syncState?.uploadedPages == 0)
        // Corrupt a cached page without changing its length while parsed objects are still warm.
        let pages = cacheOne.appendingPathComponent(fixture.workspace.id.uuidString)
            .appendingPathComponent(one.deviceID.uuidString).appendingPathComponent("pages")
        let page = try #require(FileManager.default.contentsOfDirectory(
            at: pages, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        var damaged = try Data(contentsOf: page)
        damaged[0] = damaged[0] == 123 ? 91 : 123
        try damaged.write(to: page)
        let repaired = try await MidasUsageHubClient.exchange(
            connection: one, workspace: fixture.workspace, local: first, stateRoot: cacheOne)
        #expect((repaired.syncState?.downloadedPages ?? 0) >= 1)
        #expect(repaired.publications.reduce(0) { $0 + $1.events.count } == 150_000)
    }

    private func publication(
        _ workspace: MidasUsageSyncWorkspace,
        _ connection: MidasUsageHubConnection,
        count: Int,
        offset: Int,
        now: Date) -> MidasUsageSyncPublication
    {
        let day = MidasUsageSyncPublication.day(now)
        let events = (0..<count).map { index in
            MidasUsageSyncEvent(
                id: String(format: "%064x", index + offset),
                provider: .codex,
                day: day,
                observedAt: now,
                values: .init(tokens: 1, costUSD: 0.000001, model: "synthetic"))
        }
        return MidasUsageSyncPublication(
            workspaceID: workspace.id,
            deviceID: connection.deviceID,
            deviceName: connection.deviceName,
            publishedAt: now,
            events: events)
    }
}
