import Foundation

public struct WidgetSnapshot: Codable, Sendable {
    public struct WidgetUsageRowSnapshot: Codable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let percentLeft: Double?

        public init(id: String, title: String, percentLeft: Double?) {
            self.id = id
            self.title = title
            self.percentLeft = percentLeft
        }
    }

    public struct ProviderEntry: Codable, Sendable {
        public let provider: UsageProvider
        public let updatedAt: Date
        public let primary: RateWindow?
        public let secondary: RateWindow?
        public let tertiary: RateWindow?
        public let usageRows: [WidgetUsageRowSnapshot]?
        public let creditsRemaining: Double?
        public let codeReviewRemainingPercent: Double?
        public let tokenUsage: TokenUsageSummary?
        public let dailyUsage: [DailyUsagePoint]

        /// Compares everything the widget renders except the `updatedAt` freshness stamp,
        /// which advances on every fetch even when the data itself is unchanged.
        /// Keep in sync when adding fields; a missed field only delays widget updates
        /// until the periodic re-persist interval in `UsageStore.persistWidgetSnapshot`.
        public func hasSameRenderedContent(as other: ProviderEntry) -> Bool {
            self.provider == other.provider &&
                self.primary == other.primary &&
                self.secondary == other.secondary &&
                self.tertiary == other.tertiary &&
                self.usageRows == other.usageRows &&
                self.creditsRemaining == other.creditsRemaining &&
                self.codeReviewRemainingPercent == other.codeReviewRemainingPercent &&
                self.tokenUsage == other.tokenUsage &&
                self.dailyUsage == other.dailyUsage
        }

        public init(
            provider: UsageProvider,
            updatedAt: Date,
            primary: RateWindow?,
            secondary: RateWindow?,
            tertiary: RateWindow?,
            usageRows: [WidgetUsageRowSnapshot]? = nil,
            creditsRemaining: Double?,
            codeReviewRemainingPercent: Double?,
            tokenUsage: TokenUsageSummary?,
            dailyUsage: [DailyUsagePoint])
        {
            self.provider = provider
            self.updatedAt = updatedAt
            self.primary = primary
            self.secondary = secondary
            self.tertiary = tertiary
            self.usageRows = usageRows
            self.creditsRemaining = creditsRemaining
            self.codeReviewRemainingPercent = codeReviewRemainingPercent
            self.tokenUsage = tokenUsage
            self.dailyUsage = dailyUsage
        }
    }

    public struct TokenUsageSummary: Codable, Equatable, Sendable {
        public let sessionCostUSD: Double?
        public let sessionTokens: Int?
        public let last30DaysCostUSD: Double?
        public let last30DaysTokens: Int?
        public let currencyCode: String
        public let sessionLabel: String
        public let last30DaysLabel: String

        public init(
            sessionCostUSD: Double?,
            sessionTokens: Int?,
            last30DaysCostUSD: Double?,
            last30DaysTokens: Int?,
            currencyCode: String = "USD",
            sessionLabel: String = "Today",
            last30DaysLabel: String = "30d")
        {
            self.sessionCostUSD = sessionCostUSD
            self.sessionTokens = sessionTokens
            self.last30DaysCostUSD = last30DaysCostUSD
            self.last30DaysTokens = last30DaysTokens
            self.currencyCode = currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "USD"
                : currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            self.sessionLabel = sessionLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Today"
                : sessionLabel
            self.last30DaysLabel = last30DaysLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "30d"
                : last30DaysLabel
        }

        private enum CodingKeys: String, CodingKey {
            case sessionCostUSD
            case sessionTokens
            case last30DaysCostUSD
            case last30DaysTokens
            case currencyCode
            case sessionLabel
            case last30DaysLabel
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                sessionCostUSD: container.decodeIfPresent(Double.self, forKey: .sessionCostUSD),
                sessionTokens: container.decodeIfPresent(Int.self, forKey: .sessionTokens),
                last30DaysCostUSD: container.decodeIfPresent(Double.self, forKey: .last30DaysCostUSD),
                last30DaysTokens: container.decodeIfPresent(Int.self, forKey: .last30DaysTokens),
                currencyCode: container.decodeIfPresent(String.self, forKey: .currencyCode) ?? "USD",
                sessionLabel: container.decodeIfPresent(String.self, forKey: .sessionLabel) ?? "Today",
                last30DaysLabel: container.decodeIfPresent(String.self, forKey: .last30DaysLabel) ?? "30d")
        }
    }

    public struct DailyUsagePoint: Codable, Equatable, Sendable {
        public let dayKey: String
        public let totalTokens: Int?
        public let costUSD: Double?

        public init(dayKey: String, totalTokens: Int?, costUSD: Double?) {
            self.dayKey = dayKey
            self.totalTokens = totalTokens
            self.costUSD = costUSD
        }
    }

    public let entries: [ProviderEntry]
    public let enabledProviders: [UsageProvider]
    public let generatedAt: Date

    public init(entries: [ProviderEntry], enabledProviders: [UsageProvider]? = nil, generatedAt: Date) {
        self.entries = entries
        self.enabledProviders = enabledProviders ?? entries.map(\.provider)
        self.generatedAt = generatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case entries
        case enabledProviders
        case generatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.entries = try container.decode([ProviderEntry].self, forKey: .entries)
        self.generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        self.enabledProviders = try container.decodeIfPresent([UsageProvider].self, forKey: .enabledProviders)
            ?? self.entries.map(\.provider)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.entries, forKey: .entries)
        try container.encode(self.enabledProviders, forKey: .enabledProviders)
        try container.encode(self.generatedAt, forKey: .generatedAt)
    }

    /// True when the widget would render identically from both snapshots.
    /// Ignores `generatedAt` and per-entry `updatedAt` so unchanged usage data
    /// doesn't force a widget timeline reload on every refresh cycle.
    public func hasSameRenderedContent(as other: WidgetSnapshot) -> Bool {
        guard self.enabledProviders == other.enabledProviders,
              self.entries.count == other.entries.count
        else { return false }
        return zip(self.entries, other.entries).allSatisfy { lhs, rhs in
            lhs.hasSameRenderedContent(as: rhs)
        }
    }
}

