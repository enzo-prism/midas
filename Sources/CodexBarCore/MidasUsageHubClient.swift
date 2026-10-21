import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A per-device enrollment. The bearer credential is only for numeric usage sync, never a provider API key.
public struct MidasUsageHubConnection: Codable, Sendable, Equatable {
    public let endpoint: URL
    public let deviceID: UUID
    public let deviceName: String
    public let credential: String
    public let workspaceID: UUID?

    public init(endpoint: URL, deviceID: UUID, deviceName: String, credential: String, workspaceID: UUID? = nil) {
        self.endpoint = endpoint
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.credential = credential
        self.workspaceID = workspaceID
    }

    public func validate() throws {
        guard let parts = URLComponents(url: self.endpoint, resolvingAgainstBaseURL: false),
              let host = parts.host?.lowercased(), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port == nil || (1...65535).contains(parts.port!),
              (1...80).contains(self.deviceName.utf8.count),
              !self.deviceName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (32...256).contains(self.credential.utf8.count),
              self.credential.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
              })
        else { throw MidasUsageHubError.invalidConnection }
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        let privateHTTPS = parts.scheme == "https" && host.hasSuffix(".ts.net") && host.count > ".ts.net".count
        guard privateHTTPS || (parts.scheme == "http" && loopback) else {
            throw MidasUsageHubError.invalidConnection
        }
    }
}

public struct MidasUsageHubExchange: Codable, Sendable, Equatable {
    public let workspace: MidasUsageSyncWorkspace
    public let publications: [MidasUsageSyncPublication]
    public let publicationSucceeded: Bool
    public let unavailableFiles: Int
    public let rejectedFiles: Int
    public let syncState: MidasUsageHubSyncState?

    public init(
        workspace: MidasUsageSyncWorkspace,
        publications: [MidasUsageSyncPublication],
        publicationSucceeded: Bool,
        unavailableFiles: Int,
        rejectedFiles: Int,
        syncState: MidasUsageHubSyncState? = nil)
    {
        self.workspace = workspace
        self.publications = publications
        self.publicationSucceeded = publicationSucceeded
        self.unavailableFiles = unavailableFiles
        self.rejectedFiles = rejectedFiles
        self.syncState = syncState
    }
}

public enum MidasUsageHubError: Error, LocalizedError, Sendable, Equatable {
    case invalidConnection
    case unauthorized
    case rejectedSnapshot
    case responseTooLarge
    case invalidResponse
    case unavailable
    case unsafeConnectionFile
    case unsupportedProtocol
    case incompatibleProtocol
    case timedOut
    case nameResolutionFailed
    case secureConnectionFailed
    case corruptCache
    case revisionExpired

    public var errorDescription: String? {
        switch self {
        case .invalidConnection: "Choose a valid private Tailscale hub connection file."
        case .unauthorized: "The hub credential was revoked or is not valid. Enroll this device again."
        case .rejectedSnapshot: "The hub rejected an older or conflicting snapshot. Local usage is retained."
        case .responseTooLarge: "The hub response exceeds the usage sync safety limits."
        case .invalidResponse: "The hub returned usage that could not be validated."
        case .unavailable: "The private usage hub is unavailable. Your last received usage is retained."
        case .unsafeConnectionFile: "The hub connection file must be a private, owned, regular file with mode 600."
        case .unsupportedProtocol: "This hub does not support incremental usage sync."
        case .incompatibleProtocol: "Update Midas or its private hub to a compatible version."
        case .timedOut: "The usage sync transfer exceeded its time limit. Local changes are saved for retry."
        case .nameResolutionFailed: "The private hub name could not be resolved. Check Tailscale."
        case .secureConnectionFailed: "The private hub’s secure connection could not be verified."
        case .revisionExpired: "The selected hub checkpoint expired. Sync will resume from a fresh checkpoint."
        case .corruptCache: "The local transport cache needs repair. Unacknowledged usage is retained."
        }
    }
}

/// Negotiates incremental v2 exchange while preserving old hubs and the v1 validation contract.
public enum MidasUsageHubClient {
    public static let maximumDevices = 128
    public static let maximumExchangeBytes = 128 * 1024 * 1024
    public static let maximumExchangeRecords = 250_000

