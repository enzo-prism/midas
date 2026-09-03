import Foundation
import Testing
@testable import CodexBarCore

struct ZaiCostUsageFetcherTests {
    /// Empty temp dir so aggregation tests price with the deterministic built-in GLM rates
    /// instead of the host's cached models.dev catalog.
    private static func emptyCacheRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-zai-cost-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test
    func `dateChunks splits range into week long windows`() throws {
        let calendar = Calendar.current
        let from = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 0)))
        let to = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 20, hour: 0)))

        let chunks = ZaiCostUsageFetcher.dateChunks(from: from, to: to, daySpan: 7)

        // 20 days / 7-day span → 3 chunks (7 + 7 + 6).
        #expect(chunks.count == 3)
        #expect(chunks.first?.start == from)
        #expect(chunks.last?.end == to)
        // Non-overlapping and contiguous.
        for index in 1..<chunks.count {
            #expect(chunks[index].start == chunks[index - 1].end)
        }
    }

    @Test
    func `dateChunks returns empty for inverted range`() {
        let now = Date()
        #expect(ZaiCostUsageFetcher.dateChunks(from: now, to: now.addingTimeInterval(-1), daySpan: 7).isEmpty)
    }

    @Test
    func `buildDailyReport aggregates hourly buckets into priced daily entries`() throws {
        let cacheRoot = try Self.emptyCacheRoot()
        // Two hours on 2026-01-10, two models.
        let modelUsage = ZaiModelUsageData(
            xTime: ["2026-01-10 09:00", "2026-01-10 10:00"],
            modelDataList: [
                ZaiModelDataItem(modelName: "glm-4.6", tokensUsage: [500_000, 500_000]),
                ZaiModelDataItem(modelName: "glm-4-flash", tokensUsage: [100_000, nil]),
            ])

        let report = ZaiCostUsageFetcher.buildDailyReport(from: [modelUsage], modelsDevCacheRoot: cacheRoot)

        #expect(report.data.count == 1)
        let day = report.data[0]
        #expect(day.date == "2026-01-10")
        // glm-4.6: 1,000,000 tokens × 1.0e-6 = $1.0; glm-4-flash: free → $0.
        #expect(day.totalTokens == 1_100_000)
        #expect(day.costUSD == 1.0)
        #expect(day.modelsUsed == ["glm-4-flash", "glm-4.6"])
        // Breakdowns sorted by cost descending → glm-4.6 first.
        #expect(day.modelBreakdowns?.first?.modelName == "glm-4.6")
        #expect(day.modelBreakdowns?.first?.costUSD == 1.0)
        #expect(day.modelBreakdowns?.last?.modelName == "glm-4-flash")
        #expect(day.modelBreakdowns?.last?.costUSD == 0)
        #expect(report.summary?.totalTokens == 1_100_000)
        #expect(report.summary?.totalCostUSD == 1.0)
    }

    @Test
    func `buildDailyReport merges same day across multiple model usage payloads`() throws {
        let cacheRoot = try Self.emptyCacheRoot()
        let a = ZaiModelUsageData(
            xTime: ["2026-01-10 09:00"],
            modelDataList: [ZaiModelDataItem(modelName: "glm-4.6", tokensUsage: [300_000])])
        let b = ZaiModelUsageData(
            xTime: ["2026-01-10 10:00"],
            modelDataList: [ZaiModelDataItem(modelName: "glm-4.6", tokensUsage: [700_000])])

        let report = ZaiCostUsageFetcher.buildDailyReport(from: [a, b], modelsDevCacheRoot: cacheRoot)

        #expect(report.data.count == 1)
        #expect(report.data[0].totalTokens == 1_000_000)
        #expect(report.data[0].costUSD == 1.0)
    }

    @Test
    func `buildDailyReport spans multiple sorted days`() throws {
        let cacheRoot = try Self.emptyCacheRoot()
        let modelUsage = ZaiModelUsageData(
            xTime: ["2026-01-11 09:00", "2026-01-10 09:00"],
            modelDataList: [ZaiModelDataItem(modelName: "glm-4.6", tokensUsage: [200_000, 800_000])])

        let report = ZaiCostUsageFetcher.buildDailyReport(from: [modelUsage], modelsDevCacheRoot: cacheRoot)

        #expect(report.data.count == 2)
        #expect(report.data.map(\.date) == ["2026-01-10", "2026-01-11"])
        #expect(report.data[0].totalTokens == 800_000)
        #expect(report.data[1].totalTokens == 200_000)
    }

    @Test
    func `buildDailyReport ignores unpriced models in cost but keeps tokens`() throws {
        let cacheRoot = try Self.emptyCacheRoot()
        let modelUsage = ZaiModelUsageData(
            xTime: ["2026-01-10 09:00"],
            modelDataList: [
                ZaiModelDataItem(modelName: "glm-4.6", tokensUsage: [1_000_000]),
                ZaiModelDataItem(modelName: "unreleased-glm-x", tokensUsage: [9_000_000]),
            ])

        let report = ZaiCostUsageFetcher.buildDailyReport(from: [modelUsage], modelsDevCacheRoot: cacheRoot)

        let day = report.data[0]
        #expect(day.totalTokens == 10_000_000)
        // Only glm-4.6 contributes dollars; the unknown model is excluded from cost.
        #expect(day.costUSD == 1.0)
        #expect(report.summary?.totalCostUSD == 1.0)
    }

    @Test
    func `buildDailyReport handles empty input`() {
        let report = ZaiCostUsageFetcher.buildDailyReport(from: [])
        #expect(report.data.isEmpty)
        #expect(report.summary?.totalTokens == 0)
        #expect(report.summary?.totalCostUSD == 0)
    }
}
