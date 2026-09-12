import CodexBarCore
import CryptoKit
import Foundation

extension UsageStore {
    /// Stable across independent logins and installations; no email or account ID is written to the shared file.
    nonisolated static func calibrationPortableScope(accounts: [CodexVisibleAccount]) -> String? {
        guard !accounts.isEmpty else { return nil }
        var identities: [String] = []
        for account in accounts {
            let email = account.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard email.contains("@") else { return nil }
            let identity = [email, account.workspaceAccountID ?? "personal"]
            guard let data = try? JSONEncoder().encode(identity), let value = String(data: data, encoding: .utf8)
            else { return nil }
            identities.append(value)
        }
        guard let data = try? JSONEncoder().encode(Array(Set(identities)).sorted()) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var midasCalibrationPortableScope: String? {
        Self.calibrationPortableScope(accounts: self.settings.codexVisibleAccountProjection.visibleAccounts)
    }

    func scheduleMidasCalibrationSharing(now: Date = Date(), force: Bool = false) {
        guard !SettingsStore.isRunningTests else { return }
        guard self.settings.midasCalibrationSharingEnabled, self.settings.costUsageEnabled,
              self.settings.midasCloudUsageEnabled, self.isEnabled(.codex),
              let scope = self.midasCalibrationPortableScope
        else {
            self.midasCalibrationSharingTask?.cancel()
            self.midasCalibrationSharingTask = nil
            self.midasCalibrationSharingGeneration = UUID()
            self.midasCalibrationSharingAttempt = nil
            self.midasSharedCalibration = nil
            self.midasCalibrationSharingStatus = ""
            self.repriceMidasCloudUsage()
            return
        }
        if self.midasCalibrationSharingScope != scope {
            self.midasCalibrationSharingTask?.cancel()
            self.midasCalibrationSharingTask = nil
            self.midasCalibrationSharingAttempt = nil
            self.midasSharedCalibration = nil
            self.midasCalibrationSharingScope = scope
        }
        guard self.midasCalibrationSharingTask == nil else { return }
        if !force, let last = self.midasCalibrationSharingAttempt, now.timeIntervalSince(last) < 60 { return }
        self.midasCalibrationSharingAttempt = now
        let generation = UUID()
        self.midasCalibrationSharingGeneration = generation
        let local = self.midasCodexCalibrationScope == self.tokenCostScope(for: .codex).signature
            ? self.midasCodexCalibration : nil
        let record = local.flatMap { calibration in
            calibration.estimate(now: now).map { _ in
                MidasCalibrationExchange.Record(
                    deviceID: self.settings.midasCalibrationDeviceID,
                    scope: scope,
                    calibration: calibration)
            }
        }
        self.midasCalibrationSharingStatus = "Checking iCloud Drive…"
        self.midasCalibrationSharingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.midasCalibrationSharingGeneration == generation { self.midasCalibrationSharingTask = nil }
            }
            do {
                let folder = try await Task.detached(priority: .utility) {
                    let root = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
                    var directory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory),
                          directory.boolValue else { throw CocoaError(.fileNoSuchFile) }
                    return root.appendingPathComponent("Midas Estimates", isDirectory: true)
                }.value
                guard !Task.isCancelled else { return }
                let result = try await MidasCalibrationExchange.exchange(folder: folder, local: record, now: now)
                let records = result.records
                guard !Task.isCancelled, self.midasCalibrationSharingGeneration == generation,
                      self.settings.midasCalibrationSharingEnabled, self.midasCalibrationPortableScope == scope
                else { return }
                self.midasSharedCalibration = MidasCalibrationExchange.winner(records: records, scope: scope, now: now)
                let devices = Set(records.filter {
                    $0.scope == scope && $0.schemaVersion == 1 && $0.methodVersion == 1
                        && $0.calibration.estimate(now: now) != nil
                }.map(\.deviceID)).count
                if result.publicationFailed {
                    self.midasCalibrationSharingStatus = "Reading shared samples; this Mac could not publish."
                } else {
                    self.midasCalibrationSharingStatus = devices == 0
                        ? "Waiting for a priced sample from another Mac."
                        : "Shared folder: \(devices) Mac\(devices == 1 ? "" : "s") with a recent sample."
                }
            } catch {
                guard !Task.isCancelled, self.midasCalibrationSharingGeneration == generation else { return }
                self.midasCalibrationSharingStatus = "Sharing unavailable. Check iCloud Drive."
            }
            self.repriceMidasCloudUsage()
            self.persistWidgetSnapshot(reason: "shared-codex-estimate")
        }
    }
}