    public static func workspace(connection: MidasUsageHubConnection) async throws -> MidasUsageSyncWorkspace {
        let data = try await self.request(connection: connection, path: "v1/workspace", body: nil, limit: 4096)
        let workspace: MidasUsageSyncWorkspace
        do {
            workspace = try autoreleasepool { try JSONDecoder().decode(MidasUsageSyncWorkspace.self, from: data) }
            try workspace.validate()
        } catch { throw MidasUsageHubError.invalidResponse }
        if let expected = connection.workspaceID, workspace.id != expected {
            throw MidasUsageSyncError.wrongWorkspace
        }
        return workspace
    }

    public static func exchange(
        connection: MidasUsageHubConnection,
        workspace: MidasUsageSyncWorkspace,
        local: MidasUsageSyncPublication?,
        now: Date = Date(),
        stateRoot: URL? = nil) async throws -> MidasUsageHubExchange
    {
        try connection.validate()
        try workspace.validate()
        if let expected = connection.workspaceID, expected != workspace.id {
            throw MidasUsageSyncError.wrongWorkspace
        }
        try local?.validateCanonical(workspaceID: workspace.id, now: now)
        if let local, local.deviceID != connection.deviceID || local.deviceName != connection.deviceName {
            throw MidasUsageHubError.invalidConnection
        }
        do {
            return try await MidasUsageHubTransportV2.exchange(
                connection: connection, workspace: workspace, local: local, now: now, stateRoot: stateRoot)
        } catch MidasUsageHubError.unsupportedProtocol {
            // Only an absent initial manifest route permits downgrade. Invalid v2 data never does.
        }
        let legacy = local.map { self.legacyPublication($0) }
        try legacy?.validate(workspaceID: workspace.id, now: now)
        let body = try legacy.map { try MidasUsageSyncEncoding.encodePublication($0) } ?? Data("null".utf8)
        guard body.count <= MidasUsageSyncPublication.maximumFileBytes else {
            throw MidasUsageSyncError.limitExceeded
        }
        let clock = ContinuousClock()
        let started = clock.now
        let data = try await self.request(
            connection: connection, path: "v1/exchange", body: body, limit: self.maximumExchangeBytes)
        let elapsed = started.duration(to: clock.now).components
        let validationTime = now.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        return try self.validatedExchange(
            data, connection: connection, workspace: workspace, local: legacy, now: validationTime)
    }

    /// The old wire schema has a closed values whitelist. New metadata stays in canonical state.
    static func legacyPublication(_ publication: MidasUsageSyncPublication) -> MidasUsageSyncPublication {
        let legacy = MidasUsageSyncLedger.retainingLocalHistory(previous: nil, fresh: publication)
        func values(_ value: MidasUsageSyncValues) -> MidasUsageSyncValues {
            MidasUsageSyncValues(
                tokens: value.tokens,
                requests: value.requests,
                costUSD: value.costUSD,
                apiEquivalentCostUSD: value.apiEquivalentCostUSD,
                tokenMix: value.tokenMix,
                provenance: value.provenance,
                model: value.model,
                unpricedRequests: value.unpricedRequests,
                estimatedRequests: value.estimatedRequests)
        }
        return MidasUsageSyncPublication(
            workspaceID: legacy.workspaceID,
            deviceID: legacy.deviceID,
            deviceName: legacy.deviceName,
            publishedAt: legacy.publishedAt,
            events: legacy.events.map {
                MidasUsageSyncEvent(
                    id: $0.id,
                    provider: $0.provider,
                    day: $0.day,
                    observedAt: $0.observedAt,
                    values: values($0.values))
            },
            accountDays: legacy.accountDays.map {
                MidasUsageSyncAccountDay(
                    accountScope: $0.accountScope,
                    provider: $0.provider,
                    day: $0.day,
                    observedAt: $0.observedAt,
                    values: values($0.values))
            },
            excludedRecords: legacy.excludedRecords)
    }

