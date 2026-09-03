import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    private static let costSupportedProviders: Set<UsageProvider> = [.claude, .codex, .zai, .meta, .openai, .cursor]

    static func runCost(_ values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
        let config = CodexBarCLI.loadConfig(output: output)
        let selection = CodexBarCLI.decodeProvider(from: values, config: config)
        let providers = Self.costProviders(from: selection)
        let unsupported = selection.asList.filter { !Self.costSupportedProviders.contains($0) }
        if !unsupported.isEmpty {
            let names = unsupported
                .map { ProviderDescriptorRegistry.descriptor(for: $0).metadata.displayName }
                .sorted()
                .joined(separator: ", ")
            if !output.jsonOnly {
                Self.writeStderr("Skipping providers without local cost usage: \(names)\n")
            }
        }
        guard !providers.isEmpty else {
            Self.exit(
                code: .failure,
                message: "Error: cost is only supported for Claude, Codex, z.ai, Meta, OpenAI, and Cursor.",
                output: output,
                kind: .args)
        }

        let format = output.format
        let forceRefresh = values.flags.contains("refresh")
        let useColor = Self.shouldUseColor(noColor: values.flags.contains("noColor"), format: format)
        let historyDays = Self.decodeCostHistoryDays(from: values)

        let fetcher = CostUsageFetcher()
        var sections: [String] = []
        var payload: [CostPayload] = []
        var successes: [(provider: UsageProvider, snapshot: CostUsageTokenSnapshot)] = []
        var exitCode: ExitCode = .success

        // Merge config-stored API keys into the environment so key-backed cost paths
        // (OpenAI Admin API, z.ai) work the same as `config set-api-key` promises.
        let tokenSelection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        let tokenContext = try? TokenAccountCLIContext(
            selection: tokenSelection,
            config: config,
            verbose: false)

        for provider in providers {
            do {
                let environment = tokenContext?.environment(
                    base: ProcessInfo.processInfo.environment,
                    provider: provider,
                    account: nil) ?? ProcessInfo.processInfo.environment
                let cursorSettings = tokenContext?.settingsSnapshot(for: provider, account: nil)?.cursor
                // Cost usage is local-only, except key-backed providers (OpenAI, z.ai)
                // and the Cursor web session, which use the merged environment above.
                let snapshot = try await fetcher.loadTokenSnapshot(
                    provider: provider,
                    environment: environment,
                    forceRefresh: forceRefresh,
                    historyDays: historyDays,
                    refreshPricingInBackground: false,
                    cursorSettings: cursorSettings)
                successes.append((provider, snapshot))
                switch format {
                case .text:
                    sections.append(Self.renderCostText(provider: provider, snapshot: snapshot, useColor: useColor))
                case .json:
                    payload.append(Self.makeCostPayload(provider: provider, snapshot: snapshot, error: nil))
                }
            } catch {
                exitCode = Self.mapError(error)
                if format == .json {
                    payload.append(Self.makeCostPayload(provider: provider, snapshot: nil, error: error))
                } else if !output.jsonOnly {
                    Self.writeStderr("Error: \(error.localizedDescription)\n")
                }
            }
        }

        switch format {
        case .text:
            if !sections.isEmpty {
                print(sections.joined(separator: "\n\n"))
            }
            if successes.count > 1, let total = Self.renderTotalSection(successes, useColor: useColor) {
                print("\n\(total)")
            }
        case .json:
            if !payload.isEmpty {
                Self.printJSON(payload, pretty: output.pretty)
            }
        }

        Self.exit(code: exitCode, output: output, kind: exitCode == .success ? .runtime : .provider)
    }

    /// Combined 30-day $ + token line across providers, priced as if every token were
    /// billed at full public API rates (Meta counts at standard-API equivalent).
    static func renderTotalSection(
        _ successes: [(provider: UsageProvider, snapshot: CostUsageTokenSnapshot)],
        useColor: Bool) -> String?
    {
        let tokens = successes.compactMap(\.snapshot.last30DaysTokens).reduce(0, +)
        var dollars = 0.0
        var priced: [String] = []
        var unpriced: [String] = []
        for success in successes {
            let name = ProviderDescriptorRegistry.descriptor(for: success.provider).metadata.displayName
            if let cost = CostUsageFetcher.listPriceCostUSD(
                provider: success.provider,
                snapshot: success.snapshot)
            {
                dollars += cost
                priced.append(name)
            } else {
                unpriced.append(name)
            }
        }
        guard !priced.isEmpty else { return nil }
        let code = successes.first?.snapshot.currencyCode ?? "USD"
        let header = Self.costHeaderLine("Total — 30d at list API rates", useColor: useColor)
        var line = "Total: \(UsageFormatter.currencyString(dollars, currencyCode: code))"
        if tokens > 0 {
            line += " · \(UsageFormatter.tokenCountString(tokens)) tokens"
        }
        line += " (\(priced.sorted().joined(separator: ", "))"
        if !unpriced.isEmpty {
            line += "; no $ data: \(unpriced.sorted().joined(separator: ", "))"
        }
        line += ")"
        return "\(header)\n\(line)"
    }

    static func renderCostText(
        provider: UsageProvider,
        snapshot: CostUsageTokenSnapshot,
        useColor: Bool) -> String
    {
        let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        let header = Self.costHeaderLine("\(name) Cost (API-rate estimate)", useColor: useColor)

        let todayCost = snapshot.sessionCostUSD
            .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) } ?? "—"
        // The legacy Cursor billing-cycle figure is not a daily one; event-backed Cursor
        // snapshots (which carry metered spend) report a real Today line instead.
        let todayLabel = provider == .cursor && snapshot.meteredCostUSD == nil ? "Billing cycle" : "Today"
        let todayTokens = snapshot.sessionTokens.map { UsageFormatter.tokenCountString($0) }
        let todayLine = todayTokens.map { "\(todayLabel): \(todayCost) · \($0) tokens" }
            ?? "\(todayLabel): \(todayCost)"

        let monthCost = snapshot.last30DaysCostUSD
            .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) } ?? "—"
        let monthTokens = snapshot.last30DaysTokens.map { UsageFormatter.tokenCountString($0) }
        let historyLabel = snapshot.historyLabel
            ?? (snapshot.historyDays == 1 ? "Today" : "Last \(snapshot.historyDays) days")
        let monthLine = monthTokens.map {
            "\(historyLabel): \(monthCost) · \($0) tokens"
        } ?? "\(historyLabel): \(monthCost)"

        // Plan-metered spend over the same window (what Cursor actually deducts), shown
        // alongside the API-rate estimate. Only providers like Cursor report it.
        let meteredLine: String? = snapshot.meteredCostUSD.map {
            let amount = UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode)
            return "Cursor-metered: \(amount) (\(historyLabel.lowercased()))"
        }

        // Meta skips the Today line: the card is 30-day API tokens + both dollar
        // figures, and a daily figure duplicates that story with less context.
        var lines = provider == .meta ? [header, monthLine] : [header, todayLine, monthLine]
        if let meteredLine {
            lines.append(meteredLine)
        }
        if provider == .meta {
            if let sparkline = Self.tokenSparkline(from: snapshot) {
                lines.append("Daily tokens: \(sparkline)")
            }
            if let equivalent = snapshot.last30DaysAPIEquivalentCostUSD {
                lines.append(
                    "At standard API rates: " +
                        "\(UsageFormatter.currencyString(equivalent, currencyCode: snapshot.currencyCode))")
            }
        }
        lines.append(UsageFormatter.costEstimateHint(provider: provider))
        return lines.joined(separator: "\n")
    }

    /// Compact 30-day token graphic (▁▂▃▄▅▆▇█ per day, oldest first).
    static func tokenSparkline(from snapshot: CostUsageTokenSnapshot) -> String? {
        let blocks = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        let values = snapshot.daily.suffix(max(1, snapshot.historyDays)).map { $0.totalTokens ?? 0 }
        guard let maxValue = values.max(), maxValue > 0 else { return nil }
        return values.map { value in
            let index = min(blocks.count - 1, (value * blocks.count) / (maxValue + 1))
            return blocks[index]
        }.joined()
    }

    private static func costHeaderLine(_ header: String, useColor: Bool) -> String {
        guard useColor else { return header }
        return "\u{001B}[1;36m\(header)\u{001B}[0m"
    }

    static func costProviders(from selection: ProviderSelection) -> [UsageProvider] {
        selection.asList.filter { Self.costSupportedProviders.contains($0) }
    }

    static func makeCostPayload(
        provider: UsageProvider,
        snapshot: CostUsageTokenSnapshot?,
        error: Error?) -> CostPayload
    {
        let daily = snapshot?.daily.map { entry in
            CostDailyEntryPayload(
                date: entry.date,
                inputTokens: entry.inputTokens,
                outputTokens: entry.outputTokens,
                cacheReadTokens: entry.cacheReadTokens,
                cacheCreationTokens: entry.cacheCreationTokens,
                totalTokens: entry.totalTokens,
                costUSD: entry.costUSD,
                apiEquivalentCostUSD: entry.apiEquivalentCostUSD,
                modelsUsed: entry.modelsUsed,
                modelBreakdowns: entry.modelBreakdowns?.map { breakdown in
                    CostModelBreakdownPayload(
                        modelName: breakdown.modelName,
                        costUSD: breakdown.costUSD,
                        totalTokens: breakdown.totalTokens)
                })
        } ?? []

        return CostPayload(
            provider: provider.rawValue,
            source: provider == .zai ? "estimated" : "local",
            updatedAt: snapshot?.updatedAt ?? (error == nil ? nil : Date()),
            currencyCode: snapshot?.currencyCode,
            sessionTokens: snapshot?.sessionTokens,
            sessionCostUSD: snapshot?.sessionCostUSD,
            historyDays: snapshot?.historyDays,
            last30DaysTokens: snapshot?.last30DaysTokens,
            last30DaysCostUSD: snapshot?.last30DaysCostUSD,
            last30DaysAPIEquivalentCostUSD: snapshot?.last30DaysAPIEquivalentCostUSD,
            meteredCostUSD: snapshot?.meteredCostUSD,
            provenance: snapshot.map(\.costProvenance.rawValue),
            daily: daily,
            totals: snapshot.flatMap(Self.costTotals(from:)),
            error: error.map { Self.makeErrorPayload($0) })
    }

    private static func costTotals(from snapshot: CostUsageTokenSnapshot) -> CostTotalsPayload? {
        let entries = snapshot.daily
        guard !entries.isEmpty else {
            guard snapshot.last30DaysTokens != nil || snapshot.last30DaysCostUSD != nil else { return nil }
            return CostTotalsPayload(
                totalInputTokens: nil,
                totalOutputTokens: nil,
                cacheReadTokens: nil,
                cacheCreationTokens: nil,
                totalTokens: snapshot.last30DaysTokens,
                totalCostUSD: snapshot.last30DaysCostUSD)
        }

        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var totalCacheCreation = 0
        var totalTokens = 0
        var totalCost = 0.0
        var sawInput = false
        var sawOutput = false
        var sawCacheRead = false
        var sawCacheCreation = false
        var sawTokens = false
        var sawCost = false

        for entry in entries {
            if let input = entry.inputTokens {
                totalInput += input
                sawInput = true
            }
            if let output = entry.outputTokens {
                totalOutput += output
                sawOutput = true
            }
            if let cacheRead = entry.cacheReadTokens {
                totalCacheRead += cacheRead
                sawCacheRead = true
            }
            if let cacheCreation = entry.cacheCreationTokens {
                totalCacheCreation += cacheCreation
                sawCacheCreation = true
            }
            if let tokens = entry.totalTokens {
                totalTokens += tokens
                sawTokens = true
            }
            if let cost = entry.costUSD {
                totalCost += cost
                sawCost = true
            }
        }

        // Prefer totals derived from daily rows; fall back to snapshot aggregates when rows omit fields.
        return CostTotalsPayload(
            totalInputTokens: sawInput ? totalInput : nil,
            totalOutputTokens: sawOutput ? totalOutput : nil,
            cacheReadTokens: sawCacheRead ? totalCacheRead : nil,
            cacheCreationTokens: sawCacheCreation ? totalCacheCreation : nil,
            totalTokens: sawTokens ? totalTokens : snapshot.last30DaysTokens,
            totalCostUSD: sawCost ? totalCost : snapshot.last30DaysCostUSD)
    }

    private static func decodeCostHistoryDays(from values: ParsedValues) -> Int {
        guard let raw = values.options["days"]?.last,
              let parsed = Int(raw)
        else { return 30 }
        return max(1, min(365, parsed))
    }
}

