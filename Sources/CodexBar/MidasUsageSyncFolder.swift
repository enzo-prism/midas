import CodexBarCore
import Darwin
import Foundation

/// A user-selected private folder carries numeric publications. Saving here does not prove cloud delivery.
enum MidasUsageSyncFolder {
    struct Result: Sendable {
        let workspace: MidasUsageSyncWorkspace
        let publications: [MidasUsageSyncPublication]
        let publicationSucceeded: Bool
        let unavailableFiles: Int
        let rejectedFiles: Int
    }

    static let maximumDevices = 128
    private static let maximumExchangeBytes = 128 * 1024 * 1024
    private static let maximumExchangeRecords = 250_000
    private static let maximumEntries = 512
    private static let maximumWorkspaceBytes = 4096
    private static let queue = DispatchQueue(
        label: MidasIdentity.bundleIdentifier + ".usage-sync-folder",
        qos: .utility)

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

    static func workspace(at folder: URL) async throws -> MidasUsageSyncWorkspace {
        try await self.perform(at: folder) { directory, cancellation in
            try self.loadWorkspace(directory: directory, create: true, cancellation: cancellation)
        }
    }

    static func exchange(
        at folder: URL,
        workspace: MidasUsageSyncWorkspace,
        local: MidasUsageSyncPublication?,
        now: Date = Date(),
        elapsedTime: (@Sendable () -> Duration)? = nil) async throws -> Result
    {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let elapsed: @Sendable () -> Duration = elapsedTime ?? { startedAt.duration(to: clock.now) }
        let validationTime: @Sendable () -> Date = {
            let duration = max(.zero, elapsed()).components
            return now.addingTimeInterval(Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
        }
        try workspace.validate()
        try local?.validate(workspaceID: workspace.id, now: now)
        return try await self.perform(at: folder) { directory, cancellation in
            let current = try self.loadWorkspace(directory: directory, create: false, cancellation: cancellation)
            guard current == workspace else { throw MidasUsageSyncError.wrongWorkspace }
            // Coordination can wait on a File Provider. Keep the caller's epoch and advance only elapsed time.
            try local?.validate(workspaceID: workspace.id, now: validationTime())
            let devices = directory.appendingPathComponent("devices", isDirectory: true)
            try self.ensureDevicesDirectory(in: directory)
            try self.validateDirectory(devices)
            var published = false
            if let local {
                try cancellation.check()
                do {
                    try self.publish(local, directory: devices, cancellation: cancellation)
                    published = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A read-only folder can still contribute previously received publications.
                    published = false
                }
            }
            let received = try self.readPublications(
                directory: devices,
                workspace: workspace,
                validationTime: validationTime,
                cancellation: cancellation)
            return Result(
                workspace: current,
                publications: received.publications,
                publicationSucceeded: published,
                unavailableFiles: received.unavailableFiles,
                rejectedFiles: received.rejectedFiles)
        }
    }

    private static func perform<Value: Sendable>(
        at folder: URL,
        operation: @escaping @Sendable (URL, Cancellation) throws -> Value) async throws -> Value
    {
        try Task.checkCancellation()
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.queue.async {
                    do {
                        try cancellation.check()
                        try self.validateDirectory(folder)
                        let coordinator = NSFileCoordinator(filePresenter: nil)
                        var coordinationError: NSError?
                        var outcome: Swift.Result<Value, Error>?
                        coordinator.coordinate(
                            writingItemAt: folder,
                            options: .forMerging,
                            error: &coordinationError)
                        { directory in
                            outcome = Swift.Result {
                                try cancellation.check()
                                try self.validateDirectory(folder)
                                // Resolve the coordinated URL only after validating the chosen path again.
                                let coordinated = try self.canonicalDirectory(directory)
                                guard try coordinated.path == (self.canonicalDirectory(folder)).path else {
                                    throw MidasUsageSyncError.folderUnavailable
                                }
                                try self.validateDirectory(coordinated)
                                return try operation(coordinated, cancellation)
                            }
                        }
                        try cancellation.check()
                        if let coordinationError { throw coordinationError }
                        guard let outcome else { throw MidasUsageSyncError.folderUnavailable }
                        continuation.resume(with: outcome)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func loadWorkspace(
        directory: URL, create: Bool, cancellation: Cancellation) throws -> MidasUsageSyncWorkspace
    {
        let file = directory.appendingPathComponent("workspace.json")
        let placeholder = directory.appendingPathComponent(".workspace.json.icloud")
        try cancellation.check()
        // Never initialize a second workspace while the original metadata is still in the cloud.
        if !self.exists(file), self.exists(placeholder) {
            try self.validateRegularFile(placeholder)
            try? FileManager.default.startDownloadingUbiquitousItem(at: file)
            throw MidasUsageSyncError.folderUnavailable
        }
        let entries = try self.entries(in: directory)
        let conflicts = entries.filter {
            let name = $0.lastPathComponent
            let metadataName = name.hasPrefix(".") ? String(name.dropFirst()) : name
            return name != "workspace.json" && name != ".workspace.json.icloud"
                && metadataName.hasPrefix("workspace") && (name.hasSuffix(".json") || name.hasSuffix(".json.icloud"))
        }
        // Cloud providers may preserve concurrent initializations as conflict copies.
        guard conflicts.isEmpty else { throw MidasUsageSyncError.wrongWorkspace }
        if !self.exists(file) {
            guard create else { throw MidasUsageSyncError.folderUnavailable }
            let workspace = MidasUsageSyncWorkspace()
            try cancellation.check()
            try self.atomicWrite(JSONEncoder().encode(workspace), to: file, replace: false)
        }
        guard NSFileVersion.unresolvedConflictVersionsOfItem(at: file)?.isEmpty ?? true else {
            throw MidasUsageSyncError.wrongWorkspace
        }
        let data = try self.read(file, maximumBytes: self.maximumWorkspaceBytes)
        let workspace = try JSONDecoder().decode(MidasUsageSyncWorkspace.self, from: data)
        try workspace.validate()
        return workspace
    }

    private static func publish(
        _ publication: MidasUsageSyncPublication, directory: URL, cancellation: Cancellation) throws
    {
        let destination = directory.appendingPathComponent(publication.deviceID.uuidString + ".json")
        if self.exists(destination) {
            try self.validateRegularFile(destination)
            if let existing = try? self.read(destination, maximumBytes: MidasUsageSyncPublication.maximumFileBytes),
               let decoded = try? JSONDecoder().decode(MidasUsageSyncPublication.self, from: existing),
               decoded == publication
            {
                return
            }
        }
        let data = try JSONEncoder().encode(publication)
        guard data.count <= MidasUsageSyncPublication.maximumFileBytes else {
            throw MidasUsageSyncError.limitExceeded
        }
        try cancellation.check()
        try self.atomicWrite(data, to: destination, replace: true)
    }

    private static func readPublications(
        directory: URL,
        workspace: MidasUsageSyncWorkspace,
        validationTime: @Sendable () -> Date,
        cancellation: Cancellation) throws -> Result
    {
        var publications: [MidasUsageSyncPublication] = []
        var unavailable = Set<UUID>()
        var rejected = 0
        var bytesRead = 0
        var recordsRead = 0
        var deviceIDs = Set<UUID>()
        let candidates = try self.entries(in: directory).filter {
            $0.pathExtension == "json" || $0.lastPathComponent.hasSuffix(".json.icloud")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard candidates.count <= self.maximumDevices * 2 else { throw MidasUsageSyncError.limitExceeded }
        for file in candidates {
            try cancellation.check()
            let placeholder = file.lastPathComponent.hasPrefix(".") && file.lastPathComponent.hasSuffix(".json.icloud")
            let name = placeholder ? String(file.lastPathComponent.dropFirst().dropLast(".icloud".count))
                : file.lastPathComponent
            guard let id = UUID(uuidString: String(name.dropLast(".json".count))),
                  name == id.uuidString + ".json"
            else {
                rejected += 1
                continue
            }
            deviceIDs.insert(id)
            guard deviceIDs.count <= self.maximumDevices else { throw MidasUsageSyncError.limitExceeded }
            do {
                try self.validateRegularFile(file)
                if placeholder {
                    let target = directory.appendingPathComponent(name)
                    try? FileManager.default.startDownloadingUbiquitousItem(at: target)
                    if !self.exists(target) { unavailable.insert(id) }
                    continue
                }
                let byteLimit = min(MidasUsageSyncPublication.maximumFileBytes, self.maximumExchangeBytes - bytesRead)
                let data = try self.read(file, maximumBytes: byteLimit)
                bytesRead += data.count
                let publication = try JSONDecoder().decode(MidasUsageSyncPublication.self, from: data)
                guard publication.deviceID == id else { throw MidasUsageSyncError.invalidRecord }
                try publication.validate(workspaceID: workspace.id, now: validationTime())
                let recordCount = publication.events.count + publication.accountDays.count
                guard recordCount <= self.maximumExchangeRecords - recordsRead else {
                    throw MidasUsageSyncError.limitExceeded
                }
                recordsRead += recordCount
                publications.append(publication)
                unavailable.remove(id)
            } catch MidasUsageSyncError.folderUnavailable {
                unavailable.insert(id)
            } catch let error as CocoaError where [.fileReadNoSuchFile, .fileReadNoPermission].contains(error.code) {
                unavailable.insert(id)
            } catch let error as POSIXError where [.ENOENT, .EACCES, .EPERM].contains(error.code) {
                unavailable.insert(id)
            } catch {
                rejected += 1
            }
        }
        return Result(
            workspace: workspace,
            publications: publications,
            publicationSucceeded: false,
            unavailableFiles: unavailable.count,
            rejectedFiles: rejected)
    }

    /// Enumerate lazily and stop at the limit, rather than allocating an unbounded directory listing.
    private static func entries(in directory: URL) throws -> [URL] {
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsSubdirectoryDescendants,
            errorHandler: { _, error in
                enumerationError = error
                return false
            })
        else {
            throw MidasUsageSyncError.folderUnavailable
        }
        var files: [URL] = []
        for case let file as URL in enumerator {
            guard files.count < self.maximumEntries else { throw MidasUsageSyncError.limitExceeded }
            files.append(file)
        }
        if enumerationError != nil { throw MidasUsageSyncError.folderUnavailable }
        return files
    }

    /// Reject links along the selected path as well as links standing in for workspace/device files.
    private static func validateDirectory(_ directory: URL) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"),
              !directory.pathComponents.contains("."), !directory.pathComponents.contains("..")
        else { throw MidasUsageSyncError.unsafeFile }
        var path = URL(fileURLWithPath: "/", isDirectory: true)
        for component in directory.pathComponents.dropFirst() {
            path.appendPathComponent(component, isDirectory: true)
            let values: URLResourceValues
            do {
                values = try path.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            } catch {
                throw MidasUsageSyncError.folderUnavailable
            }
            guard values.isSymbolicLink != true else { throw MidasUsageSyncError.unsafeFile }
            guard values.isDirectory == true else { throw MidasUsageSyncError.folderUnavailable }
        }
    }

    private static func canonicalDirectory(_ directory: URL) throws -> URL {
        guard let path = Darwin.realpath(directory.path, nil) else { throw MidasUsageSyncError.folderUnavailable }
        defer { Darwin.free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    private static func validateRegularFile(_ file: URL) throws {
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw MidasUsageSyncError.unsafeFile
        }
    }

    private static func exists(_ file: URL) -> Bool {
        // resourceValues notices dangling symlinks, unlike fileExists(atPath:).
        (try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])) != nil
    }

    private static func read(_ file: URL, maximumBytes: Int) throws -> Data {
        let values = try file.resourceValues(forKeys: [
            .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .ubiquitousItemDownloadingStatusKey,
        ])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw MidasUsageSyncError.unsafeFile
        }
        if values.ubiquitousItemDownloadingStatus == .notDownloaded {
            try? FileManager.default.startDownloadingUbiquitousItem(at: file)
            throw MidasUsageSyncError.folderUnavailable
        }
        guard let size = values.fileSize, size > 0, size <= maximumBytes else {
            throw MidasUsageSyncError.limitExceeded
        }
        let parent = try self.openDirectory(file.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        let descriptor = Darwin.openat(parent, file.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw self.posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw MidasUsageSyncError.unsafeFile
        }
        guard info.st_size > 0, info.st_size <= maximumBytes else { throw MidasUsageSyncError.limitExceeded }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumBytes else { throw MidasUsageSyncError.limitExceeded }
        return data
    }

    private static func atomicWrite(_ data: Data, to destination: URL, replace: Bool) throws {
        let parent = try self.openDirectory(destination.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        let temporary = ".midas-" + UUID().uuidString
        let descriptor = Darwin.openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw self.posixError() }
        defer { Darwin.unlinkat(parent, temporary, 0) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        guard fsync(descriptor) == 0 else { throw self.posixError() }
        if replace {
            var info = stat()
            if fstatat(parent, destination.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG else { throw MidasUsageSyncError.unsafeFile }
            } else if errno != ENOENT {
                throw self.posixError()
            }
            guard Darwin.renameat(parent, temporary, parent, destination.lastPathComponent) == 0 else {
                throw self.posixError()
            }
        } else if renameatx_np(parent, temporary, parent, destination.lastPathComponent, UInt32(RENAME_EXCL)) != 0 {
            // A concurrent initializer won. Read its workspace rather than replacing it.
            guard errno == EEXIST else { throw self.posixError() }
        }
    }

    /// Open each directory relative to a stable descriptor so a concurrent link swap cannot redirect file IO.
    private static func openDirectory(_ directory: URL) throws -> Int32 {
        guard directory.isFileURL, !directory.pathComponents.contains("."),
              !directory.pathComponents.contains("..")
        else {
            throw MidasUsageSyncError.unsafeFile
        }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw self.posixError() }
        for component in directory.pathComponents.dropFirst() {
            let child = Darwin.openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let failure = errno
            Darwin.close(descriptor)
            guard child >= 0 else {
                if failure == ELOOP || failure == ENOTDIR { throw MidasUsageSyncError.unsafeFile }
                throw MidasUsageSyncError.folderUnavailable
            }
            descriptor = child
        }
        return descriptor
    }

    private static func ensureDevicesDirectory(in directory: URL) throws {
        let parent = try self.openDirectory(directory)
        defer { Darwin.close(parent) }
        var info = stat()
        if fstatat(parent, "devices", &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw MidasUsageSyncError.unsafeFile }
        } else {
            guard errno == ENOENT else { throw self.posixError() }
            if mkdirat(parent, "devices", 0o700) != 0, errno != EEXIST { throw self.posixError() }
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
