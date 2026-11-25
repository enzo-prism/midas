import Foundation

public struct GeminiTranscriptStep: Sendable, Equatable {
    public let timestamp: Date
    public let model: String
    public let inputTokens: Int
    public let cacheReadTokens: Int
    public let outputTokens: Int

    public var totalTokens: Int {
        self.inputTokens + self.cacheReadTokens + self.outputTokens
    }
}

/// Scans Antigravity local agent transcripts (`~/.gemini/antigravity/brain/*/.system_generated/logs/transcript.jsonl`)
/// for Gemini `PLANNER_RESPONSE` token usage and estimates API-equivalent value using public Google Gemini rates.
public enum GeminiTranscriptLogScanner: Sendable {
    static let maxFilesPerScan = 5000
    static let maxLineBytes = 16 * 1024 * 1024

    public static func defaultBrainRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity", isDirectory: true)
            .appendingPathComponent("brain", isDirectory: true)
    }

    public static func defaultBrainRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let geminiRoot = home.appendingPathComponent(".gemini", isDirectory: true)
        return [
            geminiRoot
                .appendingPathComponent("antigravity", isDirectory: true)
                .appendingPathComponent("brain", isDirectory: true),
            geminiRoot
                .appendingPathComponent("antigravity-cli", isDirectory: true)
                .appendingPathComponent("brain", isDirectory: true),
        ]
    }

    public static func loadTokenSnapshot(
        brainRoot: URL? = nil,
        since: Date,
        until: Date,
        now: Date = Date(),
        historyDays: Int = 30,
        pricingCacheRoot: URL? = nil,
        calendar: Calendar = .current) -> CostUsageTokenSnapshot
    {
        let roots = brainRoot.map { [$0] } ?? self.defaultBrainRoots()
        var files: [URL] = []
        var seenPaths = Set<String>()
        for root in roots {
            for fileURL in self.listTranscriptFiles(root: root, since: since) {
                let path = fileURL.standardizedFileURL.path
                guard seenPaths.insert(path).inserted else { continue }
                files.append(fileURL)
                if files.count >= self.maxFilesPerScan { break }
            }
            if files.count >= self.maxFilesPerScan { break }
        }
        var steps: [GeminiTranscriptStep] = []
        steps.reserveCapacity(512)
        for fileURL in files {
            autoreleasepool {
                self.appendSteps(from: fileURL, into: &steps)
            }
        }
        return self.buildTokenSnapshot(
            steps: steps,
            window: SnapshotWindow(
                since: since,
                until: until,
                now: now,
                historyDays: historyDays,
                pricingCacheRoot: pricingCacheRoot,
                calendar: calendar))
    }

    public static func _parseStepForTesting(fromLine line: String) -> GeminiTranscriptStep? {
        guard let data = line.data(using: .utf8) else { return nil }
        return self.parseStep(from: data)
    }

    public static func _buildTokenSnapshotForTesting(
        steps: [GeminiTranscriptStep],
        since: Date,
        until: Date,
        now: Date,
        historyDays: Int,
        pricingCacheRoot: URL? = nil,
        calendar: Calendar = .current) -> CostUsageTokenSnapshot
    {
        self.buildTokenSnapshot(
            steps: steps,
            window: SnapshotWindow(
                since: since,
                until: until,
                now: now,
                historyDays: historyDays,
                pricingCacheRoot: pricingCacheRoot,
                calendar: calendar))
    }

    /// Strips effort and tiering suffixes appended by agent runtimes (e.g. `-high`, `-xhigh`,
    /// `-medium`, `-low`, `-minimal`, `-tiered`) to match public model identifiers.
    public static func normalizeModelIDForPricing(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let slash = value.lastIndex(of: "/") {
            value = String(value[value.index(after: slash)...])
        }
        let suffixes = ["-xhigh", "-high", "-medium", "-low", "-minimal", "-tiered", "-thinking", "-max"]
        var changed = true
        while changed {
            changed = false
            for suffix in suffixes where value.hasSuffix(suffix) {
                value = String(value.dropLast(suffix.count))
                changed = true
            }
        }
        return value
    }

    private struct SnapshotWindow {
        let since: Date
        let until: Date
        let now: Date
        let historyDays: Int
        let pricingCacheRoot: URL?
        let calendar: Calendar
    }

    private struct DayAccumulator {
        var inputTokens = 0
        var cacheReadTokens = 0
        var outputTokens = 0
        var requestCount = 0
        var pricedCostUSD = 0.0
        var hasPricedStep = false
        var unpricedRequests = 0
        var models: [String: ModelAccumulator] = [:]
    }

    private struct ModelAccumulator {
        var inputTokens = 0
        var cacheReadTokens = 0
        var outputTokens = 0
        var requestCount = 0
        var pricedCostUSD = 0.0
        var hasPricedStep = false
    }

    private static func buildTokenSnapshot(
        steps: [GeminiTranscriptStep],
        window: SnapshotWindow) -> CostUsageTokenSnapshot
    {
        let calendar = window.calendar
        let startDay = calendar.startOfDay(for: window.since)
        let endOfUntilDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: window.until))
            ?? window.until
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let todayKey = dayFormatter.string(from: window.now)

        var days: [String: DayAccumulator] = [:]
        for step in steps {
            guard step.timestamp >= startDay, step.timestamp < endOfUntilDay else { continue }
            let dayKey = dayFormatter.string(from: step.timestamp)
            let normalizedModel = Self.normalizeModelIDForPricing(step.model)
            let stepCost = CostUsagePricing.geminiCostUSD(
                model: normalizedModel,
                inputTokens: step.inputTokens,
                cacheReadTokens: step.cacheReadTokens,
                outputTokens: step.outputTokens,
                cacheRoot: window.pricingCacheRoot)

            var day = days[dayKey] ?? DayAccumulator()
            day.inputTokens += step.inputTokens
            day.cacheReadTokens += step.cacheReadTokens
            day.outputTokens += step.outputTokens
            day.requestCount += 1
            if let stepCost {
                day.pricedCostUSD += stepCost
                day.hasPricedStep = true
            } else {
                day.unpricedRequests += 1
            }

            var modelAcc = day.models[normalizedModel] ?? ModelAccumulator()
            modelAcc.inputTokens += step.inputTokens
            modelAcc.cacheReadTokens += step.cacheReadTokens
            modelAcc.outputTokens += step.outputTokens
            modelAcc.requestCount += 1
            if let stepCost {
                modelAcc.pricedCostUSD += stepCost
                modelAcc.hasPricedStep = true
            }
            day.models[normalizedModel] = modelAcc
            days[dayKey] = day
        }

        let dailyEntries: [CostUsageDailyReport.Entry] = days.keys.sorted().map { dateKey in
            let day = days[dateKey]!
            let totalTokens = day.inputTokens + day.cacheReadTokens + day.outputTokens
            let modelNames = day.models.keys.sorted()
            let breakdowns = modelNames.map { modelName -> CostUsageDailyReport.ModelBreakdown in
                let acc = day.models[modelName]!
                return CostUsageDailyReport.ModelBreakdown(
                    modelName: modelName,
                    costUSD: acc.hasPricedStep ? acc.pricedCostUSD : nil,
                    totalTokens: acc.inputTokens + acc.cacheReadTokens + acc.outputTokens,
                    requestCount: acc.requestCount,
                    inputTokens: acc.inputTokens,
                    outputTokens: acc.outputTokens,
                    cacheReadTokens: acc.cacheReadTokens)
            }
            return CostUsageDailyReport.Entry(
                date: dateKey,
                inputTokens: day.inputTokens,
                outputTokens: day.outputTokens,
                cacheReadTokens: day.cacheReadTokens,
                cacheCreationTokens: nil,
                reasoningTokens: nil,
                totalTokens: totalTokens,
                requestCount: day.requestCount,
                costUSD: day.hasPricedStep ? day.pricedCostUSD : nil,
                apiEquivalentCostUSD: nil,
                modelsUsed: modelNames.isEmpty ? nil : modelNames,
                modelBreakdowns: breakdowns.isEmpty ? nil : breakdowns,
                unpricedRequestCount: day.unpricedRequests > 0 ? day.unpricedRequests : nil,
                estimatedRequestCount: day.hasPricedStep ? (day.requestCount - day.unpricedRequests) : nil)
        }

        let todayEntry = dailyEntries.first { $0.date == todayKey }
        let totalTokens = dailyEntries.reduce(0) { $0 + ($1.totalTokens ?? 0) }
        let pricedEntries = dailyEntries.compactMap(\.costUSD)
        let totalCostUSD: Double? = pricedEntries.isEmpty ? nil : pricedEntries.reduce(0, +)

        return CostUsageTokenSnapshot(
            sessionTokens: todayEntry?.totalTokens,
            sessionCostUSD: todayEntry?.costUSD,
            last30DaysTokens: dailyEntries.isEmpty ? nil : totalTokens,
            last30DaysCostUSD: totalCostUSD,
            historyDays: window.historyDays,
            costProvenance: totalCostUSD != nil ? .listPriceEstimate : .unknown,
            daily: dailyEntries,
            updatedAt: window.now)
    }

    private static func listTranscriptFiles(root: URL, since: Date) -> [URL] {
        let fm = FileManager.default
        guard let conversations = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else {
            return []
        }

        let cutoff = since.addingTimeInterval(-48 * 3600)
        var results: [URL] = []
        for convoDir in conversations {
            let transcriptURL = convoDir
                .appendingPathComponent(".system_generated", isDirectory: true)
                .appendingPathComponent("logs", isDirectory: true)
                .appendingPathComponent("transcript.jsonl", isDirectory: false)
            guard fm.fileExists(atPath: transcriptURL.path) else { continue }
            if let values = try? transcriptURL.resourceValues(forKeys: [.contentModificationDateKey]),
               let modified = values.contentModificationDate,
               modified < cutoff
            {
                continue
            }
            results.append(transcriptURL)
            if results.count >= self.maxFilesPerScan { break }
        }
        return results
    }

    private static func appendSteps(from fileURL: URL, into steps: inout [GeminiTranscriptStep]) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }

        let chunkSize = 64 * 1024
        var buffer = Data()
        var skippingOversizedLine = false
        let newline = UInt8(ascii: "\n")

        while true {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nlIndex = buffer.firstIndex(of: newline) {
                let lineData = buffer[..<nlIndex]
                if !skippingOversizedLine, !lineData.isEmpty, lineData.count <= self.maxLineBytes,
                   let step = Self.parseStep(from: Data(lineData))
                {
                    steps.append(step)
                }
                buffer.removeSubrange(...nlIndex)
                skippingOversizedLine = false
            }
            if buffer.count > self.maxLineBytes {
                buffer.removeAll(keepingCapacity: true)
                skippingOversizedLine = true
            }
        }
        if !skippingOversizedLine, !buffer.isEmpty, buffer.count <= self.maxLineBytes,
           let step = Self.parseStep(from: buffer)
        {
            steps.append(step)
        }
    }

    private static func parseStep(from data: Data) -> GeminiTranscriptStep? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard (json["type"] as? String) == "PLANNER_RESPONSE",
              let rawModel = json["model"] as? String
        else {
            return nil
        }
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.lowercased().hasPrefix("gemini") else {
            return nil
        }
        guard let createdAt = json["created_at"] as? String,
              let timestamp = Self.parseISO8601(createdAt)
        else {
            return nil
        }

        let inputTokens = Self.nonNegativeInt(json["input_tokens"])
        let cacheReadTokens = Self.nonNegativeInt(json["cache_read_tokens"])
        let outputTokens = Self.nonNegativeInt(json["output_tokens"])
        guard inputTokens + cacheReadTokens + outputTokens > 0 else {
            return nil
        }

        return GeminiTranscriptStep(
            timestamp: timestamp,
            model: model,
            inputTokens: inputTokens,
            cacheReadTokens: cacheReadTokens,
            outputTokens: outputTokens)
    }

    private static func nonNegativeInt(_ value: Any?) -> Int {
        if let intVal = value as? Int { return max(0, intVal) }
        if let numVal = value as? NSNumber { return max(0, numVal.intValue) }
        return 0
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
