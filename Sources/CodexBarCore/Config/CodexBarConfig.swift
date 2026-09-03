import Foundation

public struct CodexBarConfig: Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var providers: [ProviderConfig]

    /// Provider entries whose `id` is unknown to this build (written by a newer release).
    /// Carried opaquely through load/normalize/save so older builds never delete settings
    /// (including secrets) they don't understand. Unknown entries are appended after known
    /// providers when saving.
    public var unknownProviders: [UnknownProviderEntry] = []

    public init(
        version: Int = Self.currentVersion,
        providers: [ProviderConfig],
        unknownProviders: [UnknownProviderEntry] = [])
    {
        self.version = version
        self.providers = providers
        self.unknownProviders = unknownProviders
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case providers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        // Decode providers lossily: entries for providers this build doesn't know are
        // preserved as unknown entries instead of failing the whole config.
        let rawProviders = try container.decodeIfPresent([UnknownProviderEntry.Value].self, forKey: .providers)
            ?? []
        let encoder = JSONEncoder()
        let valueDecoder = JSONDecoder()
        var providers: [ProviderConfig] = []
        var unknownProviders: [UnknownProviderEntry] = []
        for raw in rawProviders {
            guard case let .object(fields) = raw,
                  fields["id"] != nil,
                  let data = try? encoder.encode(raw),
                  let entry = try? valueDecoder.decode(ProviderConfig.self, from: data)
            else {
                if let data = try? encoder.encode(raw),
                   let entry = try? valueDecoder.decode(UnknownProviderEntry.self, from: data)
                {
                    unknownProviders.append(entry)
                }
                continue
            }
            providers.append(entry)
        }
        self.providers = providers
        self.unknownProviders = unknownProviders
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.version, forKey: .version)
        var nested = container.nestedUnkeyedContainer(forKey: .providers)
        for provider in self.providers {
            try nested.encode(provider)
        }
        for entry in self.unknownProviders {
            try nested.encode(entry)
        }
    }

    public static func makeDefault(
        metadata: [UsageProvider: ProviderMetadata] = ProviderDescriptorRegistry.metadata) -> CodexBarConfig
    {
        let providers = UsageProvider.allCases.map { provider in
            ProviderConfig(
                id: provider,
                enabled: metadata[provider]?.defaultEnabled)
        }
        return CodexBarConfig(version: Self.currentVersion, providers: providers)
    }

    public func normalized(
        metadata: [UsageProvider: ProviderMetadata] = ProviderDescriptorRegistry.metadata) -> CodexBarConfig
    {
        var seen: Set<UsageProvider> = []
        var normalized: [ProviderConfig] = []
        normalized.reserveCapacity(max(self.providers.count, UsageProvider.allCases.count))

        for provider in self.providers {
            guard !seen.contains(provider.id) else { continue }
            seen.insert(provider.id)
            normalized.append(provider)
        }

        for provider in UsageProvider.allCases where !seen.contains(provider) {
            normalized.append(ProviderConfig(
                id: provider,
                enabled: metadata[provider]?.defaultEnabled))
        }

        return CodexBarConfig(
            version: Self.currentVersion,
            providers: normalized,
            unknownProviders: self.unknownProviders)
    }

    public func orderedProviders() -> [UsageProvider] {
        self.providers.map(\.id)
    }

    public func enabledProviders(
        metadata: [UsageProvider: ProviderMetadata] = ProviderDescriptorRegistry.metadata) -> [UsageProvider]
    {
        self.providers.compactMap { config in
            let enabled = config.enabled ?? metadata[config.id]?.defaultEnabled ?? false
            return enabled ? config.id : nil
        }
    }

    public func providerConfig(for id: UsageProvider) -> ProviderConfig? {
        self.providers.first(where: { $0.id == id })
    }

    public mutating func setProviderConfig(_ config: ProviderConfig) {
        if let index = self.providers.firstIndex(where: { $0.id == config.id }) {
            self.providers[index] = config
        } else {
            self.providers.append(config)
        }
    }
}

