import AppKit
import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct MidasDGXSparkRenderTests {
    /// Native render fixtures use synthetic measurements and never inspect live accounts or credentials.
    @Test @MainActor func exportLocalInferenceSurfacesWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["MIDAS_SPARK_RENDER_OUTPUT"] else { return }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let now = Date()
        let day = MidasUsageSyncPublication.day(now)
        let row = CostUsageDailyReport.Entry(
            date: day,
            inputTokens: 12_000_000,
            outputTokens: 400_000,
            cacheReadTokens: 9_000_000,
            totalTokens: 12_400_000,
            costUSD: nil,
            modelsUsed: [DGXSparkPricing.modelID],
            modelBreakdowns: [.init(
                modelName: DGXSparkPricing.modelID,
                costUSD: nil,
                totalTokens: 12_400_000,
                inputTokens: 12_000_000,
                outputTokens: 400_000,
                cacheReadTokens: 9_000_000)])
        let snapshot = DGXSparkPricing.project(
            snapshot: .init(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: 12_400_000,
                last30DaysCostUSD: nil,
                daily: [row],
                updatedAt: now),
            now: now)
        let priced = MidasDGXSparkPresentation.make(snapshot: snapshot, now: now)
        #expect(priced.tokens == 12_400_000)
        #expect(try abs(#require(priced.amount) - 1.25) < 0.000001)
        let actions = MidasActions(
            refresh: {}, settings: {}, accounts: { _ in }, openUsage: { _ in }, legacyMenu: {}, quit: {})
        let partial = self.partialPricingModel(day: day, now: now)
        #expect(partial.tokens == 1_400_000)
        #expect(partial.pricedTokens == 83000)
        for scheme in [ColorScheme.light, .dark] {
            try self.export(
                MidasDGXSparkCard(model: priced, showsNavigation: true),
                name: "card",
                size: NSSize(width: 352, height: 440),
                scheme: scheme,
                output: output)
            try self.export(
                MidasDGXSparkDetailView(model: priced, actions: actions),
                name: "detail",
                size: NSSize(width: 400, height: 1000),
                scheme: scheme,
                output: output)
            try self.export(
                MidasDGXSparkCard(model: .make(snapshot: nil, now: now)),
                name: "waiting",
                size: NSSize(width: 290, height: 440),
                scheme: scheme,
                output: output)
            let unknown = CostUsageDailyReport.Entry(
                date: day,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: 8,
                costUSD: nil,
                modelsUsed: ["local-runtime"],
                modelBreakdowns: nil)
            let unknownModel = MidasDGXSparkPresentation.make(
                snapshot: .init(
                    sessionTokens: nil,
                    sessionCostUSD: nil,
                    last30DaysTokens: 8,
                    last30DaysCostUSD: nil,
                    daily: [unknown],
                    updatedAt: now.addingTimeInterval(-3600)),
                now: now)
            try self.export(
                MidasDGXSparkCard(model: unknownModel),
                name: "unpriced-stale",
                size: NSSize(width: 290, height: 440),
                scheme: scheme,
                output: output)
            try self.export(
                MidasDGXSparkCard(model: partial),
                name: "partial-pricing",
                size: NSSize(width: 352, height: 480),
                scheme: scheme,
                output: output)
        }
    }

    private func partialPricingModel(day: String, now: Date) -> MidasDGXSparkPresentation {
        let row = CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 1_400_000,
            costUSD: nil,
            modelsUsed: [DGXSparkPricing.modelID, "local-runtime"],
            modelBreakdowns: [
                .init(
                    modelName: DGXSparkPricing.modelID,
                    costUSD: nil,
                    totalTokens: 83000,
                    inputTokens: 80000,
                    outputTokens: 3000,
                    cacheReadTokens: 60000),
                .init(modelName: "local-runtime", costUSD: nil, totalTokens: 1_317_000),
            ])
        let snapshot = DGXSparkPricing.project(
            snapshot: .init(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: 1_400_000,
                last30DaysCostUSD: nil,
                daily: [row],
                updatedAt: now),
            now: now)
        return .make(snapshot: snapshot, now: now)
    }

    @MainActor private func export(
        _ content: some View,
        name: String,
        size: NSSize,
        scheme: ColorScheme,
        output: String) throws
    {
        let view = VStack(alignment: .leading, spacing: 16) {
            Text("Midas · Sample data").font(.caption).foregroundStyle(MidasTheme.secondaryText)
            content
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .foregroundStyle(MidasTheme.text)
        .background(MidasTheme.background)
        .environment(\.colorScheme, scheme)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let filename = "midas-dgx-spark-\(name)-\(scheme == .dark ? "dark" : "light").png"
        try png.write(to: URL(fileURLWithPath: output).appendingPathComponent(filename), options: .withoutOverwriting)
        #expect(bitmap.pixelsWide >= Int(size.width))
    }
}
