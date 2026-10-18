import Foundation
import Testing
@testable import CodexBarCore

struct MidasUsageSyncCodecTests {
    private struct FixtureEnvelope: Codable, Equatable {
        let schemaVersion: Int
        let label: String
        let publications: [MidasUsageSyncPublication]
        let pendingLocal: MidasUsageSyncPublication?
    }

    private let now = Date(timeIntervalSince1970: 1_792_065_600)
    private let workspace = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!

    private func publication(count: Int = 1, accounts: Int = 0) -> MidasUsageSyncPublication {
        let day = MidasUsageSyncPublication.day(self.now)
        return MidasUsageSyncPublication(
            workspaceID: self.workspace,
            deviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            deviceName: #"Test "Mac" \ [Spark] 雪"#,
            publishedAt: self.now,
            events: (0..<count).map { index in
                MidasUsageSyncEvent(
                    id: String(format: "%064x", index),
                    provider: index.isMultiple(of: 2) ? .codex : .claude,
                    day: day,
                    observedAt: self.now,
                    values: .init(
                        tokens: index,
                        requests: index.isMultiple(of: 2) ? 0 : nil,
                        costUSD: index.isMultiple(of: 3) ? nil : Double(index) / 1_000_000,
                        apiEquivalentCostUSD: 0,
                        tokenMix: .init(inputTokens: index, outputTokens: 0),
                        provenance: .listPriceEstimate,
                        model: "gpt-5",
                        estimatedRequests: 1))
            },
            accountDays: (0..<accounts).map { index in
                MidasUsageSyncAccountDay(
                    accountScope: String(format: "%064x", index),
                    provider: .cursor,
                    day: day,
                    observedAt: self.now,
                    values: .init(tokens: 0, costUSD: 0, provenance: .vendorMetered))
            },
            excludedRecords: 7)
    }

