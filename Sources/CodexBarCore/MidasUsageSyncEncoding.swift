import Foundation

/// Keeps numeric-history encoding transient graphs small while preserving JSONEncoder's default representation.
public enum MidasUsageSyncEncoding {
    private static let maximumEnvelopeBytes = 128 * 1024 * 1024
    private static let maximumMetadataBytes = 64 * 1024
    private static let maximumRecordBytes = 64 * 1024
    private static let maximumBatchBytes = 256 * 1024
    private static let maximumBatchRows = 512

    public static func encodePublication(_ publication: MidasUsageSyncPublication) throws -> Data {
        try self.validateCount(publication)
        var output = Output(limit: MidasUsageSyncPublication.maximumFileBytes, storesBytes: true)
        output.reserveCapacity(self.reservation(records: publication.events.count + publication.accountDays.count))
        try self.publication(publication, into: &output)
        return output.data ?? Data()
    }

    /// Uses the same byte-emission path as encoding, without retaining a complete serialized publication.
    public static func encodedPublicationSize(_ publication: MidasUsageSyncPublication) throws -> Int {
        try self.validateCount(publication)
        var output = Output(limit: MidasUsageSyncPublication.maximumFileBytes, storesBytes: false)
        try self.publication(publication, into: &output)
        return output.count
    }

