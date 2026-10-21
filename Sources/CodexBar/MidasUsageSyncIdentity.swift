import CryptoKit
import Foundation
import IOKit

/// These opaque values stay in local preferences/cache. They never enter a shared publication.
struct MidasUsageSyncEnvironmentIdentity: Sendable, Equatable {
    var deviceBinding: String?
    var cloudAccountFingerprint: String

    init(
        deviceBinding: String? = nil,
        cloudAccountFingerprint: String = "no-icloud-account")
    {
        self.deviceBinding = deviceBinding
        self.cloudAccountFingerprint = cloudAccountFingerprint
    }

    static func live() -> Self {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        var binding: String?
        if service != 0 {
            defer { IOObjectRelease(service) }
            if let identifier = IORegistryEntryCreateCFProperty(
                service,
                "IOPlatformUUID" as CFString,
                kCFAllocatorDefault,
                0)?.takeRetainedValue() as? String
            {
                binding = self.fingerprint(Data(("Midas local device v1:" + identifier).utf8))
            }
        }
        guard let token = FileManager.default.ubiquityIdentityToken else {
            return Self(
                deviceBinding: binding,
                cloudAccountFingerprint: "identity-unavailable")
        }
        return Self(
            deviceBinding: binding,
            cloudAccountFingerprint: self.cloudAccountFingerprint(
                token: token,
                defaults: .standard))
    }

    /// Apple defines account-token identity with isEqual, not the bytes of its archive.
    /// Keep a local stable label so caches do not depend on serialization order.
    static func cloudAccountFingerprint(
        token: (any NSCoding & NSObjectProtocol)?,
        defaults: UserDefaults) -> String
    {
        guard let token else { return "identity-unavailable" }
        if let data = defaults.data(forKey: "midasUsageSyncIdentityToken"),
           let decoder = try? NSKeyedUnarchiver(forReadingFrom: data)
        {
            decoder.requiresSecureCoding = false
            decoder.decodingFailurePolicy = .setErrorAndReturn
            let previous = decoder.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
            decoder.finishDecoding()
            if let previous, token.isEqual(previous),
               let fingerprint = defaults.string(forKey: "midasUsageSyncIdentityFingerprint")
            {
                return fingerprint
            }
        }
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: false)
        else {
            return "identity-unavailable"
        }
        let fingerprint = "icloud-account-v2:" + UUID().uuidString
        defaults.set(
            data,
            forKey: "midasUsageSyncIdentityToken")
        defaults.set(
            fingerprint,
            forKey: "midasUsageSyncIdentityFingerprint")
        return fingerprint
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
