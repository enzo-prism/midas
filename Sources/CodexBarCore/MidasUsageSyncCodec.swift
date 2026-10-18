import Foundation

/// Decodes large numeric snapshots without building one Foundation JSON index for the entire history.
/// Structural scanning retains only record byte ranges; temporary decoder graphs are bounded to 512 rows / 256 KiB.
/// Metadata and individual records are capped at 64 KiB, including unknown extension fields.
public enum MidasUsageSyncCodec {
    public struct Envelope: Sendable {
        public let metadata: Data
        public let publications: [MidasUsageSyncPublication]
        public let pendingLocal: MidasUsageSyncPublication?
    }

    private static let maximumInputBytes = 128 * 1024 * 1024
    private static let maximumPublications = 128
    private static let maximumCombinedRecords = 250_000
    private static let batchSize = 512
    private static let maximumMetadataBytes = 64 * 1024
    private static let maximumRecordBytes = 64 * 1024
    private static let maximumBatchBytes = 256 * 1024

    public static func decodeEnvelope(_ data: Data) throws -> Envelope {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw MidasUsageSyncError.invalidRecord }
        guard data.count <= self.maximumInputBytes else { throw MidasUsageSyncError.limitExceeded }
        return try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var scanner = Scanner(bytes: bytes)
            let parts = try scanner.envelope()
            try scanner.finish()
            let metadata = try self.metadata(parts.fields, bytes: bytes, replacing: [
                "publications": "[]", "pendingLocal": "null",
            ])
            let publications = try parts.publications.map { try self.decode($0, bytes: bytes) }
            let pending = try parts.pending.map { try self.decode($0, bytes: bytes) }
            return Envelope(
                metadata: metadata,
                publications: publications,
                pendingLocal: pending)
        }
    }

    public static func decodePublication(_ data: Data) throws -> MidasUsageSyncPublication {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw MidasUsageSyncError.invalidRecord }
        guard data.count <= MidasUsageSyncPublication.maximumFileBytes else {
            throw MidasUsageSyncError.limitExceeded
        }
        return try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var scanner = Scanner(bytes: bytes)
            let parts = try scanner.publication(depth: 0)
            try scanner.finish()
            return try self.decode(parts, bytes: bytes)
        }
    }

    private struct Field {
        let key: String
        let name: Range<Int>
        let value: Range<Int>
    }

    private struct PublicationParts {
        let fields: [Field]
        let events: [Range<Int>]
        let accounts: [Range<Int>]

        var count: Int {
            self.events.count + self.accounts.count
        }
    }

    private struct EnvelopeParts {
        let fields: [Field]
        let publications: [PublicationParts]
        let pending: PublicationParts?
    }

    private static func metadata(
        _ fields: [Field], bytes: UnsafeBufferPointer<UInt8>, replacing replacements: [String: String]) throws -> Data
    {
        let count = fields.reduce(2) { total, field in
            total + field.name.count + 2 + (replacements[field.key]?.utf8.count ?? field.value.count)
        }
        guard count <= self.maximumMetadataBytes else { throw MidasUsageSyncError.limitExceeded }
        var output = Data()
        output.reserveCapacity(count)
        output.append(123)
        for (index, field) in fields.enumerated() {
            if index > 0 { output.append(44) }
            output.append(contentsOf: bytes[field.name])
            output.append(58)
            if let replacement = replacements[field.key] {
                output.append(contentsOf: replacement.utf8)
            } else {
                output.append(contentsOf: bytes[field.value])
            }
        }
        output.append(125)
        return output
    }

    private static func decode(
        _ parts: PublicationParts, bytes: UnsafeBufferPointer<UInt8>) throws -> MidasUsageSyncPublication
    {
        let headerData = try self.metadata(parts.fields, bytes: bytes, replacing: ["events": "[]", "accountDays": "[]"])
        let header = try autoreleasepool {
            try JSONDecoder().decode(MidasUsageSyncPublication.self, from: headerData)
        }
        let events: [MidasUsageSyncEvent] = try self.rows(parts.events, bytes: bytes)
        let accounts: [MidasUsageSyncAccountDay] = try self.rows(parts.accounts, bytes: bytes)
        return MidasUsageSyncPublication(
            workspaceID: header.workspaceID,
            deviceID: header.deviceID,
            deviceName: header.deviceName,
            publishedAt: header.publishedAt,
            events: events,
            accountDays: accounts,
            excludedRecords: header.excludedRecords,
            schemaVersion: header.schemaVersion)
    }

    private static func rows<Row: Decodable>(
        _ ranges: [Range<Int>], bytes: UnsafeBufferPointer<UInt8>) throws -> [Row]
    {
        var output: [Row] = []
        output.reserveCapacity(ranges.count)
        var start = 0
        while start < ranges.count {
            try Task.checkCancellation()
            var end = start
            var byteCount = 2
            while end < ranges.count, end - start < self.batchSize {
                let nextCount = byteCount + ranges[end].count + (end == start ? 0 : 1)
                if nextCount > self.maximumBatchBytes { break }
                byteCount = nextCount
                end += 1
            }
            guard end > start else { throw MidasUsageSyncError.limitExceeded }
            let batch = ranges[start..<end]
            let decoded: [Row] = try autoreleasepool {
                var data = Data()
                data.reserveCapacity(byteCount)
                data.append(91)
                for (index, range) in batch.enumerated() {
                    if index > 0 { data.append(44) }
                    data.append(contentsOf: bytes[range])
                }
                data.append(93)
                return try JSONDecoder().decode([Row].self, from: data)
            }
            output.append(contentsOf: decoded)
            start = end
        }
        return output
    }

    /// The scanner validates JSON grammar, Unicode, and duplicate keys at every object depth.
    /// It never creates a String or a Foundation object graph for a complete payload or transcript.
    private struct Scanner {
        let bytes: UnsafeBufferPointer<UInt8>
        private var offset = 0
        private var valueLimit: Int
        private static let maximumDepth = 128
        private static let maximumObjectFields = 4096

        init(bytes: UnsafeBufferPointer<UInt8>) {
            self.bytes = bytes
            self.valueLimit = bytes.count
            // Foundation accepts an optional UTF-8 BOM. Preserve it without
            // copying or converting the complete input into a String.
            if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
                self.offset = 3
            }
        }

        mutating func envelope() throws -> EnvelopeParts {
            try self.expect(123)
            var fields: [Field] = []
            var keys: Set<String> = []
            var publications: [PublicationParts]?
            var pending: PublicationParts?
            if !self.consume(125) {
                repeat {
                    let (key, name) = try self.key(in: &keys)
                    let start = self.offset
                    if key == "publications" {
                        publications = try self.publicationArray()
                    } else if key == "pendingLocal" {
                        if self.current == 110 {
                            try self.literal([110, 117, 108, 108])
                        } else {
                            pending = try self.publication(depth: 1)
                        }
                    } else {
                        try self.boundedValue(depth: 1, maximumBytes: MidasUsageSyncCodec.maximumMetadataBytes)
                    }
                    fields.append(Field(key: key, name: name, value: start..<self.offset))
                } while try !self.endMember(125)
            }
            guard let publications else { throw MidasUsageSyncError.invalidRecord }
            return EnvelopeParts(fields: fields, publications: publications, pending: pending)
        }

        private mutating func publicationArray() throws -> [PublicationParts] {
            try self.expect(91)
            var output: [PublicationParts] = []
            var records = 0
            if self.consume(93) { return output }
            repeat {
                guard output.count < MidasUsageSyncCodec.maximumPublications else {
                    throw MidasUsageSyncError.limitExceeded
                }
                let publication = try self.publication(depth: 2)
                records += publication.count
                guard records <= MidasUsageSyncCodec.maximumCombinedRecords else {
                    throw MidasUsageSyncError.limitExceeded
                }
                output.append(publication)
            } while try !self.endMember(93)
            return output
        }

        mutating func publication(depth: Int) throws -> PublicationParts {
            let beginning = self.offset
            try self.expect(123)
            var fields: [Field] = []
            var keys: Set<String> = []
            var events: [Range<Int>]?
            var accounts: [Range<Int>]?
            if !self.consume(125) {
                repeat {
                    let (key, name) = try self.key(in: &keys)
                    let start = self.offset
                    switch key {
                    case "events":
                        events = try self.records(
                            depth: depth + 1,
                            remaining: MidasUsageSyncPublication.maximumRecords
                                - (accounts?.count ?? 0))
                    case "accountDays":
                        accounts = try self.records(
                            depth: depth + 1,
                            remaining: MidasUsageSyncPublication.maximumRecords
                                - (events?.count ?? 0))
                    default:
                        try self.boundedValue(
                            depth: depth + 1, maximumBytes: MidasUsageSyncCodec.maximumMetadataBytes)
                    }
                    guard self.offset - beginning <= MidasUsageSyncPublication.maximumFileBytes else {
                        throw MidasUsageSyncError.limitExceeded
                    }
                    fields.append(Field(key: key, name: name, value: start..<self.offset))
                } while try !self.endMember(125)
            }
            guard self.offset - beginning <= MidasUsageSyncPublication.maximumFileBytes else {
                throw MidasUsageSyncError.limitExceeded
            }
            guard let events, let accounts else { throw MidasUsageSyncError.invalidRecord }
            return PublicationParts(fields: fields, events: events, accounts: accounts)
        }

        private mutating func records(depth: Int, remaining: Int) throws -> [Range<Int>] {
            try self.expect(91)
            var ranges: [Range<Int>] = []
            if self.consume(93) { return ranges }
            repeat {
                guard ranges.count < remaining else { throw MidasUsageSyncError.limitExceeded }
                let start = self.offset
                try self.boundedValue(depth: depth + 1, maximumBytes: MidasUsageSyncCodec.maximumRecordBytes)
                ranges.append(start..<self.offset)
            } while try !self.endMember(93)
            return ranges
        }

        mutating func finish() throws {
            self.whitespace()
            guard self.offset == self.bytes.count else { throw MidasUsageSyncError.invalidRecord }
        }

        private var current: UInt8? {
            self.offset < self.bytes.count ? self.bytes[self.offset] : nil
        }

        private mutating func whitespace() {
            while let byte = self.current, byte == 32 || byte == 9 || byte == 10 || byte == 13 {
                self.offset += 1
            }
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            self.whitespace()
            guard self.current == byte else { return false }
            self.offset += 1
            return true
        }

        private mutating func expect(_ byte: UInt8) throws {
            guard self.consume(byte) else { throw MidasUsageSyncError.invalidRecord }
            self.whitespace()
        }

        private mutating func endMember(_ closing: UInt8) throws -> Bool {
            if self.consume(closing) { return true }
            try self.expect(44)
            return false
        }

        private mutating func key(in keys: inout Set<String>) throws -> (String, Range<Int>) {
            guard keys.count < Self.maximumObjectFields else { throw MidasUsageSyncError.limitExceeded }
            let start = self.offset
            let escaped = try self.string()
            let end = self.offset
            guard end - start <= MidasUsageSyncCodec.maximumMetadataBytes else {
                throw MidasUsageSyncError.limitExceeded
            }
            let key: String
            if escaped {
                key = try autoreleasepool {
                    try JSONDecoder().decode(String.self, from: Data(self.bytes[start..<end]))
                }
            } else {
                guard let decoded = String(bytes: self.bytes[(start + 1)..<(end - 1)], encoding: .utf8) else {
                    throw MidasUsageSyncError.invalidRecord
                }
                key = decoded
            }
            guard keys.insert(key).inserted else { throw MidasUsageSyncError.invalidRecord }
            try self.expect(58)
            return (key, start..<end)
        }

        private mutating func boundedValue(depth: Int, maximumBytes: Int) throws {
            let previousLimit = self.valueLimit
            self.valueLimit = min(previousLimit, self.offset + maximumBytes)
            defer { self.valueLimit = previousLimit }
            try self.value(depth: depth)
            guard self.offset <= self.valueLimit else { throw MidasUsageSyncError.limitExceeded }
        }

        private mutating func value(depth: Int) throws {
            guard depth <= Self.maximumDepth else { throw MidasUsageSyncError.limitExceeded }
            self.whitespace()
            guard self.offset < self.valueLimit else { throw MidasUsageSyncError.limitExceeded }
            guard let byte = self.current else { throw MidasUsageSyncError.invalidRecord }
            switch byte {
            case 123:
                try self.expect(123)
                var keys: Set<String> = []
                if self.consume(125) { return }
                repeat {
                    _ = try self.key(in: &keys)
                    try self.value(depth: depth + 1)
                } while try !self.endMember(125)
            case 91:
                try self.expect(91)
                if self.consume(93) { return }
                repeat {
                    try self.value(depth: depth + 1)
                } while try !self.endMember(93)
            case 34: _ = try self.string()
            case 110: try self.literal([110, 117, 108, 108])
            case 116: try self.literal([116, 114, 117, 101])
            case 102: try self.literal([102, 97, 108, 115, 101])
            case 45, 48...57: try self.number()
            default: throw MidasUsageSyncError.invalidRecord
            }
        }

        private mutating func literal(_ value: [UInt8]) throws {
            guard self.bytes.count - self.offset >= value.count else { throw MidasUsageSyncError.invalidRecord }
            for byte in value {
                guard self.current == byte else { throw MidasUsageSyncError.invalidRecord }
                self.offset += 1
            }
        }

        private mutating func number() throws {
            if self.current == 45 { self.offset += 1 }
            if self.current == 48 {
                self.offset += 1
            } else {
                guard let byte = self.current, (49...57).contains(byte) else {
                    throw MidasUsageSyncError.invalidRecord
                }
                try self.digits()
            }
            if self.current == 46 {
                self.offset += 1
                guard let byte = self.current, (48...57).contains(byte) else {
                    throw MidasUsageSyncError.invalidRecord
                }
                try self.digits()
            }
            if self.current == 69 || self.current == 101 {
                self.offset += 1
                if self.current == 43 || self.current == 45 { self.offset += 1 }
                guard let byte = self.current, (48...57).contains(byte) else {
                    throw MidasUsageSyncError.invalidRecord
                }
                try self.digits()
            }
        }

        private mutating func digits() {
            while let byte = self.current, (48...57).contains(byte) {
                self.offset += 1
            }
        }

        /// Consumes a JSON string and validates raw UTF-8 and escaped Unicode scalar pairs.
        @discardableResult
        private mutating func string() throws -> Bool {
            guard self.current == 34 else { throw MidasUsageSyncError.invalidRecord }
            self.offset += 1
            var escaped = false
            while let byte = self.current {
                guard self.offset < self.valueLimit else { throw MidasUsageSyncError.limitExceeded }
                if byte == 34 { self.offset += 1; return escaped }
                guard byte >= 32 else { throw MidasUsageSyncError.invalidRecord }
                if byte == 92 {
                    escaped = true
                    self.offset += 1
                    guard let next = self.current else { throw MidasUsageSyncError.invalidRecord }
                    self.offset += 1
                    if next == 117 {
                        let scalar = try self.hexScalar()
                        if (0xD800...0xDBFF).contains(scalar) {
                            guard self.current == 92 else { throw MidasUsageSyncError.invalidRecord }
                            self.offset += 1
                            guard self.current == 117 else { throw MidasUsageSyncError.invalidRecord }
                            self.offset += 1
                            guard try (0xDC00...0xDFFF).contains(self.hexScalar()) else {
                                throw MidasUsageSyncError.invalidRecord
                            }
                        } else if (0xDC00...0xDFFF).contains(scalar) {
                            throw MidasUsageSyncError.invalidRecord
                        }
                    } else if ![34, 92, 47, 98, 102, 110, 114, 116].contains(next) {
                        throw MidasUsageSyncError.invalidRecord
                    }
                } else if byte < 128 {
                    self.offset += 1
                } else {
                    try self.utf8Scalar()
                }
            }
            throw MidasUsageSyncError.invalidRecord
        }

        private mutating func hexScalar() throws -> UInt16 {
            var value: UInt16 = 0
            for _ in 0..<4 {
                guard let byte = self.current else { throw MidasUsageSyncError.invalidRecord }
                let digit: UInt8
                switch byte {
                case 48...57: digit = byte - 48
                case 65...70: digit = byte - 55
                case 97...102: digit = byte - 87
                default: throw MidasUsageSyncError.invalidRecord
                }
                value = value * 16 + UInt16(digit)
                self.offset += 1
            }
            return value
        }

        private mutating func utf8Scalar() throws {
            guard let first = self.current else { throw MidasUsageSyncError.invalidRecord }
            let count: Int
            let minimum: UInt32
            var scalar: UInt32
            switch first {
            case 0xC2...0xDF: count = 2; minimum = 0x80; scalar = UInt32(first & 0x1F)
            case 0xE0...0xEF: count = 3; minimum = 0x800; scalar = UInt32(first & 0x0F)
            case 0xF0...0xF4: count = 4; minimum = 0x10000; scalar = UInt32(first & 0x07)
            default: throw MidasUsageSyncError.invalidRecord
            }
            guard self.bytes.count - self.offset >= count else { throw MidasUsageSyncError.invalidRecord }
            self.offset += 1
            for _ in 1..<count {
                guard let byte = self.current, (0x80...0xBF).contains(byte) else {
                    throw MidasUsageSyncError.invalidRecord
                }
                scalar = scalar * 64 + UInt32(byte & 0x3F)
                self.offset += 1
            }
            guard scalar >= minimum, scalar <= 0x10FFFF, !(0xD800...0xDFFF).contains(scalar) else {
                throw MidasUsageSyncError.invalidRecord
            }
        }
    }
}