    public static func acknowledgeApplied(
        connection: MidasUsageHubConnection,
        workspace: MidasUsageSyncWorkspace,
        state: MidasUsageHubSyncState,
        stateRoot: URL? = nil) async throws -> [MidasUsageHubPeerReceipt]
    {
        try connection.validate()
        try workspace.validate()
        if let expected = connection.workspaceID, expected != workspace.id {
            throw MidasUsageSyncError.wrongWorkspace
        }
        return try await MidasUsageHubTransportV2.acknowledge(
            connection: connection, workspace: workspace, state: state, stateRoot: stateRoot)
    }

    static func validatedExchange(
        _ data: Data,
        connection: MidasUsageHubConnection,
        workspace: MidasUsageSyncWorkspace,
        local: MidasUsageSyncPublication?,
        now: Date) throws -> MidasUsageHubExchange
    {
        guard data.count <= self.maximumExchangeBytes else { throw MidasUsageHubError.responseTooLarge }
        let result: MidasUsageHubExchange
        do {
            result = try autoreleasepool {
                let envelope = try MidasUsageSyncCodec.decodeEnvelope(data)
                let metadata = try JSONDecoder().decode(MidasUsageHubExchange.self, from: envelope.metadata)
                return MidasUsageHubExchange(
                    workspace: metadata.workspace,
                    publications: envelope.publications,
                    publicationSucceeded: metadata.publicationSucceeded,
                    unavailableFiles: metadata.unavailableFiles,
                    rejectedFiles: metadata.rejectedFiles)
            }
        } catch {
            throw MidasUsageHubError.invalidResponse
        }
        guard result.workspace == workspace else { throw MidasUsageSyncError.wrongWorkspace }
        guard result.publications.count <= self.maximumDevices,
              (0...self.maximumDevices).contains(result.unavailableFiles),
              (0...self.maximumDevices).contains(result.rejectedFiles)
        else { throw MidasUsageHubError.invalidResponse }
        var devices = Set<UUID>()
        var records = 0
        for publication in result.publications {
            try Task.checkCancellation()
            try publication.validate(workspaceID: workspace.id, now: now)
            guard devices.insert(publication.deviceID).inserted else { throw MidasUsageHubError.invalidResponse }
            if publication.deviceID == connection.deviceID, publication.deviceName != connection.deviceName {
                throw MidasUsageHubError.invalidResponse
            }
            let encodedBytes: Int
            do {
                encodedBytes = try MidasUsageSyncEncoding.encodedPublicationSize(publication)
            } catch MidasUsageSyncError.limitExceeded {
                // A valid wire representation can expand under canonical JSON escaping.
                // Preserve the received-publication size error used before bounded encoding.
                throw MidasUsageHubError.responseTooLarge
            }
            guard encodedBytes <= MidasUsageSyncPublication.maximumFileBytes else {
                throw MidasUsageHubError.responseTooLarge
            }
            records += publication.events.count + publication.accountDays.count
            guard records <= self.maximumExchangeRecords else { throw MidasUsageHubError.responseTooLarge }
        }
        // An acknowledgement is only credible when the exact submitted snapshot is returned for this device.
        if let local, result.publicationSucceeded {
            guard result.publications.first(where: { $0.deviceID == connection.deviceID }) == local else {
                throw MidasUsageHubError.invalidResponse
            }
        } else if local == nil, result.publicationSucceeded {
            throw MidasUsageHubError.invalidResponse
        }
        return result
    }