public struct ProviderConfig: Codable, Sendable, Identifiable {
    public let id: UsageProvider
    public var enabled: Bool?
    public var source: ProviderSourceMode?
    public var extrasEnabled: Bool?
    public var apiKey: String?
    public var secretKey: String?
    public var cookieHeader: String?
    public var cookieSource: ProviderCookieSource?
    public var region: String?
    public var workspaceID: String?
    public var enterpriseHost: String?
    public var tokenAccounts: ProviderTokenAccountData?
    public var codexActiveSource: CodexActiveSource?
    public var quotaWarnings: QuotaWarningConfig?
    public var kiloKnownOrganizations: [KiloOrganization]?
    public var kiloEnabledOrganizationIDs: [String]?
    public var awsProfile: String?
    public var awsAuthMode: String?

    public init(
        id: UsageProvider,
        enabled: Bool? = nil,
        source: ProviderSourceMode? = nil,
        extrasEnabled: Bool? = nil,
        apiKey: String? = nil,
        secretKey: String? = nil,
        cookieHeader: String? = nil,
        cookieSource: ProviderCookieSource? = nil,
        region: String? = nil,
        workspaceID: String? = nil,
        enterpriseHost: String? = nil,
        tokenAccounts: ProviderTokenAccountData? = nil,
        codexActiveSource: CodexActiveSource? = nil,
        quotaWarnings: QuotaWarningConfig? = nil,
        kiloKnownOrganizations: [KiloOrganization]? = nil,
        kiloEnabledOrganizationIDs: [String]? = nil,
        awsProfile: String? = nil,
        awsAuthMode: String? = nil)
    {
        self.id = id
        self.enabled = enabled
        self.source = source
        self.extrasEnabled = extrasEnabled
        self.apiKey = apiKey
        self.secretKey = secretKey
        self.cookieHeader = cookieHeader
        self.cookieSource = cookieSource
        self.region = region
        self.workspaceID = workspaceID
        self.enterpriseHost = enterpriseHost
        self.tokenAccounts = tokenAccounts
        self.codexActiveSource = codexActiveSource
        self.quotaWarnings = quotaWarnings
        self.kiloKnownOrganizations = kiloKnownOrganizations
        self.kiloEnabledOrganizationIDs = kiloEnabledOrganizationIDs
        self.awsProfile = awsProfile
        self.awsAuthMode = awsAuthMode
    }

    public var sanitizedAPIKey: String? {
        Self.clean(self.apiKey)
    }

    public var sanitizedSecretKey: String? {
        Self.clean(self.secretKey)
    }

    public var sanitizedCookieHeader: String? {
        Self.clean(self.cookieHeader)
    }

    public var sanitizedRegion: String? {
        Self.clean(self.region)
    }

    public var sanitizedWorkspaceID: String? {
        Self.clean(self.workspaceID)
    }

    public var sanitizedEnterpriseHost: String? {
        Self.clean(self.enterpriseHost)
    }

    public var sanitizedAWSProfile: String? {
        Self.clean(self.awsProfile)
    }

    public var sanitizedAWSAuthMode: String? {
        Self.clean(self.awsAuthMode)
    }

    private static func clean(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// A provider entry whose `id` is unknown to this build (written by a newer release).
/// All other fields are carried opaquely so they round-trip byte-for-byte semantically.
public struct UnknownProviderEntry: Codable, Sendable, Equatable {
    public var id: String
    public var fields: [String: Value]

    public init(id: String, fields: [String: Value] = [:]) {
        self.id = id
        self.fields = fields
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = "\(intValue)"
            self.intValue = intValue
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        guard let idKey = AnyKey(stringValue: "id") else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing provider id."))
        }
        self.id = try container.decode(String.self, forKey: idKey)
        var fields: [String: Value] = [:]
        for key in container.allKeys where key.stringValue != "id" {
            fields[key.stringValue] = try container.decode(Value.self, forKey: key)
        }
        self.fields = fields
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        guard let idKey = AnyKey(stringValue: "id") else { return }
        try container.encode(self.id, forKey: idKey)
        for (key, value) in self.fields {
            guard let codingKey = AnyKey(stringValue: key) else { continue }
            try container.encode(value, forKey: codingKey)
        }
    }

    /// Any JSON value, for losslessly carrying unknown provider fields.
    public enum Value: Codable, Sendable, Equatable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([Value])
        case object([String: Value])

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
                return
            }
            if let value = try? container.decode(Bool.self) {
                self = .bool(value)
                return
            }
            if let value = try? container.decode(Int.self) {
                self = .int(value)
                return
            }
            if let value = try? container.decode(Double.self) {
                self = .double(value)
                return
            }
            if let value = try? container.decode(String.self) {
                self = .string(value)
                return
            }
            if let value = try? container.decode([Value].self) {
                self = .array(value)
                return
            }
            if let value = try? container.decode([String: Value].self) {
                self = .object(value)
                return
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value.")
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null:
                try container.encodeNil()
            case let .bool(value):
                try container.encode(value)
            case let .int(value):
                try container.encode(value)
            case let .double(value):
                try container.encode(value)
            case let .string(value):
                try container.encode(value)
            case let .array(value):
                try container.encode(value)
            case let .object(value):
                try container.encode(value)
            }
        }
    }
}

