import Foundation

enum CostUsagePricing {
    private static let codexPriorityInputTokenLimit = 272_000

    struct CodexPricing {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        let cacheReadInputCostPerToken: Double?
        let displayLabel: String?

        let thresholdTokens: Int?
        let inputCostPerTokenAboveThreshold: Double?
        let outputCostPerTokenAboveThreshold: Double?
        let cacheReadInputCostPerTokenAboveThreshold: Double?
        let priorityInputCostPerToken: Double?
        let priorityOutputCostPerToken: Double?
        let priorityCacheReadInputCostPerToken: Double?

        init(
            inputCostPerToken: Double,
            outputCostPerToken: Double,
            cacheReadInputCostPerToken: Double?,
            displayLabel: String?,
            thresholdTokens: Int? = nil,
            inputCostPerTokenAboveThreshold: Double? = nil,
            outputCostPerTokenAboveThreshold: Double? = nil,
            cacheReadInputCostPerTokenAboveThreshold: Double? = nil,
            priorityInputCostPerToken: Double? = nil,
            priorityOutputCostPerToken: Double? = nil,
            priorityCacheReadInputCostPerToken: Double? = nil)
        {
            self.inputCostPerToken = inputCostPerToken
            self.outputCostPerToken = outputCostPerToken
            self.cacheReadInputCostPerToken = cacheReadInputCostPerToken
            self.displayLabel = displayLabel
            self.thresholdTokens = thresholdTokens
            self.inputCostPerTokenAboveThreshold = inputCostPerTokenAboveThreshold
            self.outputCostPerTokenAboveThreshold = outputCostPerTokenAboveThreshold
            self.cacheReadInputCostPerTokenAboveThreshold = cacheReadInputCostPerTokenAboveThreshold
            self.priorityInputCostPerToken = priorityInputCostPerToken
            self.priorityOutputCostPerToken = priorityOutputCostPerToken
            self.priorityCacheReadInputCostPerToken = priorityCacheReadInputCostPerToken
        }
    }

    struct ClaudePricing {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        let cacheCreationInputCostPerToken: Double
        let cacheReadInputCostPerToken: Double

        let thresholdTokens: Int?
        let inputCostPerTokenAboveThreshold: Double?
        let outputCostPerTokenAboveThreshold: Double?
        let cacheCreationInputCostPerTokenAboveThreshold: Double?
        let cacheReadInputCostPerTokenAboveThreshold: Double?
    }

    /// z.ai cost is an *estimate*: the z.ai model-usage API exposes aggregate per-model token
    /// counts (no input/output split, no real billing). We price each model with a single blended
    /// USD-per-token rate derived from public z.ai/Zhipu list pricing. Built-ins are a fallback;
    /// models.dev (provider id `zai`) wins when available so rates stay current.
    struct ZaiPricing {
        let costPerToken: Double
        let displayLabel: String?
    }

    /// Which Meta Model API tier priced a bucket of Muse tokens.
    enum MetaPricingTier: String, Sendable {
        case contributor
        case standard
    }

    /// Meta (Muse Spark) USD-per-token rates, from Meta's public Model API pricing.
    ///
    /// Contributor tier (data-sharing consent): $0.10/M input, $0.20/M output,
    /// $0.002/M cached input. Standard tier: $1.25/M input, $4.25/M output,
    /// $0.15/M cached input. Reasoning tokens bill at the output rate.
    /// Verify against https://dev.meta.ai/docs before tightening.
    struct MetaPricing: Sendable, Equatable {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        let cacheReadInputCostPerToken: Double
        let tier: MetaPricingTier
        let displayLabel: String

        static let contributor = MetaPricing(
            inputCostPerToken: 1.0e-7,
            outputCostPerToken: 2.0e-7,
            cacheReadInputCostPerToken: 2.0e-9,
            tier: .contributor,
            displayLabel: "Contributor $0.10/$0.20 per 1M in/out")