struct CostOptions: CommanderParsable {
    @Flag(names: [.short("v"), .long("verbose")], help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long("json-output"), help: "Emit machine-readable logs")
    var jsonOutput: Bool = false

    @Option(name: .long("log-level"), help: "Set log level (trace|verbose|debug|info|warning|error|critical)")
    var logLevel: String?

    @Option(
        name: .long("provider"),
        help: ProviderHelp.optionHelp)
    var provider: ProviderSelection?

    @Option(name: .long("format"), help: "Output format: text | json")
    var format: OutputFormat?

    @Flag(name: .long("json"), help: "")
    var jsonShortcut: Bool = false

    @Flag(name: .long("json-only"), help: "Emit JSON only (suppress non-JSON output)")
    var jsonOnly: Bool = false

    @Flag(name: .long("pretty"), help: "Pretty-print JSON output")
    var pretty: Bool = false

    @Flag(name: .long("no-color"), help: "Disable ANSI colors in text output")
    var noColor: Bool = false

    @Flag(name: .long("refresh"), help: "Force refresh by ignoring cached scans")
    var refresh: Bool = false

    @Option(name: .long("days"), help: "Cost history window in days (1...365)")
    var days: Int?
}

struct CostPayload: Encodable {
    let provider: String
    let source: String
    let updatedAt: Date?
    let currencyCode: String?
    let sessionTokens: Int?
    let sessionCostUSD: Double?
    let historyDays: Int?
    let last30DaysTokens: Int?
    let last30DaysCostUSD: Double?
    let last30DaysAPIEquivalentCostUSD: Double?
    /// Provider-metered spend over the same window (what Cursor actually deducts, as
    /// opposed to the API-rate estimate). Only some providers report this.
    let meteredCostUSD: Double?
    /// How the payload costs were produced (`listPriceEstimate`, `vendorMetered`, `mixed`, `unknown`).
    let provenance: String?
    let daily: [CostDailyEntryPayload]
    let totals: CostTotalsPayload?
    let error: ProviderErrorPayload?