public enum WidgetSnapshotStore {
    public enum SaveResult: Equatable, Sendable {
        case saved(path: String)
        case failed(path: String, message: String)

        public var didSave: Bool {
            switch self {
            case .saved:
                true
            case .failed:
                false
            }
        }

        public var path: String {
            switch self {
            case let .saved(path),
                 let .failed(path, _):
                path
            }
        }

        public var message: String? {
            switch self {
            case .saved:
                nil
            case let .failed(_, message):
                message
            }
        }
    }

    private static let filename = AppGroupSupport.widgetSnapshotFilename

    public static func load(bundleID: String? = Bundle.main.bundleIdentifier) -> WidgetSnapshot? {
        let url = self.snapshotURL(bundleID: bundleID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? self.decoder.decode(WidgetSnapshot.self, from: data)
    }

    @discardableResult
    public static func save(
        _ snapshot: WidgetSnapshot,
        bundleID: String? = Bundle.main.bundleIdentifier) -> SaveResult
    {
        let url = self.snapshotURL(bundleID: bundleID)
        do {
            let data = try self.encoder.encode(snapshot)
            try data.write(to: url, options: [.atomic])
            return .saved(path: url.path)
        } catch {
            return .failed(path: url.path, message: error.localizedDescription)
        }
    }

    private static func snapshotURL(bundleID: String?) -> URL {
        AppGroupSupport.snapshotURL(bundleID: bundleID)
    }

    public static func appGroupID(for bundleID: String?) -> String? {
        AppGroupSupport.currentGroupID(for: bundleID)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum WidgetSelectionStore {
    private static let selectedProviderKey = "widgetSelectedProvider"

    public static func loadSelectedProvider(bundleID: String? = Bundle.main.bundleIdentifier) -> UsageProvider? {
        let defaults = self.sharedDefaults(bundleID: bundleID)
        guard let raw = defaults.string(forKey: self.selectedProviderKey) else { return nil }
        return UsageProvider(rawValue: raw)
    }

    public static func saveSelectedProvider(
        _ provider: UsageProvider,
        bundleID: String? = Bundle.main.bundleIdentifier)
    {
        let defaults = self.sharedDefaults(bundleID: bundleID)
        defaults.set(provider.rawValue, forKey: self.selectedProviderKey)
    }

    private static func sharedDefaults(bundleID: String?) -> UserDefaults {
        AppGroupSupport.sharedDefaults(bundleID: bundleID) ?? .standard
    }
}
