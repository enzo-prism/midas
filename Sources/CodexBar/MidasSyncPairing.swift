import CodexBarCore
import Foundation
import Observation

/// A short-lived pairing secret exists only in memory until the hub grants this Mac its own credential.
@MainActor @Observable
final class MidasSyncPairing {
    var endpoint = ""
    var code: String?
    var message: String?
    var isWaiting = false
    @ObservationIgnored private var operation: Task<Void, Never>?

    func cancel() {
        self.operation?.cancel()
        self.operation = nil
        self.isWaiting = false
        self.code = nil
    }

    func begin(coordinator: MidasUsageSyncCoordinator) {
        guard !self.isWaiting else { return }
        guard let endpoint = URL(string: self.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            self.message = "Enter your hub’s private https:// name ending in .ts.net."
            return
        }
        let requestID = UUID()
        let secret = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
        let deviceName = coordinator.deviceName
        do {
            try MidasUsageHubConnection(
                endpoint: endpoint,
                deviceID: requestID,
                deviceName: deviceName,
                credential: secret).validate()
        } catch {
            self.message = "Use your private Tailscale HTTPS hub address."
            return
        }
        self.isWaiting = true
        self.message = nil
        self.operation = Task { [weak self, weak coordinator] in
            guard let self, let coordinator else { return }
            defer { self.isWaiting = false }
            do {
                let initial = try await Self.request(endpoint: endpoint, path: "v2/pairing/request", payload: [
                    "deviceName": deviceName, "requestID": requestID.uuidString,
                    "requestSecret": secret, "endpoint": endpoint.absoluteString,
                ])
                guard let code = initial.code, code.count == 6, code.allSatisfy(\.isNumber) else {
                    throw MidasUsageHubError.invalidResponse
                }
                self.code = code
                self.message = "On the hub Mac, open Midas → Sync → Review device requests and approve this code."
                for _ in 0..<150 {
                    try await Task.sleep(for: .seconds(2))
                    let status = try await Self.request(endpoint: endpoint, path: "v2/pairing/status", payload: [
                        "requestID": requestID.uuidString, "requestSecret": secret,
                    ])
                    switch status.status {
                    case "approved":
                        guard let connection = status.connection, connection.endpoint == endpoint else {
                            throw MidasUsageHubError.invalidResponse
                        }
                        try connection.validate()
                        try Task.checkCancellation()
                        try await coordinator.connect(hub: connection)
                        self.code = nil
                        self.message = "This Mac is connected to your private hub."
                        return
                    case "denied", "expired":
                        self.code = nil
                        self.message = "This request expired or was declined. Start again when both Macs are ready."
                        return
                    case "pending": break
                    default: throw MidasUsageHubError.invalidResponse
                    }
                }
                self.code = nil
                self.message = "The request expired. Start again when both Macs are ready."
            } catch is CancellationError {
                self.code = nil
            } catch {
                self.code = nil
                self.message = "Could not finish pairing. Check Tailscale and update the hub, then try again."
            }
        }
    }

    private struct Response: Decodable {
        let status: String
        let code: String?
        let connection: MidasUsageHubConnection?
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void)
        {
            completionHandler(nil)
        }
    }

    private static func request(endpoint: URL, path: String, payload: [String: String]) async throws -> Response {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw MidasUsageHubError.invalidResponse
        }
        var data = Data()
        for try await byte in stream {
            guard data.count < 16384 else { throw MidasUsageHubError.responseTooLarge }
            data.append(byte)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