    /// Metadata contains all ordinary envelope fields, without publications or pendingLocal.
    /// A nil outbox is omitted, matching synthesized Codable optional-field behavior.
    public static func encodeEnvelope(
        metadata: Data,
        publications: [MidasUsageSyncPublication],
        pendingLocal: MidasUsageSyncPublication?) throws -> Data
    {
        try Task.checkCancellation()
        guard publications.count <= 128 else { throw MidasUsageSyncError.limitExceeded }
        var records = 0
        for publication in publications {
            try self.validateCount(publication)
            records += publication.events.count + publication.accountDays.count
            guard records <= 250_000 else { throw MidasUsageSyncError.limitExceeded }
        }
        if let pendingLocal { try self.validateCount(pendingLocal) }
        let content = try self.metadataContent(metadata)
        var output = Output(limit: self.maximumEnvelopeBytes, storesBytes: true)
        output.reserveCapacity(self.reservation(
            records: records + (pendingLocal.map { $0.events.count + $0.accountDays.count } ?? 0)))
        try output.append([123])
        if !content.isEmpty {
            try output.append(content)
            try output.append([44])
        }
        try output.append(Data(#""publications":["#.utf8))
        for (index, publication) in publications.enumerated() {
            if index > 0 { try output.append([44]) }
            try self.publication(publication, into: &output)
        }
        try output.append([93])
        if let pendingLocal {
            try output.append(Data(",\"pendingLocal\":".utf8))
            try self.publication(pendingLocal, into: &output)
        }
        try output.append([125])
        return output.data ?? Data()
    }

    private struct Header: Encodable {
        let schemaVersion: Int
        let workspaceID: UUID
        let deviceID: UUID
        let deviceName: String
        let publishedAt: Date
        let excludedRecords: Int

        init(_ publication: MidasUsageSyncPublication) {
            self.schemaVersion = publication.schemaVersion
            self.workspaceID = publication.workspaceID
            self.deviceID = publication.deviceID
            self.deviceName = publication.deviceName
            self.publishedAt = publication.publishedAt
            self.excludedRecords = publication.excludedRecords
        }
    }

    private struct Output {
        var limit: Int
        private(set) var data: Data?
        private(set) var count = 0

        init(limit: Int, storesBytes: Bool) {
            self.limit = limit
            self.data = storesBytes ? Data() : nil
        }

        mutating func reserveCapacity(_ bytes: Int) {
            self.data?.reserveCapacity(min(bytes, self.limit))
        }

        mutating func append(_ bytes: some Collection<UInt8>) throws {
            guard bytes.count <= self.limit - self.count else { throw MidasUsageSyncError.limitExceeded }
            self.count += bytes.count
            self.data?.append(contentsOf: bytes)
        }
    }

    private static func reservation(records: Int) -> Int {
        // Avoid repeated large Data-buffer growth. Only written pages become resident.
        min(self.maximumEnvelopeBytes, max(4096, records * 512))
    }

    private static func validateCount(_ publication: MidasUsageSyncPublication) throws {
        guard publication.events.count <= MidasUsageSyncPublication.maximumRecords,
              publication.accountDays.count <= MidasUsageSyncPublication.maximumRecords - publication.events.count
        else { throw MidasUsageSyncError.limitExceeded }
    }

    private static func publication(_ publication: MidasUsageSyncPublication, into output: inout Output) throws {
        try Task.checkCancellation()
        let previousLimit = output.limit
        output.limit = min(previousLimit, output.count + MidasUsageSyncPublication.maximumFileBytes)
        defer { output.limit = previousLimit }
        guard publication.deviceName.utf8.count <= self.maximumMetadataBytes else {
            throw MidasUsageSyncError.limitExceeded
        }
        let encoder = JSONEncoder()
        let header = try autoreleasepool { try encoder.encode(Header(publication)) }
        guard header.count <= self.maximumMetadataBytes else { throw MidasUsageSyncError.limitExceeded }
        try output.append(header.dropLast())
        try output.append(Data(",\"events\":[".utf8))
        try self.rows(publication.events, encoder: encoder, into: &output) { row in
            try self.rowBound(row.id, row.day, row.values.model)
        }
        try output.append(Data("],\"accountDays\":[".utf8))
        try self.rows(publication.accountDays, encoder: encoder, into: &output) { row in
            try self.rowBound(row.accountScope, row.day, row.values.model)
        }
        try output.append([93, 125])
    }

    private static func rowBound(_ identity: String, _ day: String, _ model: String?) throws -> Int {
        let count = identity.utf8.count + day.utf8.count + (model?.utf8.count ?? 0)
        guard count <= self.maximumRecordBytes else { throw MidasUsageSyncError.limitExceeded }
        // All other fields are bounded-size keys, numbers, provider/provenance names and punctuation.
        // A UTF-8 byte may expand to six bytes when JSONEncoder escapes a control character.
        return 768 + count * 6
    }

    private static func rows<Row: Encodable>(
        _ rows: [Row],
        encoder: JSONEncoder,
        into output: inout Output,
        upperBound: (Row) throws -> Int) throws
    {
        var start = 0
        while start < rows.count {
            try Task.checkCancellation()
            var end = start
            var estimatedBytes = 2
            while end < rows.count, end - start < self.maximumBatchRows {
                let bound = try upperBound(rows[end])
                if end > start, bound > self.maximumRecordBytes || estimatedBytes + bound + 1 > self.maximumBatchBytes {
                    break
                }
                estimatedBytes += bound + 1
                end += 1
                if bound > self.maximumRecordBytes { break }
            }
            try autoreleasepool {
                let data = try encoder.encode(Array(rows[start..<end]))
                let content = data.dropFirst().dropLast()
                if end - start == 1, content.count > self.maximumRecordBytes {
                    throw MidasUsageSyncError.limitExceeded
                }
                guard data.count <= self.maximumBatchBytes else { throw MidasUsageSyncError.limitExceeded }
                try Task.checkCancellation()
                if start > 0 { try output.append([44]) }
                try output.append(content)
            }
            start = end
        }
    }

    private static func metadataContent(_ metadata: Data) throws -> Data {
        guard metadata.count <= self.maximumMetadataBytes else { throw MidasUsageSyncError.limitExceeded }
        return try metadata.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var first = 0
            var end = bytes.count
            while first < end, self.isWhitespace(bytes[first]) {
                first += 1
            }
            while end > first, self.isWhitespace(bytes[end - 1]) {
                end -= 1
            }
            guard end - first >= 2, bytes[first] == 123, bytes[end - 1] == 125 else {
                throw MidasUsageSyncError.invalidRecord
            }
            let inner = bytes[(first + 1)..<(end - 1)]
            let hasFields = inner.contains { !self.isWhitespace($0) }
            // Reuse the strict bounded scanner. Reserved fields are preinserted so an escaped or
            // duplicate bulk field is rejected before metadata can override the actual history.
            var inspection = Data(#"{"publications":[],"pendingLocal":null"#.utf8)
            if hasFields {
                inspection.append(44)
                inspection.append(contentsOf: inner)
            }
            inspection.append(125)
            _ = try autoreleasepool { try MidasUsageSyncCodec.decodeEnvelope(inspection) }
            return hasFields ? Data(inner) : Data()
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13
    }
}
