import CodexBarCore
import Foundation

enum MidasCodexEstimateMode: String, CaseIterable, Identifiable {
    case automatic
    case custom
    case tokensOnly

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .custom: "Custom rate"
        case .tokensOnly: "Tokens only"
        }
    }

    static func load(from defaults: UserDefaults) -> Self {
        if let raw = defaults.string(forKey: "midasCodexEstimateMode"), let mode = Self(rawValue: raw) { return mode }
        // Preserve an existing explicit rate or tokens-only choice during upgrades.
        guard defaults.object(forKey: "midasCloudUSDPerMillionTokens") != nil else { return .automatic }
        return defaults.double(forKey: "midasCloudUSDPerMillionTokens") > 0 ? .custom : .tokensOnly
    }
}

struct MidasCodexEstimate {
    let rate: Double
    let detail: String
}

/// A pricing sample, never additional usage to add to the cloud total.
struct MidasCodexCalibration: Codable, Equatable {
    let rate: Double
    let pricedTokens: Double
    let observedTokens: Double
    let sampledAt: Date
    let lastUsageDay: String

    static func make(
        snapshot: CostUsageTokenSnapshot,
        now: Date) -> Self?
    {
        guard snapshot.currencyCode == "USD", snapshot.costProvenance == .listPriceEstimate,
              snapshot.updatedAt <= now.addingTimeInterval(300),
              now.timeIntervalSince(snapshot.updatedAt) <= 86400 else { return nil }
        let window = CodexCloudAccountUsage.window(now: now)
        var tokens = 0.0
        var observed = 0.0
        var dollars = 0.0
        var lastDay = ""
        for day in snapshot.daily where day.date >= window.start && day.date <= window.end {
            guard let total = day.totalTokens, total >= 0 else { return nil }
            observed += Double(total)
            var dayPriced = 0.0
            for model in day.modelBreakdowns ?? [] {
                guard let count = model.totalTokens, count > 0,
                      let cost = model.costUSD, cost.isFinite, cost >= 0 else { continue }
                dayPriced += Double(count)
                dollars += cost
                lastDay = max(lastDay, day.date)
            }
            guard dayPriced <= Double(total) else { return nil }
            tokens += dayPriced
        }
        // Avoid calibrating from a tiny or predominantly unpriced sample.
        guard tokens >= 10000, observed > 0, tokens / observed >= 0.8,
              dollars.isFinite, dollars > 0 else { return nil }
        let rate = dollars / tokens * 1_000_000
        guard rate.isFinite, rate > 0 else { return nil }
        return Self(
            rate: rate,
            pricedTokens: tokens,
            observedTokens: observed,
            sampledAt: snapshot.updatedAt,
            lastUsageDay: lastDay)
    }

    func estimate(now: Date) -> MidasCodexEstimate? {
        guard self.rate.isFinite, self.rate > 0,
              self.pricedTokens >= 10000, self.observedTokens >= self.pricedTokens,
              self.pricedTokens / self.observedTokens >= 0.8,
              self.sampledAt <= now.addingTimeInterval(300),
              now.timeIntervalSince(self.sampledAt) <= 86400,
              self.lastUsageDay >= CodexCloudAccountUsage.window(now: now).start,
              self.lastUsageDay <= CodexCloudAccountUsage.window(now: now).end else { return nil }
        let formattedRate = self.rate.formatted(.number.precision(.fractionLength(2...4)))
        let coverage = (self.pricedTokens / self.observedTokens).formatted(.percent.precision(.fractionLength(0)))
        return MidasCodexEstimate(
            rate: self.rate,
            detail:
            "Cloud tokens × $\(formattedRate)/M, estimated from this Mac’s recent priced usage mix "
                + "(\(coverage) of observed tokens priced). Assumes a similar model and cache mix across accounts "
                + "and devices. Sample refreshed \(self.sampledAt.formatted(date: .abbreviated, time: .shortened)). "
                + "A modeled API-equivalent estimate, not a bill.")
    }
}

extension UsageStore {
    var midasCodexAutomaticEstimate: MidasCodexEstimate? {
        guard self.midasCodexCalibrationScope == self.tokenCostScope(for: .codex).signature else { return nil }
        return self.midasCodexCalibration?.estimate(now: Date())
    }

    var midasCodexEstimate: MidasCodexEstimate? {
        switch self.settings.midasCodexEstimateMode {
        case .automatic: self.midasCodexAutomaticEstimate
        case .tokensOnly: nil
        case .custom:
            self.settings.midasCloudUSDPerMillionTokens > 0
                ? MidasCodexEstimate(
                    rate: self.settings.midasCloudUSDPerMillionTokens,
                    detail: "Cloud tokens × $\(self.settings.midasCloudUSDPerMillionTokens)/M. "
                        + "A custom approximation, not measured API spend or a bill.") : nil
        }
    }

    func repriceMidasCloudUsage(now: Date = Date()) {
        guard self.settings.midasCloudUsageEnabled, self.settings.costUsageEnabled, self.isEnabled(.codex),
              self.lastTokenFetchScope[.codex] == "cloud:" + Self.cloudAccountSignature(
                  self.settings.codexVisibleAccountProjection.visibleAccounts) else { return }
        let ids = Set(self.settings.codexVisibleAccountProjection.visibleAccounts.map(\.id))
        self.tokenSnapshots[.codex] = Self.cloudTokenSnapshot(
            accounts: self.midasCloudAccounts.filter { ids.contains($0.key) }.map(\.value),
            rate: self.midasCodexEstimate?.rate ?? 0,
            now: now)
    }

    func scheduleMidasCodexCalibration(now: Date) {
        guard !SettingsStore.isRunningTests else { return }
        let scope = self.tokenCostScope(for: .codex)
        if self.midasCodexCalibrationScope != scope.signature {
            self.midasCodexCalibrationTask?.cancel()
            self.midasCodexCalibrationTask = nil
            self.midasCodexCalibration = nil
            self.midasCodexCalibrationAttempt = nil
            self.midasCodexCalibrationScope = scope.signature
        }
        guard self.midasCodexCalibrationTask == nil else { return }
        if let last = self.midasCodexCalibrationAttempt, now.timeIntervalSince(last) < 300 { return }
        self.midasCodexCalibrationAttempt = now
        let generation = UUID()
        self.midasCodexCalibrationGeneration = generation
        self.midasCodexCalibrationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.midasCodexCalibrationGeneration == generation { self.midasCodexCalibrationTask = nil }
            }
            let fresh = try? await self.costUsageFetcher.loadTokenSnapshot(
                provider: .codex,
                environment: self.environmentBase,
                now: now,
                codexHomePath: scope.codexHomePath,
                codexAdditionalHomePaths: scope.additionalHomes,
                historyDays: 30,
                refreshPricingInBackground: false)
            guard !Task.isCancelled, self.midasCodexCalibrationGeneration == generation,
                  self.tokenCostScope(for: .codex).signature == scope.signature else { return }
            if let fresh {
                self.midasCodexCalibration = MidasCodexCalibration.make(
                    snapshot: fresh,
                    now: now)
            }
            self.repriceMidasCloudUsage()
            self.persistWidgetSnapshot(reason: "codex-automatic-estimate")
        }
    }
}