    static func request(
        connection: MidasUsageHubConnection,
        path: String,
        body: Data?,
        limit: Int,
        notFoundError: MidasUsageHubError = .invalidResponse) async throws -> Data
    {
        try connection.validate()
        try Task.checkCancellation()
        var request = URLRequest(url: connection.endpoint.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer " + connection.credential, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let transfer = BoundedTransfer(limit: limit, notFoundError: notFoundError)
        return try await withTaskCancellationHandler {
            try await transfer.run(request)
        } onCancel: {
            transfer.cancel()
        }
    }

    /// URLSession's data(for:) buffers before returning. This delegate applies the limit while bytes arrive.
    private final class BoundedTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private let notFoundError: MidasUsageHubError
        private var data = Data()
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var continuation: CheckedContinuation<Data, any Error>?
        private var failure: (any Error)?
        private var cancelled = false

        init(limit: Int, notFoundError: MidasUsageHubError) {
            self.limit = limit
            self.notFoundError = notFoundError
        }

        func run(_ request: URLRequest) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                self.lock.withLock {
                    if self.cancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.httpCookieStorage = nil
                    configuration.httpShouldSetCookies = false
                    configuration.urlCredentialStorage = nil
                    configuration.urlCache = nil
                    configuration.timeoutIntervalForRequest = 30
                    configuration.timeoutIntervalForResource = 45
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                    self.session = session
                    self.continuation = continuation
                    let task = session.dataTask(with: request)
                    self.task = task
                    task.resume()
                }
            }
        }

        private static func safeNetworkError(_ error: any Error) -> MidasUsageHubError {
            guard let error = error as? URLError else { return .unavailable }
            return switch error.code {
            case .timedOut: .timedOut
            case .cannotFindHost, .dnsLookupFailed: .nameResolutionFailed
            case .secureConnectionFailed, .serverCertificateHasBadDate,
                 .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .clientCertificateRejected,
                 .clientCertificateRequired: .secureConnectionFailed
            default: .unavailable
            }
        }

        func cancel() {
            self.lock.withLock {
                self.cancelled = true
                self.task?.cancel()
            }
        }

        func urlSession(
            _: URLSession,
            task _: URLSessionTask,
            willPerformHTTPRedirection _: HTTPURLResponse,
            newRequest _: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void)
        {
            // Never forward the credential, including to another Tailscale host.
            completionHandler(nil)
        }

        func urlSession(
            _: URLSession,
            dataTask _: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
        {
            let accepted = self.lock.withLock {
                guard let response = response as? HTTPURLResponse else {
                    self.failure = MidasUsageHubError.invalidResponse
                    return false
                }
                guard response.statusCode == 200 else {
                    self.failure = switch response.statusCode {
                    case 401, 403: MidasUsageHubError.unauthorized
                    case 410: MidasUsageHubError.revisionExpired
                    case 409: MidasUsageHubError.rejectedSnapshot
                    case 413: MidasUsageHubError.responseTooLarge
                    case 404: self.notFoundError
                    case 400: MidasUsageHubError.invalidResponse
                    case 426: MidasUsageHubError.incompatibleProtocol
                    default: MidasUsageHubError.unavailable
                    }
                    return false
                }
                guard response.expectedContentLength <= Int64(self.limit) else {
                    self.failure = MidasUsageHubError.responseTooLarge
                    return false
                }
                // Snapshot responses are large. Reserve a validated Content-Length once
                // instead of repeatedly growing and copying the accumulated byte buffer.
                if response.expectedContentLength > 0 {
                    self.data.reserveCapacity(Int(response.expectedContentLength))
                }
                return true
            }
            completionHandler(accepted ? .allow : .cancel)
        }

        func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let overflow = self.lock.withLock {
                guard data.count <= self.limit - self.data.count else {
                    self.failure = MidasUsageHubError.responseTooLarge
                    return true
                }
                self.data.append(data)
                return false
            }
            if overflow { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let outcome: (CheckedContinuation<Data, any Error>?, Result<Data, any Error>) = self.lock.withLock {
                let result: Result<Data, any Error> = switch (self.cancelled, self.failure, error) {
                case (true, _, _): .failure(CancellationError())
                case let (_, failure?, _): .failure(failure)
                case let (_, _, .some(error)):
                    .failure(Self.safeNetworkError(error))
                default: .success(self.data)
                }
                let continuation = self.continuation
                self.continuation = nil
                self.task = nil
                self.session = nil
                // The continuation now owns successful bytes. Drop our reference even
                // while URLSession is asynchronously releasing its delegate/session.
                self.data = Data()
                return (continuation, result)
            }
            session.finishTasksAndInvalidate()
            outcome.0?.resume(with: outcome.1)
        }
    }
}
