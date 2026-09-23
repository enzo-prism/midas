import CodexBarCore
import Foundation
import Security

/// Adopts Keychain items written under the inherited CodexBar service into Midas's own service.
///
/// Midas builds before 0.36.0 stored provider cookies and tokens under `com.steipete.CodexBar`.
/// When a store finds nothing under `MidasIdentity.keychainService`, it asks here once; a legacy
/// item is copied forward (never deleted, so an upstream CodexBar install keeps working) and the
/// copy is returned. Reads happen lazily per item so any macOS prompt appears only for providers
/// that are actually in use.
enum MidasLegacyKeychain {
    private static let log = CodexBarLog.logger(LogCategories.keychainMigration)

    static func adoptIfNeeded(
        service: String,
        account: String,
        promptKind: KeychainPromptContext.Kind) -> Data?
    {
        guard !KeychainAccessGate.isDisabled else { return nil }
        let legacyService = MidasIdentity.Upstream.keychainService
        guard service != legacyService else { return nil }

        switch KeychainAccessPreflight.checkGenericPassword(service: legacyService, account: account) {
        case .notFound:
            return nil
        case .interactionRequired:
            KeychainPromptHandler.handler?(KeychainPromptContext(
                kind: promptKind,
                service: legacyService,
                account: account))
        default:
            break
        }

        var result: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, !data.isEmpty else {
            if status != errSecItemNotFound {
                self.log.warning(
                    "Legacy keychain read failed",
                    metadata: ["account": account, "status": "\(status)"])
            }
            return nil
        }

        let target: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var addQuery = target
        for (key, value) in attributes {
            addQuery[key] = value
        }
        var writeStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if writeStatus == errSecDuplicateItem {
            writeStatus = SecItemUpdate(target as CFDictionary, attributes as CFDictionary)
        }
        if writeStatus == errSecSuccess {
            self.log.info("Adopted legacy keychain item into Midas service", metadata: ["account": account])
        } else {
            self.log.warning(
                "Could not copy legacy keychain item forward; using it for this read only",
                metadata: ["account": account, "status": "\(writeStatus)"])
        }
        return data
    }
}
