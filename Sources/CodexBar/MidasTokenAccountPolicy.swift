import CodexBarCore
import Foundation

/// A saved reading can only follow the credential and organization that produced it.
enum MidasTokenAccountPolicy {
    static func entryBelongs(to account: ProviderTokenAccount, entry: TokenAccountUsageSnapshot) -> Bool {
        self.sameConnection(account, entry.account)
    }

    static func sameConnection(_ account: ProviderTokenAccount, _ other: ProviderTokenAccount) -> Bool {
        account.id == other.id && account.token == other.token
            && account.sanitizedOrganizationID == other.sanitizedOrganizationID
            && account.externalIdentifier == other.externalIdentifier
    }

    static func identityMatches(_ snapshot: UsageSnapshot, account: ProviderTokenAccount) -> Bool {
        let expected = [account.externalIdentifier, account.label]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .first { $0.contains("@") }
        guard let expected,
              let actual = snapshot.accountEmail(for: .claude)?
                  .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !actual.isEmpty
        else { return true }
        return expected == actual
    }

    static let identityMismatch = "This Claude connection belongs to a different account. Reconnect it in Settings."
}
