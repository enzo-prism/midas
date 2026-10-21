import Darwin
import Foundation
import Testing
@testable import CodexBarCore

struct MidasUsageHubV2Tests {
    @Test func closedDayPagesStayIdenticalWhenCurrentDayGrows() throws {
        let root = try self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = MidasUsageSyncWorkspace()
        let device = UUID()
        let storage = try MidasUsageHubV2Storage(root: root, workspaceID: workspace.id, deviceID: device)
        let now = Date()
        let historical = (0..<1200).map { self.event($0, day: "2026-09-01", now: now) }
        let original = MidasUsageSyncPublication(
            workspaceID: workspace.id,
            deviceID: device,
            deviceName: "Fixture",
            publishedAt: now,
            events: historical + [self.event(2000, day: "2026-09-02", now: now)])
        let grown = MidasUsageSyncPublication(
            workspaceID: workspace.id,
            deviceID: device,
            deviceName: "Fixture",
            publishedAt: now.addingTimeInterval(60),
            events: original.events + [self.event(2001, day: "2026-09-02", now: now)])
        let before = try MidasUsageHubTransportV2.prepare(original, maximumBytes: 8192, storage: storage)
        let after = try MidasUsageHubTransportV2.prepare(grown, maximumBytes: 8192, storage: storage)
        #expect(before.pages.count > 3)
        #expect(before.pages.dropLast() == after.pages.dropLast())
        #expect(before.pages.last?.digest != after.pages.last?.digest)
        for page in after.pages {
            let optional = try storage.page(page.digest, maximumBytes: 8192)
            let data = try #require(optional)
            #expect(data.count <= 8192)
            #expect(MidasUsageHubTransportV2.hash(data) == page.digest)
        }
    }

    @Test func cacheIsPrivateAtomicAndRejectsSymlinks() throws {
        let root = try self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = MidasUsageSyncWorkspace()
        let device = UUID()
        let storage = try MidasUsageHubV2Storage(root: root, workspaceID: workspace.id, deviceID: device)
        let data = Data("numeric fixture".utf8)
        let digest = MidasUsageHubTransportV2.hash(data)
        try storage.savePage(data, digest: digest)
        #expect(try storage.page(digest, maximumBytes: 100) == data)
        let path = storage.root.appendingPathComponent("pages/" + digest + ".json")
        let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: root.appendingPathComponent("outside"))
        #expect(throws: MidasUsageSyncError.unsafeFile) { try storage.savePage(data, digest: digest) }
        #expect(throws: MidasUsageSyncError.unsafeFile) { try storage.page(digest, maximumBytes: 100) }
    }

    @Test func pruningKeepsPendingAndSelectedPages() throws {
        let root = try self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = MidasUsageSyncWorkspace()
        let storage = try MidasUsageHubV2Storage(root: root, workspaceID: workspace.id, deviceID: UUID())
        let kept = Data("retained".utf8)
        let orphan = Data("orphan".utf8)
        let digest = MidasUsageHubTransportV2.hash(kept)
        let removed = MidasUsageHubTransportV2.hash(orphan)
        try storage.savePage(kept, digest: digest)
        try storage.savePage(orphan, digest: removed)
        try storage.prunePages(keeping: [digest])
        #expect(try storage.page(digest, maximumBytes: 100) == kept)
        #expect(try storage.page(removed, maximumBytes: 100) == nil)
    }

    @Test func legacyProjectionOmitsNewPricingMetadataAndKeepsMeasurements() throws {
        let workspace = MidasUsageSyncWorkspace()
        let now = Date()
        let local = MidasUsageSyncPublication(
            workspaceID: workspace.id,
            deviceID: UUID(),
            deviceName: "Fixture",
            publishedAt: now,
            events: [MidasUsageSyncEvent(
                id: String(repeating: "a", count: 64),
                provider: .codex,
                day: "2026-09-01",
                observedAt: now,
                values: MidasUsageSyncValues(tokens: 123, costUSD: 0.3, pricingRevision: 1))])
        let legacy = MidasUsageHubClient.legacyPublication(local)
        let data = try MidasUsageSyncEncoding.encodePublication(legacy)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("pricingRevision"))
        #expect(legacy.events.reduce(0) { $0 + ($1.values.tokens ?? 0) } == 123)
        #expect(local.events.first?.values.pricingRevision == 1)
    }

    @Test func oldExchangeDecodesWithoutSyncMetadata() throws {
        let workspace = MidasUsageSyncWorkspace()
        let exchange = MidasUsageHubExchange(
            workspace: workspace,
            publications: [],
            publicationSucceeded: false,
            unavailableFiles: 0,
            rejectedFiles: 0)
        let data = try JSONEncoder().encode(exchange)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["syncState"] == nil)
        #expect(try JSONDecoder().decode(MidasUsageHubExchange.self, from: data).syncState == nil)
    }

    private func event(_ index: Int, day: String, now: Date) -> MidasUsageSyncEvent {
        MidasUsageSyncEvent(
            id: String(repeating: "a", count: 40) + String(format: "%024d", index),
            provider: .codex,
            day: day,
            observedAt: now,
            values: MidasUsageSyncValues(tokens: 15, costUSD: 0.01))
    }

    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("midas-v2-unit-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return root
    }
}
