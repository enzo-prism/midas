import AppKit
import Foundation
import Observation

struct MidasSyncPendingPairing: Decodable, Identifiable, Sendable {
    let requestID: UUID
    let deviceName: String?
    var id: UUID {
        self.requestID
    }
}

struct MidasSyncManagementResult: Decodable, Sendable {
    let schemaVersion: Int
    let status: String
    let code: String?
    let hubVersion: String?
    let pendingRequests: [MidasSyncPendingPairing]?
}

/// Only the signed, bundled helper chooses service paths and runs fixed operations.
@MainActor @Observable
final class MidasSyncManagement {
    enum Action: String, Sendable {
        case check, doctor, restart, upgrade
        case pairingList = "pairing-list"
        case pairingApprove = "pairing-approve"
        case pairingDeny = "pairing-deny"
    }

    var isRunning = false
    var message: String?
    var requests: [MidasSyncPendingPairing] = []

    func run(_ action: Action, requestID: UUID? = nil, code: String? = nil) async {
        guard !self.isRunning else { return }
        if action == .pairingApprove {
            guard requestID != nil, let code, code.count == 6, code.allSatisfy(\.isNumber) else {
                self.message = "Enter the six digit code shown on the other Mac."
                return
            }
        }
        self.isRunning = true
        defer { self.isRunning = false }
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MidasSyncManage")
        var arguments = [action.rawValue]
        if let requestID { arguments += ["--request-id", requestID.uuidString] }
        if let code { arguments += ["--code", code] }
        do {
            let result = try await Self.execute(
                executable: executable,
                arguments: arguments,
                timeout: action == .upgrade ? 180 : 30)
            self.requests = result.pendingRequests ?? self.requests
            switch result.status {
            case "ok", "healthy", "success":
                self.message = action == .pairingApprove ? "Device approved. Finish connecting on that Mac."
                    : "Hub check completed" + (result.hubVersion.map { " · version \($0)" } ?? "") + "."
            default:
                self.message = "The hub needs attention (\(result.code ?? "check-failed")). Run Check hub for details."
            }
        } catch {
            self.message = "Hub management is unavailable on this Mac. Open these controls on the Mac running your hub."
        }
    }

    private nonisolated static func execute(executable: URL, arguments: [String], timeout: TimeInterval) async throws
        -> MidasSyncManagementResult
    {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let termination = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: termination)
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            termination.cancel()
            guard bytes.count <= 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            let result = try JSONDecoder().decode(MidasSyncManagementResult.self, from: bytes)
            guard result.schemaVersion == 1 else { throw CocoaError(.coderReadCorrupt) }
            return result
        }.value
    }
}

extension MidasUsageSyncCoordinator {
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Connect Midas usage"
        panel.message = "Choose the same private folder on both Macs to share usage counts, costs, and device names."
        panel.prompt = "Connect"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            Task { @MainActor [weak self] in
                do { try await self?.connect(folder: folder) } catch is CancellationError {
                    return
                } catch { self?.issue = self?.message(error) }
            }
        }
    }

    func chooseHubConnection() {
        let panel = NSOpenPanel()
        panel.title = "Connect to your Tailscale hub"
        panel.message = "Choose the private Midas connection file created for this Mac."
        panel.prompt = "Connect"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let file = panel.url else { return }
            Task { @MainActor [weak self] in
                do { try await self?.connect(hubConnectionFile: file) } catch is CancellationError {
                    return
                } catch { self?.issue = self?.message(error) }
            }
        }
    }
}
