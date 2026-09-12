import Foundation

/// Exchanges derived pricing samples only. Samples from several Macs are selected, never added together.
enum MidasCalibrationExchange {
    struct Record: Codable, Sendable, Equatable {
        var schemaVersion = 1
        var methodVersion = 1
        let deviceID: UUID
        let scope: String
        let calibration: MidasCodexCalibration
    }

    struct ExchangeResult: Sendable {
        let records: [Record]
        let publicationFailed: Bool
    }

    private static let queue = DispatchQueue(label: "com.midas.calibration-exchange", qos: .utility)
    private static let maximumFileBytes = 65536
    private static let maximumFiles = 128

    static func winner(records: [Record], scope: String, now: Date) -> Record? {
        var devices: [UUID: Record] = [:]
        for record in records where record.scope == scope && self.isValid(record, now: now) {
            if let previous = devices[record.deviceID], !self.isNewer(record, than: previous) { continue }
            devices[record.deviceID] = record
        }
        return devices.values.min {
            if $0.calibration.pricedTokens != $1.calibration.pricedTokens {
                return $0.calibration.pricedTokens > $1.calibration.pricedTokens
            }
            if $0.calibration.sampledAt != $1.calibration.sampledAt {
                return $0.calibration.sampledAt > $1.calibration.sampledAt
            }
            return $0.deviceID.uuidString < $1.deviceID.uuidString
        }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            self.lock.lock()
            self.cancelled = true
            self.lock.unlock()
        }

        func check() throws {
            self.lock.lock()
            let cancelled = self.cancelled
            self.lock.unlock()
            if cancelled { throw CancellationError() }
        }
    }

    static func exchange(folder: URL, local: Record?, now: Date) async throws -> ExchangeResult {
        try Task.checkCancellation()
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.queue.async {
                    do {
                        try cancellation.check()
                        let result = try self.coordinatedExchange(
                            folder: folder, local: local, now: now, cancellation: cancellation)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func isValid(_ record: Record, now: Date) -> Bool {
        guard record.schemaVersion == 1, record.methodVersion == 1,
              record.scope.utf8.count == 64,
              record.scope.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              record.calibration.pricedTokens.isFinite, record.calibration.observedTokens.isFinite,
              record.calibration.estimate(now: now) != nil else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: record.calibration.lastUsageDay) else { return false }
        return formatter.string(from: date) == record.calibration.lastUsageDay
    }

    private static func isNewer(_ lhs: Record, than rhs: Record) -> Bool {
        if lhs.calibration.sampledAt != rhs.calibration.sampledAt {
            return lhs.calibration.sampledAt > rhs.calibration.sampledAt
        }
        if lhs.calibration.pricedTokens != rhs.calibration.pricedTokens {
            return lhs.calibration.pricedTokens > rhs.calibration.pricedTokens
        }
        if lhs.calibration.observedTokens != rhs.calibration.observedTokens {
            return lhs.calibration.observedTokens > rhs.calibration.observedTokens
        }
        if lhs.calibration.lastUsageDay != rhs.calibration.lastUsageDay {
            return lhs.calibration.lastUsageDay > rhs.calibration.lastUsageDay
        }
        return lhs.calibration.rate < rhs.calibration.rate
    }

    private static func coordinatedExchange(
        folder: URL, local: Record?, now: Date, cancellation: Cancellation) throws -> ExchangeResult
    {
        guard folder.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var records: [Record] = []
        var publicationFailed = false
        var operationError: Error?
        coordinator.coordinate(writingItemAt: folder, options: .forMerging, error: &coordinationError) { directory in
            let manager = FileManager.default
            if let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]),
               values.isSymbolicLink == true
            {
                operationError = CocoaError(.fileReadInvalidFileName)
                return
            }
            do {
                try cancellation.check()
                if !manager.fileExists(atPath: directory.path) {
                    try manager.createDirectory(at: directory, withIntermediateDirectories: false)
                }
                try cancellation.check()
                if let local {
                    do {
                        guard self.isValid(local, now: now) else { throw CocoaError(.fileWriteInvalidFileName) }
                        try self.publish(local, directory: directory)
                    } catch {
                        publicationFailed = true
                    }
                }
                records = try self.readRecords(directory: directory, now: now)
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
        return ExchangeResult(records: records, publicationFailed: publicationFailed)
    }

    private static func publish(_ record: Record, directory: URL) throws {
        let destination = directory.appendingPathComponent(record.deviceID.uuidString + ".json")
        let values = try? destination.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values?.isSymbolicLink != true, values?.isRegularFile != false else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if let size = values?.fileSize, size <= self.maximumFileBytes,
           let handle = try? FileHandle(forReadingFrom: destination)
        {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: self.maximumFileBytes + 1),
               data.count <= self.maximumFileBytes,
               let existing = try? JSONDecoder().decode(Record.self, from: data), existing == record
            {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                return
            }
        }
        let data = try JSONEncoder().encode(record)
        guard data.count <= self.maximumFileBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private static func requestPlaceholders(_ files: [URL]) {
        for file in files.prefix(self.maximumFiles) {
            let name = file.lastPathComponent
            guard name.hasPrefix("."), name.hasSuffix(".json.icloud"),
                  UUID(uuidString: String(name.dropFirst().dropLast(".json.icloud".count))) != nil,
                  let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { continue }
            let normalName = String(name.dropFirst().dropLast(".icloud".count))
            try? FileManager.default.startDownloadingUbiquitousItem(
                at: file.deletingLastPathComponent().appendingPathComponent(normalName))
        }
    }

    private static func readRecords(directory: URL, now: Date) throws -> [Record] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .ubiquitousItemDownloadingStatusKey,
        ]
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [])
        self.requestPlaceholders(files.filter { $0.lastPathComponent.hasSuffix(".json.icloud") })
        let candidates = files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return candidates.prefix(self.maximumFiles).compactMap { file in
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let values = try? file.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true else { return nil }
            if values.ubiquitousItemDownloadingStatus == .notDownloaded {
                try? FileManager.default.startDownloadingUbiquitousItem(at: file)
                return nil
            }
            guard values.isRegularFile == true, let size = values.fileSize,
                  size > 0, size <= self.maximumFileBytes,
                  let handle = try? FileHandle(forReadingFrom: file) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: self.maximumFileBytes + 1),
                  data.count <= self.maximumFileBytes,
                  let record = try? JSONDecoder().decode(Record.self, from: data), record.deviceID == id,
                  self.isValid(record, now: now) else { return nil }
            return record
        }
    }
}