    init(
        provider: String,
        source: String,
        updatedAt: Date?,
        currencyCode: String? = nil,
        sessionTokens: Int?,
        sessionCostUSD: Double?,
        historyDays: Int?,
        last30DaysTokens: Int?,
        last30DaysCostUSD: Double?,
        last30DaysAPIEquivalentCostUSD: Double? = nil,
        meteredCostUSD: Double? = nil,
        provenance: String? = nil,
        daily: [CostDailyEntryPayload],
        totals: CostTotalsPayload?,
        error: ProviderErrorPayload?)
    {
        self.provider = provider
        self.source = source
        self.updatedAt = updatedAt
        self.currencyCode = currencyCode
        self.sessionTokens = sessionTokens
        self.sessionCostUSD = sessionCostUSD
        self.historyDays = historyDays
        self.last30DaysTokens = last30DaysTokens
        self.last30DaysCostUSD = last30DaysCostUSD
        self.last30DaysAPIEquivalentCostUSD = last30DaysAPIEquivalentCostUSD
        self.meteredCostUSD = meteredCostUSD
        self.provenance = provenance
        self.daily = daily
        self.totals = totals
        self.error = error
    }
}

struct CostDailyEntryPayload: Encodable {
    let date: String
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let cacheCreationTokens: Int?
    let totalTokens: Int?
    let costUSD: Double?
    let apiEquivalentCostUSD: Double?
    let modelsUsed: [String]?
    let modelBreakdowns: [CostModelBreakdownPayload]?

