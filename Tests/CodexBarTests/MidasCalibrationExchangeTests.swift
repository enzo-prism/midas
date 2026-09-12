import Foundation
import Testing
@testable import CodexBar

struct MidasCalibrationExchangeTests {
    private let now = Date(timeIntervalSince1970: 1_789_171_200)
    private let scope = String(
        repeating: "a",
        count: 64)
    private let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private func record(
        device: UUID,
        tokens: Double = 20000,
        age: Double = 0,
        scope: String? = nil,
        rate: Double = 2) -> MidasCalibrationExchange.Record
    {
        .init(
            deviceID: device,
            scope: scope ?? self.scope,
            calibration: .init(
                rate: rate,
                pricedTokens: tokens,
                observedTokens: tokens,
                sampledAt: self.now.addingTimeInterval(-age),
                lastUsageDay: "2026-09-10"))
    }

    @Test func choosesLargestSampleWithoutAddingDevices() {
        let small = self.record(
            device: self.first,
            tokens: 10000)
        let large = self.record(
            device: self.second,
            tokens: 40000,
            rate: 3)
        for records in [[small, large], [large, small], [small, small, large]] {
            let winner = MidasCalibrationExchange.winner(
                records: records,
                scope: self.scope,
                now: self.now)
            #expect(winner == large)
            #expect(winner?.calibration.pricedTokens == 40000)
        }
    }

    @Test func newestValidRecordPerDeviceReplacesLargerOlderSample() {
        let old = self.record(
            device: self.first,
            tokens: 90000,
            age: 100)
        let fresh = self.record(
            device: self.first,
            tokens: 10000)
        let other = self.record(
            device: self.second,
            tokens: 20000)
        #expect(MidasCalibrationExchange.winner(
            records: [old, fresh, other],
            scope: self.scope,
            now: self.now) == other)
        #expect(MidasCalibrationExchange.winner(
            records: [other, fresh, old],
            scope: self.scope,
            now: self.now) == other)
    }

    @Test func deterministicTieUsesTimestampThenDeviceID() {
        let older = self.record(
            device: self.first,
            age: 10)
        let newer = self.record(device: self.second)
        #expect(MidasCalibrationExchange.winner(
            records: [older, newer],
            scope: self.scope,
            now: self.now) == newer)
        let tied = self.record(device: self.first)
        #expect(MidasCalibrationExchange.winner(
            records: [newer, tied],
            scope: self.scope,
            now: self.now) == tied)
        #expect(MidasCalibrationExchange.winner(
            records: [tied, newer],
            scope: self.scope,
            now: self.now) == tied)
    }

    @Test func rejectsUnknownVersionsScopeAndExpiredSamples() {
        var unknownSchema = self.record(device: self.first)
        unknownSchema.schemaVersion = 2
        var unknownMethod = self.record(device: self.first)
        unknownMethod.methodVersion = 2
        let invalid = [
            unknownSchema,
            unknownMethod,
            self.record(
                device: self.first,
                scope: String(
                    repeating: "b",
                    count: 64)),
            self.record(
                device: self.first,
                age: 86401),
            self.record(
                device: self.first,
                age: -301),
            self.record(
                device: self.first,
                rate: .infinity),
        ]
        #expect(MidasCalibrationExchange.winner(
            records: invalid,
            scope: self.scope,
            now: self.now) == nil)
        #expect(MidasCalibrationExchange.winner(
            records: [self.record(
                device: self.first,
                scope: "account-email")],
            scope: "account-email",
            now: self.now) == nil)
    }

    @Test func simulatedDevicesConvergeAndPreserveForeignFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = self.record(
            device: self.first,
            tokens: 10000)
        let second = self.record(
            device: self.second,
            tokens: 40000)
        _ = try await MidasCalibrationExchange.exchange(
            folder: folder,
            local: first,
            now: self.now)
        let foreign = folder.appendingPathComponent("notes.txt")
        try Data("Preserve me".utf8).write(to: foreign)
        let secondView = try await MidasCalibrationExchange.exchange(
            folder: folder,
            local: second,
            now: self.now)
        let firstView = try await MidasCalibrationExchange.exchange(
            folder: folder,
            local: first,
            now: self.now)
        #expect(MidasCalibrationExchange.winner(
            records: firstView.records,
            scope: self.scope,
            now: self.now) == second)
        #expect(MidasCalibrationExchange
            .winner(
                records: secondView.records,
                scope: self.scope,
                now: self.now) == second)
        #expect(try String(
            contentsOf: foreign,
            encoding: .utf8) == "Preserve me")
        #expect(firstView.records.count == 2)
        #expect(!firstView.publicationFailed)
    }

    @Test func ignoresMalformedOversizedSymlinkAndMismatchedRecords() async throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(
            at: folder,
            withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: folder) }
        try Data("broken".utf8).write(to: folder.appendingPathComponent(UUID().uuidString + ".json"))
        try Data(
            repeating: 65,
            count: 65537).write(to: folder.appendingPathComponent(UUID().uuidString + ".json"))
        let valid = self.record(device: self.first)
        try JSONEncoder().encode(valid).write(to: folder.appendingPathComponent(self.second.uuidString + ".json"))
        let target = folder.appendingPathComponent("foreign.txt")
        try JSONEncoder().encode(valid).write(to: target)
        try manager.createSymbolicLink(
            at: folder.appendingPathComponent(self.first.uuidString + ".json"),
            withDestinationURL: target)
        let result = try await MidasCalibrationExchange.exchange(
            folder: folder,
            local: nil,
            now: self.now)
        #expect(result.records.isEmpty)
        #expect(manager.fileExists(atPath: target.path))
    }

    @Test func publicationFailureStillReturnsRemoteRecords() async throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: folder) }
        let remote = self.record(device: self.second)
        _ = try await MidasCalibrationExchange.exchange(
            folder: folder,
            local: remote,
            now: self.now)
        try manager.createDirectory(
            at: folder.appendingPathComponent(self.first.uuidString + ".json"),
            withIntermediateDirectories: false)
        let result = try await MidasCalibrationExchange.exchange(
            folder: folder,
            local: self.record(device: self.first),
            now: self.now)
        #expect(result.publicationFailed)
        #expect(MidasCalibrationExchange.winner(
            records: result.records,
            scope: self.scope,
            now: self.now) == remote)
    }

    @Test func unchangedPublicationPreservesModificationDateAndPrivatePermissions() async throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: folder) }
        let record = self.record(device: self.first)
        _ = try await MidasCalibrationExchange.exchange(
            folder: folder,
            local: record,
            now: self.now)
        let file = folder.appendingPathComponent(self.first.uuidString + ".json")
        let sentinel = Date(timeIntervalSince1970: 1_000_000)
        try manager.setAttributes(
            [.modificationDate: sentinel],
            ofItemAtPath: file.path)
        let result = try await MidasCalibrationExchange.exchange(
            folder: folder,
            local: record,
            now: self.now)
        let attributes = try manager.attributesOfItem(atPath: file.path)
        #expect(!result.publicationFailed)
        #expect(attributes[.modificationDate] as? Date == sentinel)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func cancelledExchangeDoesNotCreateFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let record = self.record(device: self.first)
        let now = self.now
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MidasCalibrationExchange.exchange(
                folder: folder,
                local: record,
                now: now)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func inaccessibleFolderIsAnErrorNotAnEmptyHistory() async throws {
        let missingParent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await #expect(throws: (any Error).self) {
            try await MidasCalibrationExchange.exchange(
                folder: missingParent.appendingPathComponent("exchange"),
                local: nil,
                now: self.now)
        }
    }
}
