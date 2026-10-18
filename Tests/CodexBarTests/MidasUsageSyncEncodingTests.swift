import Foundation
import Testing
@testable import CodexBarCore

struct MidasUsageSyncEncodingTests {
    private struct Metadata: Codable, Equatable {
        let schemaVersion: Int
        let localDeviceID: UUID
        let deviceBinding: String?
        let accountFingerprint: String
        let workspace: MidasUsageSyncWorkspace
        let lastPublishedAt: Date?
        let lastReceivedAt: Date?
    }

    private struct Cache: Codable, Equatable {
        let schemaVersion: Int
        let localDeviceID: UUID
        let deviceBinding: String?
        let accountFingerprint: String
        let workspace: MidasUsageSyncWorkspace
        let publications: [MidasUsageSyncPublication]
        let pendingLocal: MidasUsageSyncPublication?
        let lastPublishedAt: Date?
        let lastReceivedAt: Date?
    }

    private let date = Date(timeIntervalSinceReferenceDate: 813_978_983.304637)

    private func publication(count: Int = 1, accounts: Int = 1, model: String? = "nvidia/model")
        -> MidasUsageSyncPublication
    {
        let values = MidasUsageSyncValues(
            tokens: 0,
            requests: nil,
            costUSD: 1.23456789e-12,
            apiEquivalentCostUSD: -0.0,
            tokenMix: .init(inputTokens: 0, outputTokens: nil, cacheReadTokens: 0),
            provenance: .listPriceEstimate,
            model: model,
            unpricedRequests: 0,
            estimatedRequests: 1)
        let event = MidasUsageSyncEvent(
            id: String(repeating: "a", count: 64),
            provider: .localInference,
            day: "2026-10-17",
            observedAt: self.date,
            values: values)
        let account = MidasUsageSyncAccountDay(
            accountScope: String(repeating: "b", count: 64),
            provider: .cursor,
            day: "2026-10-16",
            observedAt: self.date,
            values: values)
        return MidasUsageSyncPublication(
            workspaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            deviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            deviceName: #"Mac / "quoted" \ 雪"#,
            publishedAt: self.date,
            events: Array(repeating: event, count: count),
            accountDays: Array(repeating: account, count: accounts),
            excludedRecords: 3)
    }

    @Test func publicationBytesAndSizeMatchFoundationRepresentationAcrossBatches() throws {
        for count in [0, 1, 511, 512, 513, 1537] {
            for model in [nil, "nvidia/model", "Unicode 雪 🦉 \"quoted\" \\ /\n\t\u{0000}"] {
                let publication = self.publication(count: count, accounts: count == 0 ? 0 : 513, model: model)
                let normal = try JSONEncoder().encode(publication)
                let encoded = try MidasUsageSyncEncoding.encodePublication(publication)
                #expect(encoded.count == normal.count)
                #expect(try MidasUsageSyncEncoding.encodedPublicationSize(publication) == normal.count)
                #expect(try JSONDecoder().decode(MidasUsageSyncPublication.self, from: encoded) == publication)
                #expect(try MidasUsageSyncCodec.decodePublication(encoded) == publication)
            }
        }
    }

    @Test func schemaTwoCachePreservesAllMetadataAndOptionalOutboxBehavior() throws {
        let publication = self.publication(count: 513, accounts: 1)
        let metadata = Metadata(
            schemaVersion: 2,
            localDeviceID: publication.deviceID,
            deviceBinding: "test-binding",
            accountFingerprint: "test-fingerprint",
            workspace: MidasUsageSyncWorkspace(id: publication.workspaceID, createdAt: self.date),
            lastPublishedAt: self.date,
            lastReceivedAt: nil)
        for pending in [nil, publication] {
            let data = try MidasUsageSyncEncoding.encodeEnvelope(
                metadata: JSONEncoder().encode(metadata), publications: [publication], pendingLocal: pending)
            let expected = Cache(
                schemaVersion: metadata.schemaVersion,
                localDeviceID: metadata.localDeviceID,
                deviceBinding: metadata.deviceBinding,
                accountFingerprint: metadata.accountFingerprint,
                workspace: metadata.workspace,
                publications: [publication],
                pendingLocal: pending,
                lastPublishedAt: metadata.lastPublishedAt,
                lastReceivedAt: nil)
            #expect(try JSONDecoder().decode(Cache.self, from: data) == expected)
            #expect(try data.count == (JSONEncoder().encode(expected).count))
            let decoded = try MidasUsageSyncCodec.decodeEnvelope(data)
            #expect(decoded.publications == expected.publications)
            #expect(decoded.pendingLocal == expected.pendingLocal)
            let dictionary = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(dictionary.keys.contains("pendingLocal") == (pending != nil))
            #expect(!dictionary.keys.contains("lastReceivedAt"))
        }
    }

