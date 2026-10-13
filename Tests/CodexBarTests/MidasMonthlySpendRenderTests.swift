import AppKit
import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct MidasMonthlySpendRenderTests {
    /// Render the actual native view with synthetic data and no live stores or credential access.
    @Test @MainActor func exportMonthlyChartsWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["MIDAS_MONTHLY_PREVIEW_OUTPUT"] else { return }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-12T12:00:00Z"))
        var rows: [CostUsageDailyReport.Entry] = []
        for month in 1...10 {
            let lastDay = month == 10 ? 12 : 28
            for day in 1...lastDay {
                let date = String(format: "2026-%02d-%02d", month, day)
                let tokens = 100_000 + month * 10000
                let cost = Double(month * 2 + day) / 10
                rows.append(CostUsageDailyReport.Entry(
                    date: date,
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: tokens,
                    costUSD: cost,
                    modelsUsed: nil,
                    modelBreakdowns: nil))
            }
        }
        let cases = [
            ("costs-six-months", rows, true, 6, 500.0),
            ("tokens-twelve-months", rows, false, 12, 500.0),
            ("costs-twelve-months-wide", rows, true, 12, 816.0),
            ("gaps", rows.filter { !$0.date.hasPrefix("2026-08") }, true, 6, 500.0),
            ("unavailable", [], true, 6, 500.0),
        ]
        for (name, entries, costs, months, width) in cases {
            let snapshot = CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: nil,
                last30DaysCostUSD: nil,
                historyDays: 365,
                costProvenance: .listPriceEstimate,
                daily: entries,
                updatedAt: now)
            let model = MidasMonthlySpend(snapshot: snapshot, monthCount: months, now: now)
            for scheme in [ColorScheme.light, .dark] {
                let view = MidasMonthlySpendView(
                    model: model,
                    showsCosts: .constant(costs),
                    monthCount: .constant(months))
                    .padding(24)
                    .frame(width: width, alignment: .topLeading)
                    .foregroundStyle(MidasTheme.text)
                    .tint(MidasTheme.accent)
                    .background(MidasTheme.background)
                    .environment(\.colorScheme, scheme)
                let hosting = NSHostingView(rootView: view.frame(height: 680, alignment: .topLeading)
                    .background(MidasTheme.background))
                let size = NSSize(width: width, height: 680)
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
                #expect(bitmap.pixelsWide >= Int(width))
                #expect(bitmap.pixelsHigh > 500)
                let filename = "midas-monthly-\(name)-\(scheme == .dark ? "dark" : "light").png"
                let destination = URL(fileURLWithPath: output).appendingPathComponent(filename)
                try png.write(to: destination, options: .withoutOverwriting)
            }
        }
    }
}
