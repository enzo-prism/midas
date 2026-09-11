import Foundation

/// Private ChatGPT analytics endpoints: values retain their reported units.
public struct CodexCloudAccountUsage: Codable, Sendable, Equatable {
    public struct Day: Codable, Sendable, Equatable {
        public let date: String
        public let tokens: Int
    }

    public struct ModelUsage: Codable, Sendable, Equatable {
        public let model: String
        public let value: Double
    }

    public let days: [Day]
    public let models: [ModelUsage]
    public let modelUnits: String
    public let statsAsOf: String
    public let fetchedAt: Date

    public var totalTokens: Int? {
        guard !self.days.isEmpty else { return nil }
        return self.days.reduce(0) { $0 + $1.tokens }
    }

    public static func parse(profile: Data, breakdown: Data, now: Date = Date()) throws -> Self {
        struct Profile: Decodable {
            struct Stats: Decodable {
                struct Bucket: Decodable { let start_date: String; let tokens: Int }
                let daily_usage_buckets: [Bucket]
            }

            struct Metadata: Decodable { let stats_as_of: String; let stats_error: String? }
            let stats: Stats
            let metadata: Metadata
        }
        struct Breakdown: Decodable {
            struct Row: Decodable {
                struct Model: Decodable { let model: String; let credits: Double }
                let date: String
                let models: [Model]
            }

            let data: [Row]
            let units: String
        }
        let profile = try JSONDecoder().decode(Profile.self, from: profile)
        let breakdown = try JSONDecoder().decode(Breakdown.self, from: breakdown)
        guard profile.metadata.stats_error == nil, ["percent", "credits"].contains(breakdown.units) else {
            throw CodexCloudUsageError.invalidData
        }
        let window = Self.window(now: now)
        var dates = Set<String>()
        var total = 0
        let days = try profile.stats.daily_usage_buckets.compactMap { bucket -> Day? in
            guard Self.validDate(bucket.start_date), bucket.tokens >= 0,
                  dates.insert(bucket.start_date).inserted else { throw CodexCloudUsageError.invalidData }
            guard bucket.start_date >= window.start, bucket.start_date <= window.end else { return nil }
            let added = total.addingReportingOverflow(bucket.tokens)
            guard !added.overflow else { throw CodexCloudUsageError.invalidData }
            total = added.partialValue
            return Day(date: bucket.start_date, tokens: bucket.tokens)
        }.sorted { $0.date < $1.date }
        var models: [String: Double] = [:]
        for row in breakdown.data {
            guard Self.validDate(row.date) else { throw CodexCloudUsageError.invalidData }
            guard row.date >= window.start, row.date <= window.end else { continue }
            for model in row.models {
                guard model.credits.isFinite, model.credits >= 0 else { throw CodexCloudUsageError.invalidData }
                let sum = (models[model.model] ?? 0) + model.credits
                guard sum.isFinite else { throw CodexCloudUsageError.invalidData }
                models[model.model] = sum
            }
        }
        return Self(
            days: days,
            models: models.filter { $0.value > 0 }.map { ModelUsage(model: $0.key, value: $0.value) }
                .sorted { $0.value > $1.value },
            modelUnits: breakdown.units,
            statsAsOf: profile.metadata.stats_as_of,
            fetchedAt: now)
    }

    public static func window(now: Date) -> (start: String, end: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(byAdding: .day, value: -29, to: now)!
        let formatter = Self.dayFormatter()
        return (formatter.string(from: start), formatter.string(from: now))
    }

    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    private static func validDate(_ value: String) -> Bool {
        let formatter = Self.dayFormatter()
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
}

public enum CodexCloudUsageError: LocalizedError {
    case invalidData
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidData: "OpenAI returned unavailable or unsupported cloud usage data."
        case let .http(status): "OpenAI cloud history request failed (HTTP \(status))."
        }
    }
}

public enum CodexCloudUsageFetcher {
    public static func fetch(env: [String: String], now: Date = Date()) async throws -> CodexCloudAccountUsage {
        // Quota refresh owns token rotation. This reader never races another refresh by rotating credentials.
        let credentials = try CodexOAuthCredentialsStore.load(env: env)
        let window = CodexCloudAccountUsage.window(now: now)
        let profile = try await self.get(path: "/wham/profiles/me", credentials: credentials)
        let breakdown = try await self.get(
            path: "/wham/usage/daily-token-usage-breakdown",
            query: [
                URLQueryItem(name: "start_date", value: window.start),
                URLQueryItem(name: "end_date", value: window.end),
                URLQueryItem(name: "group_by", value: "day"),
            ],
            credentials: credentials)
        return try CodexCloudAccountUsage.parse(profile: profile, breakdown: breakdown, now: now)
    }

    private static func get(
        path: String, query: [URLQueryItem] = [], credentials: CodexOAuthCredentials) async throws -> Data
    {
        var url = URLComponents(string: "https://chatgpt.com/backend-api" + path)!
        if !query.isEmpty { url.queryItems = query }
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 30
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        let response = try await ProviderHTTPClient.shared.response(for: request, retryPolicy: .transientIdempotent)
        guard (200...299).contains(response.statusCode) else { throw CodexCloudUsageError.http(response.statusCode) }
        return response.data
    }
}
