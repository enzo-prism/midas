import CodexBarCore
import Foundation
import Observation

/// Holds a newly signed-in session only until the user confirms the verified identity.
@MainActor
@Observable
final class ClaudeAccountSignInModel {
    typealias IdentityVerifier = @Sendable (String) async throws -> String?
    typealias AccountSaver = (_ label: String, _ token: String, _ email: String) throws -> Void

    var nickname = ""
    private(set) var verifiedEmail: String?
    private(set) var isVerifying = false
    private(set) var notice: String?
    @ObservationIgnored private var pendingToken: String?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private let verifyIdentity: IdentityVerifier

    init(verifyIdentity: @escaping IdentityVerifier = { header in
        try await ClaudeWebAPIFetcher.fetchUsage(cookieHeader: header).accountEmail
    }) {
        self.verifyIdentity = verifyIdentity
    }

    static func sessionHeader(from cookies: [HTTPCookie], now: Date = Date()) -> String? {
        let candidates = cookies.filter {
            $0.name == "sessionKey" && ["claude.ai", ".claude.ai"].contains($0.domain.lowercased()) &&
                $0.isSecure && ($0.expiresDate.map { $0 > now } ?? true) && !$0.value.isEmpty &&
                !$0.value.contains(where: { $0.isNewline || $0 == ";" })
        }
        // An ambiguous cookie jar must never silently pick a different signed-in identity.
        let values = Set(candidates.map(\.value))
        guard values.count == 1, let token = values.first else { return nil }
        return "sessionKey=\(token)"
    }

    func verify(cookieHeader: String?) async {
        guard !self.isVerifying, !Task.isCancelled else { return }
        self.clearVerification()
        guard let cookieHeader else {
            self.notice = "Finish signing in to Claude, then click Continue."
            return
        }
        self.isVerifying = true
        let attempt = self.revision
        defer {
            if self.revision == attempt { self.isVerifying = false }
        }
        do {
            let email = try await self.verifyIdentity(cookieHeader)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard self.revision == attempt, !Task.isCancelled else { return }
            guard let email, !email.isEmpty else {
                self.notice = "Claude did not confirm an account email. Try signing in again."
                return
            }
            self.verifiedEmail = email
            self.pendingToken = cookieHeader
        } catch {
            guard self.revision == attempt, !Task.isCancelled else { return }
            // Never display raw networking errors that might include credentials or redirect URLs.
            self.notice = "Could not verify this Claude account. Finish signing in and try again."
        }
    }

    @discardableResult
    func save(to settings: SettingsStore) -> Bool {
        self.save { label, token, email in
            let originalConfig = settings.config
            if let existing = settings.tokenAccounts(for: .claude).first(where: {
                $0.externalIdentifier?.caseInsensitiveCompare(email) == .orderedSame
            }) {
                settings.updateTokenAccount(
                    provider: .claude,
                    accountID: existing.id,
                    label: label.isEmpty ? existing.label : label,
                    token: token,
                    externalIdentifier: .some(email))
            } else {
                settings.addTokenAccount(
                    provider: .claude,
                    label: label.isEmpty ? email : label,
                    token: token,
                    externalIdentifier: email)
            }
            settings.updateProviderConfig(provider: .claude) { entry in
                entry.enabled = true
            }
            // The general settings API debounces writes. This confirmation must report a checked write.
            settings.configPersistTask?.cancel()
            do {
                try settings.configStore.save(settings.config)
            } catch {
                settings.applyExternalConfig(originalConfig, reason: "claude-sign-in-save-failed")
                throw error
            }
        }
    }

    @discardableResult
    func save(using saver: AccountSaver) -> Bool {
        guard let token = self.pendingToken, let email = self.verifiedEmail, !self.isVerifying else { return false }
        let label = self.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try saver(label, token, email)
            self.clearVerification()
            return true
        } catch {
            self.notice = "Could not save this account. Your verified sign-in is still available. Try Save again."
            return false
        }
    }

    func clearVerification() {
        self.revision += 1
        self.pendingToken = nil
        self.verifiedEmail = nil
        self.notice = nil
        self.isVerifying = false
    }
}