    init(
        date: String,
        inputTokens: Int?,
        outputTokens: Int?,
        cacheReadTokens: Int?,
        cacheCreationTokens: Int?,
        totalTokens: Int?,
        costUSD: Double?,
        apiEquivalentCostUSD: Double? = nil,
        modelsUsed: [String]?,
        modelBreakdowns: [CostModelBreakdownPayload]?)
    {
        self.date = date
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.apiEquivalentCostUSD = apiEquivalentCostUSD
        self.modelsUsed = modelsUsed
        self.modelBreakdowns = modelBreakdowns
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case inputTokens
        case outputTokens
        case cacheReadTokens
        case cacheCreationTokens
        case totalTokens
        case costUSD = "totalCost"
        case apiEquivalentCostUSD
        case modelsUsed
        case modelBreakdowns
    }
}

struct CostModelBreakdownPayload: Encodable {
    let modelName: String
    let costUSD: Double?
    let totalTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case modelName
        case costUSD = "cost"
        case totalTokens
    }
}

struct CostTotalsPayload: Encodable {
    let totalInputTokens: Int?
    let totalOutputTokens: Int?
    let cacheReadTokens: Int?
    let cacheCreationTokens: Int?
    let totalTokens: Int?
    let totalCostUSD: Double?

    private enum CodingKeys: String, CodingKey {
        case totalInputTokens = "inputTokens"
        case totalOutputTokens = "outputTokens"
        case cacheReadTokens
        case cacheCreationTokens
        case totalTokens
        case totalCostUSD = "totalCost"
    }
}

// Intentionally empty.
