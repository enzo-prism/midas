import Foundation
import Testing
@testable import CodexBarCore

struct MidasUsageCanonicalStoreTests {
    private let now = Date(timeIntervalSince1970: 1_792_065_600)
    private let workspace = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    private let device = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    @Test func partialRescanAndStaleRestoreCannotEraseCanonicalIdentities() throws {
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MidasUsageCanonicalStore(root: root)
        let original = self.publication([self.event(1), self.event(2)])
        _ = try store.retain(previous: nil, fresh: original, now: self.now)
        let complete = try store.retain(previous: original, fresh: self.publication([self.event(3)]), now: self.now)
        #expect(complete.events.count == 3)
        #expect(try self.tokens(complete) == 300)
        let restarted = try MidasUsageCanonicalStore(root: root)
        let restored = try restarted.retain(previous: nil, fresh: self.publication([]), now: self.now)
        #expect(restored.events == complete.events)
    }

    @Test func staleOutboxCanMergeANewerHeadBeyondClockTolerance() throws {
        let old = self.publication([self.event(1)])
        let newer = MidasUsageSyncPublication(
            workspaceID: self.workspace,
            deviceID: self.device,
            deviceName: "Synthetic Mac",
            publishedAt: self.now.addingTimeInterval(86400),
            events: [self.event(2)])
        let retained = try MidasUsageSyncLedger.retainingCanonicalHistory(previous: newer, fresh: old)
        #expect(retained.events.count == 2)
        #expect(retained.publishedAt == newer.publishedAt)
    }

    @Test func streamingPermutationsAndCopiedLogsSelectCompletedWholeEvent() throws {
        let prefix = self.event(1, tokens: 100)
        let middle = self.event(2, tokens: 200)
        let complete = self.event(1, tokens: 300)
        for records in [[prefix, middle, complete], [complete, prefix, middle], [middle, complete, prefix]] {
            var previous: MidasUsageSyncPublication?
            for record in records {
                previous = try MidasUsageSyncLedger.retainingCanonicalHistory(
                    previous: previous,
                    fresh: self.publication([record]))
            }
            let selected = try #require(previous)
            #expect(selected.events.count == 2)
            #expect(try self.tokens(selected) == 500)
            let copy = MidasUsageSyncPublication(
                workspaceID: self.workspace,
                deviceID: UUID(),
                deviceName: "Copied logs",
                publishedAt: self.now,
                events: [prefix, middle, complete])
            let ledger = try MidasUsageSyncLedger(
                publications: [selected, copy],
                workspaceID: self.workspace,
                now: self.now,
                validation: .canonical)
            #expect(ledger.snapshots[.codex]?.last30DaysTokens == 500)
        }
    }

    @Test func opaqueLegacyBaselineAndFineEvidenceSurviveWithoutDoubleCounting() throws {
        let fine = [self.event(1), self.event(2)]
        let aggregate = MidasUsageSyncRollup.rollUp(fine, deviceID: self.device)
        let migrated = try MidasUsageSyncLedger.retainingCanonicalHistory(
            previous: self.publication(aggregate),
            fresh: self.publication([self.event(3)]))
        #expect(migrated.events.count == 2)
        #expect(migrated.legacyAggregateDayCount == 1)
        #expect(try self.tokens(migrated) == 200)
        let rehydrated = try MidasUsageSyncLedger.retainingCanonicalHistory(
            previous: migrated,
            fresh: self.publication(fine))
        #expect(rehydrated.events.count == 4)
        #expect(try self.tokens(rehydrated) == 300)
        // Original aggregate remains available for audit even after fine coverage overtakes it.
        #expect(rehydrated.events.contains(aggregate[0]))
    }

    @Test func repeatedFineRowsCannotInflateLegacyCoverageOrReduceKnownCost() throws {
        let aggregate = MidasUsageSyncRollup.rollUp([self.event(1), self.event(2)], deviceID: self.device)
        let repeated = self.publication(aggregate + [self.event(3), self.event(3), self.event(3)])
        #expect(try self.tokens(repeated) == 200)
        let lowerCost = MidasUsageSyncEvent(
            id: String(repeating: "f", count: 64),
            provider: .codex,
            day: MidasUsageSyncPublication.day(self.now),
            observedAt: self.now,
            values: .init(tokens: 300, costUSD: 0.25))
        let publication = self.publication(aggregate + [lowerCost])
        let ledger = try MidasUsageSyncLedger(
            publications: [publication], workspaceID: self.workspace, now: self.now, validation: .canonical)
        #expect(ledger.snapshots[.codex]?.last30DaysTokens == 200)
        #expect(ledger.snapshots[.codex]?.last30DaysCostUSD == 2)
    }

    @Test func knownPricingWinsEqualMeasurementAndNewAccountCorrectionsCanDecrease() throws {
        let unknown = self.event(1, priced: false)
        let priced = self.event(1)
        for records in [[unknown, priced], [priced, unknown]] {
            let publication = try MidasUsageSyncLedger.retainingCanonicalHistory(
                previous: self.publication([records[0]]),
                fresh: self.publication([records[1]]))
            #expect(publication.events.first?.values.costUSD == 1)
        }
        let scope = String(repeating: "a", count: 64)
        let old = MidasUsageSyncAccountDay(
            accountScope: scope,
            provider: .cursor,
            day: MidasUsageSyncPublication.day(self.now),
            observedAt: self.now.addingTimeInterval(-60),
            values: .init(tokens: 200, costUSD: 3))
        let correction = MidasUsageSyncAccountDay(
            accountScope: scope,
            provider: .cursor,
            day: old.day,
            observedAt: self.now,
            values: .init(tokens: 100, costUSD: 1))
        #expect(MidasUsageSyncRecordOrder.prefers(correction, over: old))
        #expect(!MidasUsageSyncRecordOrder.prefers(old, over: correction))
    }

