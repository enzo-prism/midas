import Foundation

// MARK: - Model-scoped weekly limits ("Current week (Fable)")

extension ClaudeStatusProbe {
    struct ScopedWeeklyUsage {
        let modelName: String
        let percentLeft: Int
        let resetDescription: String?
    }

    static func extractScopedWeeklyUsages(context: LabelSearchContext) -> [ScopedWeeklyUsage] {
        guard let regex = try? NSRegularExpression(
            pattern: #"current\s+week\s*\(([^)]+)\)"#,
            options: [.caseInsensitive])
        else { return [] }

        var seenModels: Set<String> = []
        var usages: [ScopedWeeklyUsage] = []
        for (index, line) in context.lines.enumerated() {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, options: [], range: range),
                  match.numberOfRanges >= 2,
                  let modelRange = Range(match.range(at: 1), in: line)
            else { continue }

            let modelName = String(line[modelRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedModel = self.normalizedForLabelSearch(modelName)
            guard !normalizedModel.isEmpty, !self.isAllModelsWeeklyModel(normalizedModel) else { continue }
            guard seenModels.insert(normalizedModel).inserted else { continue }

            let window = context.lines.dropFirst(index).prefix(14)
            var percentLeft: Int?
            var resetDescription: String?
            for candidate in window {
                let normalized = self.normalizedForLabelSearch(candidate)
                if normalized.hasPrefix("currentweek"), !normalized.contains(normalizedModel) { break }
                if percentLeft == nil {
                    percentLeft = self.percentFromLine(candidate)
                }
                if resetDescription == nil {
                    resetDescription = self.resetFromLine(candidate)
                }
            }
            guard let percentLeft else { continue }
            usages.append(ScopedWeeklyUsage(
                modelName: modelName,
                percentLeft: percentLeft,
                resetDescription: resetDescription))
        }
        return usages
    }

    static func extraRateWindows(
        fromScopedWeeklyUsages usages: [ScopedWeeklyUsage],
        fallbackResetDescription: String?) -> [NamedRateWindow]
    {
        usages.compactMap { usage in
            let normalizedModel = self.normalizedForLabelSearch(usage.modelName)
            guard normalizedModel != "opus",
                  normalizedModel != "sonnet",
                  normalizedModel != "sonnetonly"
            else { return nil }

            let usedPercent = max(0, min(100, 100 - Double(usage.percentLeft)))
            let modelTitle = normalizedModel.hasSuffix("only")
                ? usage.modelName
                : "\(usage.modelName) only"
            let resetDescription = usage.resetDescription ?? fallbackResetDescription
            return NamedRateWindow(
                id: "claude-weekly-scoped-\(self.slug(usage.modelName))",
                title: modelTitle,
                window: RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: self.parseResetDate(from: resetDescription),
                    resetDescription: resetDescription))
        }
    }

    /// Recognizes the "all models" weekly bucket even when the TUI capture dropped or duplicated a
    /// character (e.g. "all modls"). Claude redraws `/usage`, so the same line can be captured
    /// mid-repaint; without tolerance a garbled copy would surface as a bogus "all modls only" bar.
    /// Genuine model-scoped names (Opus, Sonnet, Fable, …) are far outside this edit distance.
    private static func isAllModelsWeeklyModel(_ normalizedModel: String) -> Bool {
        normalizedModel == "allmodels" || self.editDistance(normalizedModel, "allmodels") <= 2
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs.unicodeScalars)
        let b = Array(rhs.unicodeScalars)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previousDiagonal = row[0]
            row[0] = i
            for j in 1...b.count {
                let substitution = previousDiagonal + (a[i - 1] == b[j - 1] ? 0 : 1)
                previousDiagonal = row[j]
                row[j] = Swift.min(row[j] + 1, row[j - 1] + 1, substitution)
            }
        }
        return row[b.count]
    }

    private static func slug(_ value: String) -> String {
        var result = ""
        var lastWasDash = false
        for scalar in value.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
