import Foundation

/// Scans local Muse session logs (`~/.local/share/muse/sessions/**/session.jsonl`)
/// for `model_completed` usage events and aggregates token totals.
///
/// Log shape (verified against `muse` 1.0.2 session logs):
/// each line is either a record (`payload_type: "runtime.session"`) or a
/// `retained_frame` whose `children[].record_json` holds a stringified record.
/// Usage lives at `payload.event == {"kind": "model_completed",
/// "usage": {"input_tokens": N, "output_tokens": N, "reasoning_tokens": N,
/// "cached_tokens": N, "cache_read_tokens": N}, "model": "muse-spark-…"}` with
/// the timestamp in the outer record's `recorded_at` (microseconds since epoch).
/// Cache hits are read from `cache_read_tokens` (falling back to `cached_tokens`).
public enum MuseSessionLogScanner: Sendable {
    static let maxFilesPerScan = 5000
    static let maxLineBytes = 16 * 1024 * 1024

    public static func defaultSessionsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/muse/sessions", isDirectory: true)
    }

    public static func defaultConfigURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/muse/settings.json", isDirectory: false)
    }

    /// Configured model from `~/.config/muse/settings.json` (e.g. `muse-spark-1.3-contributor`).
    public static func configuredModel(configURL: URL? = nil) -> String? {
        let url = configURL ?? self.defaultConfigURL()
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = json["model"] as? String
        else {
            return nil
        }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func loadSummary(
        sessionsRoot: URL? = nil,
        since: Date,
        until: Date,
        now: Date = Date()) -> MetaUsageSummary
    {
        let root = sessionsRoot ?? self.defaultSessionsRoot()
        let files = self.listSessionFiles(root: root, since: since)
        var responses: [MetaCompletedResponse] = []
        responses.reserveCapacity(1024)
        for fileURL in files {
            self.appendResponses(from: fileURL, into: &responses)
        }
        return self.summarize(responses: responses, since: since, until: until, now: now)
    }

    // MARK: - Parsing (pure, unit-tested)

    public static func _parseResponsesForTesting(fromLine line: String) -> [MetaCompletedResponse] {
        self.parseResponses(fromLine: line)
    }

    public static func _summarizeForTesting(
        responses: [MetaCompletedResponse],
        since: Date,
        until: Date,
        now: Date) -> MetaUsageSummary
    {
        self.summarize(responses: responses, since: since, until: until, now: now)
    }

    static func parseResponses(fromLine line: String) -> [MetaCompletedResponse] {
        guard !line.isEmpty, line.count <= self.maxLineBytes else { return [] }
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return []
        }
        if json["retained_frame"] != nil,
           let children = json["children"] as? [[String: Any]]
        {
            var out: [MetaCompletedResponse] = []
            for child in children {
                guard let recordJSON = child["record_json"] as? String else { continue }
                out.append(contentsOf: self.parseResponses(fromLine: recordJSON))
            }
            return out
        }
        if let response = self.parseRecord(json) {
            return [response]
        }
        return []
    }

    static func parseRecord(_ json: [String: Any]) -> MetaCompletedResponse? {
        guard (json["payload_type"] as? String) == "runtime.session",
              let payload = json["payload"] as? [String: Any],
              let event = payload["event"] as? [String: Any],
              (event["kind"] as? String) == "model_completed",
              let usageDict = event["usage"] as? [String: Any]
        else {
            return nil
        }
        // `muse` 1.0.x writes cache hits as `cache_read_tokens` (with
        // `cached_tokens` often 0), so take the max of the known keys.
        let cachedTokens = max(
            self.intValue(usageDict["cached_tokens"]),
            self.intValue(usageDict["cache_read_tokens"]),
            self.intValue(usageDict["cacheReadTokens"]))
        let usage = MetaTokenUsage(
            inputTokens: self.intValue(usageDict["input_tokens"]),
            outputTokens: self.intValue(usageDict["output_tokens"]),
            reasoningTokens: self.intValue(usageDict["reasoning_tokens"]),
            cachedTokens: cachedTokens,
            requests: 1)
        guard usage.totalTokens > 0 else { return nil }
        let model = (event["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let at = self.dateValue(json["recorded_at"]) ?? Date()
        return MetaCompletedResponse(
            at: at,
            model: model?.isEmpty == true ? nil : model,
            usage: usage)
    }

    // MARK: - Aggregation

    static func summarize(
        responses: [MetaCompletedResponse],
        since: Date,
        until: Date,
        now: Date,
        calendar: Calendar = Calendar.current) -> MetaUsageSummary
    {
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let startOfToday = calendar.startOfDay(for: now)
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday

        var today = MetaTokenUsage()
        var last7 = MetaTokenUsage()
        var last30 = MetaTokenUsage()
        var byDay: [String: (usage: MetaTokenUsage, models: Set<String>)] = [:]
        var sessions = 0
        var models: Set<String> = []

        let inRange = responses.filter { $0.at >= since && $0.at <= until }
        sessions = inRange.count
        for response in inRange {
            last30 += response.usage
            if response.at >= sevenDaysAgo {
                last7 += response.usage
            }
            if response.at >= startOfToday {
                today += response.usage
            }
            let key = dayFormatter.string(from: response.at)
            var entry = byDay[key] ?? (MetaTokenUsage(), Set<String>())
            entry.usage += response.usage
            if let model = response.model, !model.isEmpty {
                entry.models.insert(model)
                models.insert(model)
            }
            byDay[key] = entry
        }

        let daily = byDay.map { key, value in
            MetaDailyUsage(dayKey: key, usage: value.usage, modelsUsed: value.models.sorted())
        }.sorted { $0.dayKey < $1.dayKey }

        return MetaUsageSummary(
            today: today,
            last7Days: last7,
            last30Days: last30,
            sessionsWithData: sessions,
            modelsUsed: models.sorted(),
            daily: daily,
            updatedAt: now)
    }

    // MARK: - File IO

    /// Session-log files under `root` modified since `since` (minus a 1-hour grace window).
    public static func listSessionFiles(root: URL, since: Date) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])
        else {
            return []
        }
        var files: [URL] = []
        let cutoff = since.addingTimeInterval(-24 * 3600)
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "session.jsonl" else { continue }
            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let mtime = values.contentModificationDate,
               mtime < cutoff
            {
                continue
            }
            files.append(url)
            if files.count >= self.maxFilesPerScan {
                break
            }
        }
        return files
    }

    static func appendResponses(from fileURL: URL, into out: inout [MetaCompletedResponse]) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        // Split on newlines without copying the whole file into Strings twice.
        var start = data.startIndex
        while start < data.endIndex {
            var end = start
            while end < data.endIndex, data[end] != 0x0A {
                data.formIndex(after: &end)
            }
            if end > start, end - start <= self.maxLineBytes,
               let line = String(data: data[start..<end], encoding: .utf8)
            {
                out.append(contentsOf: self.parseResponses(fromLine: line))
            }
            if end < data.endIndex {
                data.formIndex(after: &end)
            }
            start = end
        }
    }

    // MARK: - Helpers

    static func intValue(_ raw: Any?) -> Int {
        if let value = raw as? Int { return max(0, value) }
        if let value = raw as? Int64 { return max(0, Int(value)) }
        if let value = raw as? Double, value.isFinite { return max(0, Int(value)) }
        if let value = raw as? NSNumber { return max(0, value.intValue) }
        return 0
    }

    /// `recorded_at` is microseconds since epoch in current `muse` logs.
    static func dateValue(_ raw: Any?) -> Date? {
        if let micros = raw as? Int {
            return Date(timeIntervalSince1970: Double(micros) / 1_000_000)
        }
        if let micros = raw as? Int64 {
            return Date(timeIntervalSince1970: Double(micros) / 1_000_000)
        }
        if let micros = raw as? Double, micros.isFinite {
            // Heuristic: values above 1e12 are micros; above 1e10 are millis.
            if micros > 1e14 {
                return Date(timeIntervalSince1970: micros / 1_000_000)
            } else if micros > 1e11 {
                return Date(timeIntervalSince1970: micros / 1000)
            }
            return Date(timeIntervalSince1970: micros)
        }
        if let number = raw as? NSNumber {
            return self.dateValue(number.doubleValue)
        }
        return nil
    }
}