        static let standard = MetaPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 4.25e-6,
            cacheReadInputCostPerToken: 1.5e-7,
            tier: .standard,
            displayLabel: "Standard $1.25/$4.25 per 1M in/out")
    }

    /// Classifies one Muse model id into a pricing tier. Contributor builds carry
    /// "contributor" in the name (e.g. `muse-spark-1.3-contributor`); other Muse
    /// models price at the standard tier. Unknown models return nil (unpriced).
    static func metaPricingTier(forModel raw: String) -> MetaPricingTier? {
        let model = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !model.isEmpty else { return nil }
        if model.contains("contributor") {
            return .contributor
        }
        if model.contains("muse-spark") || model.contains("muse") {
            return .standard
        }
        return nil
    }

    /// Tier for a day's model mix. Prices only when every reported model agrees;
    /// mixed or unknown mixes return nil so estimates never silently misattribute.
    static func metaPricingTier(forModels models: [String]) -> MetaPricingTier? {
        let tiers = models.compactMap { self.metaPricingTier(forModel: $0) }
        guard !models.isEmpty, tiers.count == models.count else { return nil }
        guard let first = tiers.first, tiers.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    static func metaPricing(for tier: MetaPricingTier) -> MetaPricing {
        switch tier {
        case .contributor:
            .contributor
        case .standard:
            .standard
        }
    }

    /// USD cost for token buckets at a Meta tier. Reasoning bills at output rate.
    static func metaCost(
        inputTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int,
        cacheReadTokens: Int,
        tier: MetaPricingTier) -> Double
    {
        let pricing = self.metaPricing(for: tier)
        return Double(max(0, inputTokens)) * pricing.inputCostPerToken
            + Double(max(0, outputTokens + reasoningTokens)) * pricing.outputCostPerToken
            + Double(max(0, cacheReadTokens)) * pricing.cacheReadInputCostPerToken
    }

    private struct ClaudeCostTokens {
        let input: Int
        let cacheRead: Int
        let cacheCreation: Int
        let cacheCreation1h: Int
        let output: Int
    }

    private static let codex: [String: CodexPricing] = [
        "gpt-5": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5-codex": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5-mini": CodexPricing(
            inputCostPerToken: 2.5e-7,
            outputCostPerToken: 2e-6,
            cacheReadInputCostPerToken: 2.5e-8,
            displayLabel: nil),
        "gpt-5-nano": CodexPricing(
            inputCostPerToken: 5e-8,
            outputCostPerToken: 4e-7,
            cacheReadInputCostPerToken: 5e-9,
            displayLabel: nil),
        "gpt-5-pro": CodexPricing(
            inputCostPerToken: 1.5e-5,
            outputCostPerToken: 1.2e-4,
            cacheReadInputCostPerToken: nil,
            displayLabel: nil),
        "gpt-5.1": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5.1-codex": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5.1-codex-max": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5.1-codex-mini": CodexPricing(
            inputCostPerToken: 2.5e-7,
            outputCostPerToken: 2e-6,
            cacheReadInputCostPerToken: 2.5e-8,
            displayLabel: nil),
        "gpt-5.2": CodexPricing(
            inputCostPerToken: 1.75e-6,
            outputCostPerToken: 1.4e-5,
            cacheReadInputCostPerToken: 1.75e-7,
            displayLabel: nil),
        "gpt-5.2-codex": CodexPricing(
            inputCostPerToken: 1.75e-6,
            outputCostPerToken: 1.4e-5,
            cacheReadInputCostPerToken: 1.75e-7,
            displayLabel: nil),
        "gpt-5.2-pro": CodexPricing(
            inputCostPerToken: 2.1e-5,
            outputCostPerToken: 1.68e-4,
            cacheReadInputCostPerToken: nil,
            displayLabel: nil),
        "gpt-5.3-codex": CodexPricing(
            inputCostPerToken: 1.75e-6,
            outputCostPerToken: 1.4e-5,
            cacheReadInputCostPerToken: 1.75e-7,
            displayLabel: nil),
        "gpt-5.3-codex-spark": CodexPricing(
            inputCostPerToken: 0,
            outputCostPerToken: 0,
            cacheReadInputCostPerToken: 0,
            displayLabel: "Research Preview"),
        "gpt-5.4": CodexPricing(
            inputCostPerToken: 2.5e-6,
            outputCostPerToken: 1.5e-5,
            cacheReadInputCostPerToken: 2.5e-7,
            displayLabel: nil,
            thresholdTokens: 272_000,
            inputCostPerTokenAboveThreshold: 5e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheReadInputCostPerTokenAboveThreshold: 5e-7,
            priorityInputCostPerToken: 5e-6,
            priorityOutputCostPerToken: 3e-5,
            priorityCacheReadInputCostPerToken: 5e-7),
        "gpt-5.4-mini": CodexPricing(
            inputCostPerToken: 7.5e-7,
            outputCostPerToken: 4.5e-6,
            cacheReadInputCostPerToken: 7.5e-8,
            displayLabel: nil,
            priorityInputCostPerToken: 1.5e-6,
            priorityOutputCostPerToken: 9e-6,
            priorityCacheReadInputCostPerToken: 1.5e-7),
        "gpt-5.4-nano": CodexPricing(
            inputCostPerToken: 2e-7,
            outputCostPerToken: 1.25e-6,
            cacheReadInputCostPerToken: 2e-8,
            displayLabel: nil),
        "gpt-5.4-pro": CodexPricing(
            inputCostPerToken: 3e-5,
            outputCostPerToken: 1.8e-4,
            cacheReadInputCostPerToken: nil,
            displayLabel: nil),
        "gpt-5.5": CodexPricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 3e-5,
            cacheReadInputCostPerToken: 5e-7,
            displayLabel: nil,
            thresholdTokens: 272_000,
            inputCostPerTokenAboveThreshold: 1e-5,
            outputCostPerTokenAboveThreshold: 4.5e-5,
            cacheReadInputCostPerTokenAboveThreshold: 1e-6,
            priorityInputCostPerToken: 1.25e-5,
            priorityOutputCostPerToken: 7.5e-5,
            priorityCacheReadInputCostPerToken: 1.25e-6),
        "gpt-5.5-pro": CodexPricing(
            inputCostPerToken: 3e-5,
            outputCostPerToken: 1.8e-4,
            cacheReadInputCostPerToken: nil,
            displayLabel: nil),
    ]

    static func codexBuiltInPricingFingerprint() -> String {
        var parts = ["priorityInputTokenLimit=\(self.codexPriorityInputTokenLimit)"]
        for model in self.codex.keys.sorted() {
            guard let pricing = self.codex[model] else { continue }
            parts.append([
                "model=\(model)",
                self.optionalPricingFingerprint(pricing.inputCostPerToken),
                self.optionalPricingFingerprint(pricing.outputCostPerToken),
                self.optionalPricingFingerprint(pricing.cacheReadInputCostPerToken),
                pricing.displayLabel ?? "nil",
                pricing.thresholdTokens.map(String.init) ?? "nil",
                self.optionalPricingFingerprint(pricing.inputCostPerTokenAboveThreshold),
                self.optionalPricingFingerprint(pricing.outputCostPerTokenAboveThreshold),
                self.optionalPricingFingerprint(pricing.cacheReadInputCostPerTokenAboveThreshold),
                self.optionalPricingFingerprint(pricing.priorityInputCostPerToken),
                self.optionalPricingFingerprint(pricing.priorityOutputCostPerToken),
                self.optionalPricingFingerprint(pricing.priorityCacheReadInputCostPerToken),
            ].joined(separator: "|"))
        }
        return parts.joined(separator: "\n")
    }

    private static func optionalPricingFingerprint(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.17g", value)
    }

    private static let claude: [String: ClaudePricing] = [
        "claude-fable-5": ClaudePricing(
            inputCostPerToken: 1e-5,
            outputCostPerToken: 5e-5,
            cacheCreationInputCostPerToken: 1.25e-5,
            cacheReadInputCostPerToken: 1e-6,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-haiku-4-5-20251001": ClaudePricing(
            inputCostPerToken: 1e-6,
            outputCostPerToken: 5e-6,
            cacheCreationInputCostPerToken: 1.25e-6,
            cacheReadInputCostPerToken: 1e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-haiku-4-5": ClaudePricing(
            inputCostPerToken: 1e-6,
            outputCostPerToken: 5e-6,
            cacheCreationInputCostPerToken: 1.25e-6,
            cacheReadInputCostPerToken: 1e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-5-20251101": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-5": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-6-20260205": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-6": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-7": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-8": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-sonnet-4-5": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 6e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6,
            cacheReadInputCostPerTokenAboveThreshold: 6e-7),
        "claude-sonnet-4-6": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-sonnet-4-5-20250929": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 6e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6,
            cacheReadInputCostPerTokenAboveThreshold: 6e-7),
        "claude-opus-4-20250514": ClaudePricing(
            inputCostPerToken: 1.5e-5,
            outputCostPerToken: 7.5e-5,
            cacheCreationInputCostPerToken: 1.875e-5,
            cacheReadInputCostPerToken: 1.5e-6,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-1": ClaudePricing(
            inputCostPerToken: 1.5e-5,
            outputCostPerToken: 7.5e-5,
            cacheCreationInputCostPerToken: 1.875e-5,
            cacheReadInputCostPerToken: 1.5e-6,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-sonnet-4-20250514": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 6e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6,
            cacheReadInputCostPerTokenAboveThreshold: 6e-7),
    ]

    private static let claudeFullContextStandardPricingCutoff = Date(timeIntervalSince1970: 1_773_360_000)
    private static let claudeHistoricalLongContext: [String: ClaudePricing] = [
        "claude-opus-4-6": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 1e-5,
            outputCostPerTokenAboveThreshold: 3.75e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 1.25e-5,
            cacheReadInputCostPerTokenAboveThreshold: 1e-6),
        "claude-sonnet-4-6": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 6e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6,
            cacheReadInputCostPerTokenAboveThreshold: 6e-7),
    ]

    /// Blended USD-per-token rates for z.ai/Zhipu GLM models.
    ///
    /// Values are approximate, computed from z.ai's public USD list prices (roughly a 75/25
    /// input/output token mix typical of agentic coding traffic). Free tier models are priced 0.
    /// Verify against https://z.ai/pricing or https://open.bigmodel.cn/pricing before tightening;
    /// the `zaiBuiltInPricingFingerprint` + models.dev upstream path handle corrections.
    private static let zai: [String: ZaiPricing] = [
        "glm-4.6": ZaiPricing(costPerToken: 1.0e-6, displayLabel: nil),
        "glm-4-6": ZaiPricing(costPerToken: 1.0e-6, displayLabel: nil),
        "glm-4.5": ZaiPricing(costPerToken: 1.0e-6, displayLabel: nil),
        "glm-4-5": ZaiPricing(costPerToken: 1.0e-6, displayLabel: nil),
        "glm-4.5-air": ZaiPricing(costPerToken: 2.0e-7, displayLabel: nil),
        "glm-4-5-air": ZaiPricing(costPerToken: 2.0e-7, displayLabel: nil),
        "glm-4-plus": ZaiPricing(costPerToken: 7.0e-7, displayLabel: nil),
        "glm-4-air": ZaiPricing(costPerToken: 1.0e-7, displayLabel: nil),
        "glm-4-long": ZaiPricing(costPerToken: 1.0e-7, displayLabel: nil),
        "glm-4v": ZaiPricing(costPerToken: 7.0e-7, displayLabel: nil),
        "glm-4v-flash": ZaiPricing(costPerToken: 0, displayLabel: "Free"),
        "glm-4-flash": ZaiPricing(costPerToken: 0, displayLabel: "Free"),
        "glm-4-flashx": ZaiPricing(costPerToken: 0, displayLabel: "Free"),
    ]

    static func zaiBuiltInPricingFingerprint() -> String {
        var parts: [String] = []
        for model in self.zai.keys.sorted() {
            guard let pricing = self.zai[model] else { continue }
            parts.append([
                "model=\(model)",
                self.optionalPricingFingerprint(pricing.costPerToken),
                pricing.displayLabel ?? "nil",
            ].joined(separator: "|"))
        }
        return parts.joined(separator: "\n")
    }

    private static let codexModelsDevProviderID = "openai"
    private static let claudeModelsDevProviderID = "anthropic"
    private static let zaiModelsDevProviderID = "zai"

    static func normalizeCodexModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("openai/") {
            trimmed = String(trimmed.dropFirst("openai/".count))
        }

        if self.codex[trimmed] != nil {
            return trimmed
        }

        if let datedSuffix = trimmed.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            let base = String(trimmed[..<datedSuffix.lowerBound])
            if self.codex[base] != nil {
                return base
            }
        }
        return trimmed
    }

    static func codexDisplayLabel(model: String) -> String? {
        let key = self.normalizeCodexModel(model)
        return self.codex[key]?.displayLabel
    }

    static func zaiDisplayLabel(model: String) -> String? {
        let key = self.normalizeZaiModel(model)
        return self.zai[key]?.displayLabel
    }

    /// Normalizes a z.ai/Zhipu model id to a built-in table key.
    /// Handles `zhipu/`, `zai/` prefixes and dated snapshot suffixes. The table lists both
    /// dot and dash variants (e.g. `glm-4.6` and `glm-4-6`), so no separator swapping is needed.
    static func normalizeZaiModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("zhipu/") {
            trimmed = String(trimmed.dropFirst("zhipu/".count))
        } else if trimmed.lowercased().hasPrefix("zai/") {
            trimmed = String(trimmed.dropFirst("zai/".count))
        }

        if self.zai[trimmed] != nil {
            return trimmed
        }

        // Snapshot/dated suffixes, e.g. glm-4.6-20260101.
        if let datedSuffix = trimmed.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            let base = String(trimmed[..<datedSuffix.lowerBound])
            if self.zai[base] != nil {
                return base
            }
        }

        return trimmed
    }

    static func normalizeClaudeModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("anthropic.") {
            trimmed = String(trimmed.dropFirst("anthropic.".count))
        }

        if let lastDot = trimmed.lastIndex(of: "."),
           trimmed.contains("claude-")
        {
            let tail = String(trimmed[trimmed.index(after: lastDot)...])
            if tail.hasPrefix("claude-") {
                trimmed = tail
            }
        }

        if let vRange = trimmed.range(of: #"-v\d+:\d+$"#, options: .regularExpression) {
            trimmed.removeSubrange(vRange)
        }

        if let baseRange = trimmed.range(of: #"-\d{8}$"#, options: .regularExpression) {
            let base = String(trimmed[..<baseRange.lowerBound])
            if self.claude[base] != nil {
                return base
            }
        }

        return trimmed
    }

    static func codexCostUSD(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil) -> Double?
    {
        let key = self.normalizeCodexModel(model)
        if let lookup = self.modelsDevLookup(
            providerID: self.codexModelsDevProviderID,
            model: model,
            catalog: modelsDevCatalog,
            cacheRoot: modelsDevCacheRoot)
        {
            return self.codexCostUSD(
                pricing: lookup.pricing,
                thresholdTokens: self.codex[key]?.thresholdTokens,
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: outputTokens)
        }

        guard let pricing = self.codex[key] else { return nil }
        return self.codexCostUSD(
            pricing: pricing,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens)
    }

    static func codexPriorityCostUSD(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int = 0,
        outputTokens: Int) -> Double?
    {
        let key = self.normalizeCodexModel(model)
        guard let pricing = self.codex[key],
              let priorityInputCostPerToken = pricing.priorityInputCostPerToken,
              let priorityOutputCostPerToken = pricing.priorityOutputCostPerToken
        else { return nil }
        if max(0, inputTokens) > self.codexPriorityInputTokenLimit {
            return nil
        }

        let priorityPricing = CodexPricing(
            inputCostPerToken: priorityInputCostPerToken,
            outputCostPerToken: priorityOutputCostPerToken,
            cacheReadInputCostPerToken: pricing.priorityCacheReadInputCostPerToken,
            displayLabel: nil)
        return self.codexCostUSD(
            pricing: priorityPricing,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens)
    }

    private static func codexCostUSD(
        pricing: CodexPricing,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int) -> Double
    {
        let cached = min(max(0, cachedInputTokens), max(0, inputTokens))
        let nonCached = max(0, inputTokens - cached)
        let cachedRate = pricing.cacheReadInputCostPerToken ?? pricing.inputCostPerToken

        let usesLongContextRates = pricing.thresholdTokens.map { max(0, inputTokens) > $0 } ?? false
        let inputRate = usesLongContextRates
            ? pricing.inputCostPerTokenAboveThreshold ?? pricing.inputCostPerToken
            : pricing.inputCostPerToken
        let cachedInputRate = usesLongContextRates
            ? pricing.cacheReadInputCostPerTokenAboveThreshold ?? cachedRate
            : cachedRate
        let outputRate = usesLongContextRates
            ? pricing.outputCostPerTokenAboveThreshold ?? pricing.outputCostPerToken
            : pricing.outputCostPerToken

        return (Double(nonCached) * inputRate)
            + (Double(cached) * cachedInputRate)
            + (Double(max(0, outputTokens)) * outputRate)
    }

    private static func codexCostUSD(
        pricing: ModelsDevPricingInfo,
        thresholdTokens: Int? = nil,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int) -> Double
    {
        self.codexCostUSD(
            pricing: CodexPricing(
                inputCostPerToken: pricing.inputCostPerToken,
                outputCostPerToken: pricing.outputCostPerToken,
                cacheReadInputCostPerToken: pricing.cacheReadInputCostPerToken,
                displayLabel: nil,
                thresholdTokens: thresholdTokens ?? pricing.thresholdTokens,
                inputCostPerTokenAboveThreshold: pricing.inputCostPerTokenAboveThreshold,
                outputCostPerTokenAboveThreshold: pricing.outputCostPerTokenAboveThreshold,
                cacheReadInputCostPerTokenAboveThreshold: pricing.cacheReadInputCostPerTokenAboveThreshold),
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens)
    }

    static func claudeCostUSD(
        model: String,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        cacheCreationInputTokens: Int,
        cacheCreationInputTokens1h: Int = 0,
        outputTokens: Int,
        pricingDate: Date? = nil,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil) -> Double?
    {
        let tokens = ClaudeCostTokens(
            input: inputTokens,
            cacheRead: cacheReadInputTokens,
            cacheCreation: cacheCreationInputTokens,
            cacheCreation1h: cacheCreationInputTokens1h,
            output: outputTokens)
        let key = self.normalizeClaudeModel(model)
        if let pricingDate,
           let historicalPricing = self.claudeHistoricalLongContext[key],
           let currentPricing = self.claude[key]
        {
            return self.claudeCostUSD(
                pricing: pricingDate < self.claudeFullContextStandardPricingCutoff
                    ? historicalPricing
                    : currentPricing,
                tokens: tokens)
        }
        if let lookup = self.modelsDevLookup(
            providerID: self.claudeModelsDevProviderID,
            model: model,
            catalog: modelsDevCatalog,
            cacheRoot: modelsDevCacheRoot)
        {
            return self.claudeCostUSD(
                pricing: lookup.pricing,
                tokens: tokens)
        }

        guard let pricing = self.claude[key] else { return nil }
        return self.claudeCostUSD(
            pricing: pricing,
            tokens: tokens)
    }

    private static func claudeCostUSD(
        pricing: ClaudePricing,
        tokens: ClaudeCostTokens) -> Double
    {
        let input = max(0, tokens.input)
        let cacheRead = max(0, tokens.cacheRead)
        let cacheCreationTotal = max(0, tokens.cacheCreation)
        let cacheCreation1h = min(max(0, tokens.cacheCreation1h), cacheCreationTotal)
        let cacheCreation5m = cacheCreationTotal - cacheCreation1h
        let usesLongContextRates = pricing.thresholdTokens.map {
            input + cacheRead + cacheCreationTotal > $0
        } ?? false
        let inputRate = usesLongContextRates
            ? pricing.inputCostPerTokenAboveThreshold ?? pricing.inputCostPerToken
            : pricing.inputCostPerToken
        let cacheReadRate = usesLongContextRates
            ? pricing.cacheReadInputCostPerTokenAboveThreshold ?? pricing.cacheReadInputCostPerToken
            : pricing.cacheReadInputCostPerToken
        let cacheCreation5mRate = usesLongContextRates
            ? pricing.cacheCreationInputCostPerTokenAboveThreshold ?? pricing.cacheCreationInputCostPerToken
            : pricing.cacheCreationInputCostPerToken
        let outputRate = usesLongContextRates
            ? pricing.outputCostPerTokenAboveThreshold ?? pricing.outputCostPerToken
            : pricing.outputCostPerToken

        return Double(input) * inputRate
            + Double(cacheRead) * cacheReadRate
            + Double(cacheCreation5m) * cacheCreation5mRate
            + Double(cacheCreation1h) * inputRate * 2
            + Double(max(0, tokens.output)) * outputRate
    }

    private static func claudeCostUSD(
        pricing: ModelsDevPricingInfo,
        tokens: ClaudeCostTokens) -> Double
    {
        self.claudeCostUSD(
            pricing: ClaudePricing(
                inputCostPerToken: pricing.inputCostPerToken,
                outputCostPerToken: pricing.outputCostPerToken,
                cacheCreationInputCostPerToken: pricing.cacheCreationInputCostPerToken ?? pricing.inputCostPerToken,
                cacheReadInputCostPerToken: pricing.cacheReadInputCostPerToken ?? pricing.inputCostPerToken,
                thresholdTokens: pricing.thresholdTokens,
                inputCostPerTokenAboveThreshold: pricing.inputCostPerTokenAboveThreshold,
                outputCostPerTokenAboveThreshold: pricing.outputCostPerTokenAboveThreshold,
                cacheCreationInputCostPerTokenAboveThreshold: pricing.cacheCreationInputCostPerTokenAboveThreshold,
                cacheReadInputCostPerTokenAboveThreshold: pricing.cacheReadInputCostPerTokenAboveThreshold),
            tokens: tokens)
    }

    static func modelsDevCatalog(now: Date = Date(), cacheRoot: URL? = nil) -> ModelsDevCatalog? {
        ModelsDevCache.load(now: now, cacheRoot: cacheRoot).artifact?.catalog
    }

    /// Estimated z.ai cost from aggregate per-model token counts.
    ///
    /// z.ai's model-usage API exposes only total tokens per model (no input/output split), so the
    /// estimate uses a single blended USD-per-token rate. Returns `nil` for unknown models so
    /// callers do not invent cost; free models return `0`.
    static func zaiCostUSD(
        model: String,
        totalTokens: Int,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil) -> Double?
    {
        if let lookup = self.modelsDevLookup(
            providerID: self.zaiModelsDevProviderID,
            model: model,
            catalog: modelsDevCatalog,
            cacheRoot: modelsDevCacheRoot)
        {
            let blendedPerToken = (lookup.pricing.inputCostPerToken + lookup.pricing.outputCostPerToken) / 2
            return Double(max(0, totalTokens)) * blendedPerToken
        }

        let key = self.normalizeZaiModel(model)
        guard let pricing = self.zai[key] else { return nil }
        return Double(max(0, totalTokens)) * pricing.costPerToken
    }

    private static func modelsDevLookup(
        providerID: String,
        model: String,
        catalog: ModelsDevCatalog?,
        cacheRoot: URL?) -> ModelsDevPricingLookup?
    {
        if let catalog {
            return catalog.pricing(providerID: providerID, modelID: model)
        }

        return ModelsDevPricingPipeline.lookup(
            providerID: providerID,
            modelID: model,
            cacheRoot: cacheRoot)
    }
}