    @Test func optionalUTF8BOMRemainsCompatibleWithFoundation() throws {
        let publication = self.publication(count: 513)
        let data = try Data([0xEF, 0xBB, 0xBF]) + (JSONEncoder().encode(publication))
        #expect(try MidasUsageSyncCodec.decodePublication(data)
            == JSONDecoder().decode(MidasUsageSyncPublication.self, from: data))
        let envelope = FixtureEnvelope(schemaVersion: 2, label: "BOM", publications: [publication], pendingLocal: nil)
        let encoded = try Data([0xEF, 0xBB, 0xBF]) + (JSONEncoder().encode(envelope))
        let decoded = try MidasUsageSyncCodec.decodeEnvelope(encoded)
        #expect(decoded.publications == envelope.publications)
        #expect(try JSONDecoder().decode(FixtureEnvelope.self, from: decoded.metadata).label == "BOM")
    }

    @Test func publicationBatchesMatchFoundationAcrossBoundaryAndAccountRows() throws {
        for count in [0, 1, 511, 512, 513, 1537] {
            let expected = self.publication(count: count, accounts: 513)
            let data = try JSONEncoder().encode(expected)
            let normal = try JSONDecoder().decode(MidasUsageSyncPublication.self, from: data)
            #expect(try MidasUsageSyncCodec.decodePublication(data) == normal)
        }
    }

    @Test func envelopeSeparatesBulkRecordsAndPreservesMetadataWithoutChangingDecodedFields() throws {
        let publication = self.publication(count: 513, accounts: 2)
        let expected = FixtureEnvelope(
            schemaVersion: 2,
            label: #"braces {} brackets [] escaped "quote" \ slash / 雪"#,
            publications: [publication],
            pendingLocal: publication)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(expected)
        let decoded = try MidasUsageSyncCodec.decodeEnvelope(data)
        let metadata = try JSONDecoder().decode(FixtureEnvelope.self, from: decoded.metadata)
        #expect(metadata.schemaVersion == expected.schemaVersion)
        #expect(metadata.label == expected.label)
        #expect(metadata.publications.isEmpty)
        #expect(metadata.pendingLocal == nil)
        #expect(decoded.publications == expected.publications)
        #expect(decoded.pendingLocal == expected.pendingLocal)
        let assembled = FixtureEnvelope(
            schemaVersion: metadata.schemaVersion,
            label: metadata.label,
            publications: decoded.publications,
            pendingLocal: decoded.pendingLocal)
        #expect(try assembled == (JSONDecoder().decode(FixtureEnvelope.self, from: data)))
    }

    @Test func unknownMetadataAndMissingOrNullOutboxStayCompatible() throws {
        for pending in ["", ",\"pendingLocal\":null"] {
            let data = Data(
                (
                    #"{"publications":[],"unknown":{"text":"\uD83D\uDE80 [] { } \\\"","numbers":["#
                        + #"-0,1.25e-3,true,false,null]},"é":"雪""#
                        + pending + "}").utf8)
            let decoded = try MidasUsageSyncCodec.decodeEnvelope(data)
            #expect(decoded.publications.isEmpty)
            #expect(decoded.pendingLocal == nil)
            let metadata = try #require(JSONSerialization.jsonObject(with: decoded.metadata) as? [String: Any])
            let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect((metadata["unknown"] as? NSDictionary) == (original["unknown"] as? NSDictionary))
            #expect(metadata["é"] as? String == "雪")
            #expect(metadata.keys.contains("pendingLocal") == !pending.isEmpty)
        }
    }

    @Test func escapedSchemaKeysAreRecognizedAndDuplicateDecodedKeysAreRejected() throws {
        let empty = try MidasUsageSyncCodec.decodeEnvelope(Data(#"{"publi\u0063ations":[]}"#.utf8))
        #expect(empty.publications.isEmpty)
        #expect(try #require(String(data: empty.metadata, encoding: .utf8)).contains(#""publi\u0063ations":[]"#))
        for text in [
            #"{"publications":[],"publications":[]}"#,
            #"{"publications":[],"publi\u0063ations":[]}"#,
            #"{"publications":[],"unknown":{"a":1,"\u0061":2}}"#,
            #"{"publications":[{"events":[{"id":"a","id":"b"}],"accountDays":[]}]}"#,
            #"{"publications":[{"events":[],"accountDays":[],"extra":{"a":0,"a":1}}]}"#,
        ] {
            #expect(throws: MidasUsageSyncError.invalidRecord) {
                try MidasUsageSyncCodec.decodeEnvelope(Data(text.utf8))
            }
        }
    }

    @Test func malformedGrammarWrongBulkTypesAndTrailingPayloadsAreRejected() {
        let malformed = [
            "", "null", "[]", "{}", #"{"publications":null}"#, #"{"publications":{}}"#,
            #"{"publications":[],}"#, #"{"publications":[,]}"#, #"{"publications":[null]}"#,
            #"{"publications":[]}true"#, #"{"publications":[],"pendingLocal":[]}"#,
            #"{"publications":[],"x":01}"#, #"{"publications":[],"x":1.}"#,
            #"{"publications":[],"x":1e}"#, #"{"publications":[],"x":-}"#,
            #"{"publications":[],"x":"\q"}"#, #"{"publications":[],"x":"\uD800"}"#,
            #"{"publications":[],"x":"\uDC00"}"#, #"{"publications":[],"x":"\uD800\u0041"}"#,
            #"{"publications":[{"events":[],"accountDays":[]}]}"#,
            #"{"publications":[{"events":[true],"accountDays":[]}]}"#,
        ]
        for text in malformed {
            #expect(throws: (any Error).self) { try MidasUsageSyncCodec.decodeEnvelope(Data(text.utf8)) }
        }
        let invalidUTF8 = Data(#"{"publications":[],"x":""#.utf8) + Data([0xC0, 0xAF]) + Data(#""}"#.utf8)
        #expect(throws: MidasUsageSyncError.invalidRecord) { try MidasUsageSyncCodec.decodeEnvelope(invalidUTF8) }
    }

    @Test func recordAndDeviceLimitsAreEnforcedBeforeTypedDecoding() {
        let rows = Array(repeating: "null", count: MidasUsageSyncPublication.maximumRecords + 1).joined(separator: ",")
        let oversized = Data((#"{"events":["# + rows + #"],"accountDays":[]}"#).utf8)
        #expect(throws: MidasUsageSyncError.limitExceeded) { try MidasUsageSyncCodec.decodePublication(oversized) }
        let mixedRows = Array(repeating: "null", count: MidasUsageSyncPublication.maximumRecords).joined(separator: ",")
        let mixed = Data((#"{"events":["# + mixedRows + #"],"accountDays":[null]}"#).utf8)
        #expect(throws: MidasUsageSyncError.limitExceeded) { try MidasUsageSyncCodec.decodePublication(mixed) }
        let publications = Array(repeating: #"{"events":[],"accountDays":[]}"#, count: 129).joined(separator: ",")
        #expect(throws: MidasUsageSyncError.limitExceeded) {
            try MidasUsageSyncCodec.decodeEnvelope(Data((#"{"publications":["# + publications + "]}").utf8))
        }
        let third = Array(repeating: "null", count: 84000).joined(separator: ",")
        let publication = #"{"events":["# + third + #"],"accountDays":[]}"#
        let combined = #"{"publications":["# + Array(repeating: publication, count: 3).joined(separator: ",") + "]}"
        #expect(throws: MidasUsageSyncError.limitExceeded) {
            try MidasUsageSyncCodec.decodeEnvelope(Data(combined.utf8))
        }
    }

    @Test func unknownExtensionsCannotBypassMetadataOrIndividualRecordByteBounds() {
        let primitives = Array(repeating: "0", count: 40000).joined(separator: ",")
        for text in [
            #"{"publications":[],"extension":["# + primitives + "]}",
            #"{"publications":[{"events":[],"accountDays":[],"extension":["# + primitives + "]}]}",
            #"{"publications":[{"events":[{"extension":["# + primitives + "]}],\"accountDays\":[]}]}",
            #"{"publications":[],""# + String(repeating: "k", count: 65536) + #"":0}"#,
            #"{"publications":[],"extension":"# + String(repeating: "[", count: 130)
                + "0" + String(repeating: "]", count: 130) + "}",
        ] {
            #expect(throws: MidasUsageSyncError.limitExceeded) {
                try MidasUsageSyncCodec.decodeEnvelope(Data(text.utf8))
            }
        }
    }

    @Test func byteBoundedBatchesPreserveOrdinaryUnknownRowExtensions() throws {
        let encoded = try JSONEncoder().encode(self.publication(count: 40))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var events = try #require(object["events"] as? [[String: Any]])
        for index in events.indices {
            events[index]["extension"] = String(repeating: #"[ \ " ] 雪"#, count: 2048)
        }
        object["events"] = events
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(data.count > 256 * 1024)
        #expect(try MidasUsageSyncCodec.decodePublication(data)
            == JSONDecoder().decode(MidasUsageSyncPublication.self, from: data))
    }

    @Test func schemaVersionsAndInvalidMeasurementsRemainForExistingValidationToReject() throws {
        var publication = self.publication()
        publication.schemaVersion = 99
        let decoded = try MidasUsageSyncCodec.decodePublication(JSONEncoder().encode(publication))
        #expect(decoded.schemaVersion == 99)
        #expect(throws: MidasUsageSyncError.unsupportedSchema) {
            try decoded.validate(workspaceID: self.workspace, now: self.now)
        }
    }
}