    @Test func emptyAndUnknownMetadataRemainValidButReservedOrMalformedFieldsAreRejected() throws {
        for metadata in ["{}", " \n { \t } \n", #"{"extension":{"a":[null,true,1e-9,"雪"]}}"#] {
            let data = try MidasUsageSyncEncoding.encodeEnvelope(
                metadata: Data(metadata.utf8), publications: [], pendingLocal: nil)
            #expect(try MidasUsageSyncCodec.decodeEnvelope(data).publications.isEmpty)
        }
        for metadata in [
            "", "null", "[]", "{}true", #"{"x":1,}"#, #"{"x":1,"x":2}"#,
            #"{"publications":[]}"#, #"{"publi\u0063ations":[]}"#, #"{"pendingLocal":null}"#,
            #"{"extension":{"a":0,"a":1}}"#,
        ] {
            #expect(throws: (any Error).self) {
                try MidasUsageSyncEncoding.encodeEnvelope(
                    metadata: Data(metadata.utf8), publications: [], pendingLocal: nil)
            }
        }
    }

    @Test func countAndMetadataBoundsAreAppliedBeforeEncoding() {
        let oversized = self.publication(count: 100_000, accounts: 1)
        #expect(throws: MidasUsageSyncError.limitExceeded) {
            try MidasUsageSyncEncoding.encodePublication(oversized)
        }
        #expect(throws: MidasUsageSyncError.limitExceeded) {
            try MidasUsageSyncEncoding.encodedPublicationSize(oversized)
        }
        #expect(throws: MidasUsageSyncError.limitExceeded) {
            try MidasUsageSyncEncoding.encodeEnvelope(
                metadata: Data("{}".utf8),
                publications: Array(repeating: self.publication(count: 0, accounts: 0), count: 129),
                pendingLocal: nil)
        }
        let publication = self.publication(count: 84000, accounts: 0)
        #expect(throws: MidasUsageSyncError.limitExceeded) {
            try MidasUsageSyncEncoding.encodeEnvelope(
                metadata: Data("{}".utf8), publications: [publication, publication, publication], pendingLocal: nil)
        }
        let metadata = Data((#"{"x":""# + String(repeating: "x", count: 65536) + #""}"#).utf8)
        #expect(throws: MidasUsageSyncError.limitExceeded) {
            try MidasUsageSyncEncoding.encodeEnvelope(metadata: metadata, publications: [], pendingLocal: nil)
        }
    }

    @Test func recordAndCanonicalPublicationByteLimitsIncludeSlashExpansion() throws {
        let largeRecord = self.publication(count: 1, accounts: 0, model: String(repeating: "/", count: 40000))
        #expect(throws: MidasUsageSyncError.limitExceeded) {
            try MidasUsageSyncEncoding.encodePublication(largeRecord)
        }
        let large = self.publication(count: 80000, accounts: 0, model: String(repeating: "/", count: 160))
        #expect(throws: MidasUsageSyncError.limitExceeded) {
            try MidasUsageSyncEncoding.encodedPublicationSize(large)
        }
    }

    @Test func largeButBoundedIndividualStringsPreserveExactDefaultEncoding() throws {
        let publication = self.publication(count: 24, accounts: 0, model: String(repeating: "x", count: 12000))
        let normal = try JSONEncoder().encode(publication)
        let encoded = try MidasUsageSyncEncoding.encodePublication(publication)
        #expect(encoded.count == normal.count)
        #expect(try MidasUsageSyncEncoding.encodedPublicationSize(publication) == normal.count)
        #expect(try JSONDecoder().decode(MidasUsageSyncPublication.self, from: encoded) == publication)
    }

    @Test func cancelledWorkDoesNotReturnAPartialPublicationOrEnvelope() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MidasUsageSyncEncoding.encodeEnvelope(
                metadata: Data("{}".utf8), publications: [self.publication()], pendingLocal: nil)
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation before producing encoded usage")
        } catch is CancellationError {
            // Expected: callers retain the prior atomic cache rather than receiving partial bytes.
        } catch {
            Issue.record("Unexpected encoding error: \(error)")
        }
    }
}