    @Test func controlledPricingRevisionCanCorrectEqualTimeCostDownward() throws {
        let old = self.event(1)
        let corrected = MidasUsageSyncEvent(
            id: old.id,
            provider: old.provider,
            day: old.day,
            observedAt: old.observedAt,
            values: .init(tokens: 100, costUSD: 0.25, pricingRevision: 1))
        for records in [[old, corrected], [corrected, old]] {
            let selected = try MidasUsageSyncLedger.retainingCanonicalHistory(
                previous: self.publication([records[0]]), fresh: self.publication([records[1]]))
            #expect(selected.events == [corrected])
        }
        let oldData = try JSONEncoder().encode(old)
        #expect(!(String(data: oldData, encoding: .utf8) ?? "").contains("pricingRevision"))
        #expect(try JSONDecoder().decode(MidasUsageSyncEvent.self, from: oldData).values.pricingRevision == nil)
    }

    @Test func immutableRevisionPinsSurviveLaterWritesAndPruning() throws {
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MidasUsageCanonicalStore(root: root)
        let first = self.publication([self.event(1)])
        let revision = try store.save(first, now: self.now)
        _ = try store.save(self.publication([self.event(2)]), now: self.now)
        _ = try store.save(self.publication([self.event(3)]), now: self.now)
        try store.prune(retainingRevisions: [revision])
        #expect(try store
            .load(workspaceID: self.workspace, deviceID: self.device, revision: revision, now: self.now) == first)
        #expect(try store.load(workspaceID: self.workspace, deviceID: self.device, now: self.now)?
            .events == [self.event(3)])
    }

    @Test func corruptPageFailsClosedAndCannotReplaceCommittedHead() throws {
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MidasUsageCanonicalStore(root: root)
        let original = self.publication([self.event(1)])
        let revision = try store.save(original, now: self.now)
        let page = try #require(FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("pages"),
            includingPropertiesForKeys: nil).first)
        try Data("{}".utf8).write(to: page)
        #expect(throws: (any Error).self) {
            try store.retain(previous: nil, fresh: self.publication([self.event(2)]), now: self.now)
        }
        let manifests = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("manifests"),
            includingPropertiesForKeys: nil)
        #expect(manifests.map { $0.deletingPathExtension().lastPathComponent } == [revision])
    }

    @Test func uncommittedFilesAndRejectedSaveLeavePreviousCheckpointReadable() throws {
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MidasUsageCanonicalStore(root: root)
        let original = self.publication([self.event(1)])
        _ = try store.save(original, now: self.now)
        // A crash before atomic head replacement can leave an unattached page or temporary file.
        try Data("interrupted".utf8).write(to: root.appendingPathComponent("pages/.fixture.pending"))
        let invalid = MidasUsageSyncPublication(
            workspaceID: self.workspace,
            deviceID: self.device,
            deviceName: "Synthetic Mac",
            publishedAt: self.now,
            events: [MidasUsageSyncEvent(
                id: "invalid",
                provider: .codex,
                day: MidasUsageSyncPublication.day(self.now),
                observedAt: self.now,
                values: .init(tokens: 100, costUSD: 1))])
        #expect(throws: MidasUsageSyncError.invalidRecord) { try store.save(invalid, now: self.now) }
        let restarted = try MidasUsageCanonicalStore(root: root)
        #expect(try restarted.load(workspaceID: self.workspace, deviceID: self.device, now: self.now) == original)
    }

    @Test func canonicalCountLimitDoesNotInheritTheLegacyPublicationLimit() throws {
        let publication = self.publication(Array(repeating: self.event(1), count: 100_001))
        #expect(throws: MidasUsageSyncError.limitExceeded) {
            try publication.validate(workspaceID: self.workspace, now: self.now)
        }
        try publication.validateCanonical(workspaceID: self.workspace, now: self.now)
    }

    @Test func symlinkStoreIsRejected() throws {
        let root = self.temporaryRoot()
        let link = root.appendingPathExtension("link")
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: root)
        }
        _ = try MidasUsageCanonicalStore(root: root)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(throws: MidasUsageSyncError.unsafeFile) { try MidasUsageCanonicalStore(root: link) }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("midas-canonical-fixture-\(UUID().uuidString)")
    }

    private func publication(_ events: [MidasUsageSyncEvent]) -> MidasUsageSyncPublication {
        MidasUsageSyncPublication(
            workspaceID: self.workspace,
            deviceID: self.device,
            deviceName: "Synthetic Mac",
            publishedAt: self.now,
            events: events)
    }

    private func event(_ id: Int, tokens: Int = 100, priced: Bool = true) -> MidasUsageSyncEvent {
        MidasUsageSyncEvent(
            id: String(format: "%064x", id),
            provider: .codex,
            day: MidasUsageSyncPublication.day(self.now),
            observedAt: self.now,
            values: .init(tokens: tokens, costUSD: priced ? 1 : nil))
    }

    private func tokens(_ publication: MidasUsageSyncPublication) throws -> Int? {
        try MidasUsageSyncLedger(
            publications: [publication],
            workspaceID: self.workspace,
            now: self.now,
            validation: .canonical)
            .snapshots[.codex]?.last30DaysTokens
    }
}