public enum QuotaWarningWindow: String, Codable, Sendable, CaseIterable {
    case session
    case weekly

    public var displayName: String {
        switch self {
        case .session:
            "session"
        case .weekly:
            "weekly"
        }
    }
}

public struct QuotaWarningWindowConfig: Codable, Sendable, Equatable {
    public var thresholds: [Int]?
    public var enabled: Bool?

    public init(thresholds: [Int]? = nil, enabled: Bool? = nil) {
        self.thresholds = thresholds.map(QuotaWarningThresholds.sanitized)
        self.enabled = enabled
    }

    public var hasOverride: Bool {
        self.thresholds != nil || self.enabled != nil
    }

    public func isEnabled(global: Bool) -> Bool {
        self.enabled ?? (self.thresholds != nil ? true : global)
    }
}

public struct QuotaWarningConfig: Codable, Sendable, Equatable {
    public var session: QuotaWarningWindowConfig?
    public var weekly: QuotaWarningWindowConfig?

    public init(
        session: QuotaWarningWindowConfig? = nil,
        weekly: QuotaWarningWindowConfig? = nil)
    {
        self.session = session
        self.weekly = weekly
    }

    public func thresholds(for window: QuotaWarningWindow, global: [Int]) -> [Int] {
        switch window {
        case .session:
            QuotaWarningThresholds.sanitized(self.session?.thresholds ?? global)
        case .weekly:
            QuotaWarningThresholds.sanitized(self.weekly?.thresholds ?? global)
        }
    }

    public func isEnabled(for window: QuotaWarningWindow, global: Bool) -> Bool {
        switch window {
        case .session:
            self.session?.isEnabled(global: global) ?? global
        case .weekly:
            self.weekly?.isEnabled(global: global) ?? global
        }
    }

    public func hasOverride(for window: QuotaWarningWindow) -> Bool {
        switch window {
        case .session:
            self.session?.hasOverride ?? false
        case .weekly:
            self.weekly?.hasOverride ?? false
        }
    }

    public var isEmpty: Bool {
        self.session?.hasOverride != true && self.weekly?.hasOverride != true
    }
}

public enum QuotaWarningThresholds {
    public static let defaults = [50, 20]
    public static let allowedRange = 0...99

    public static func sanitized(_ raw: [Int]) -> [Int] {
        guard !raw.isEmpty else { return self.defaults }

        let unique = Set(raw.map(self.clamped))
        let sorted = unique.sorted(by: >)
        return sorted.isEmpty ? self.defaults : sorted
    }

    public static func active(_ raw: [Int]) -> [Int] {
        self.sanitized(raw).filter { $0 > 0 }
    }

    public static func resolved(upper: Int?, lower: Int?) -> [Int] {
        guard upper != nil || lower != nil else { return self.defaults }

        let resolvedUpper = self.clamped(upper ?? self.defaults[0])
        let lowerDefault = resolvedUpper < self.defaults[1] ? 0 : self.defaults[1]
        let resolvedLower = self.clamped(lower ?? lowerDefault)
        return self.sanitized([resolvedUpper, resolvedLower])
    }

    public static func clamped(_ value: Int) -> Int {
        min(max(value, self.allowedRange.lowerBound), self.allowedRange.upperBound)
    }
}
