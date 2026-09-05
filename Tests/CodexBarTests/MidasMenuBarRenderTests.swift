import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MidasMenuBarRenderTests {
    private func presentation(
        _ title: String = "$42.80",
        refreshing: Bool = false,
        attention: Bool = false,
        stale: Bool = false,
        width: CGFloat = 132,
        orbitProvider: UsageProvider? = nil,
        remaining: Double? = nil) -> MidasMenuBarPresentation
    {
        MidasMenuBarPresentation(
            title: title,
            accessibilityLabel: "Midas, synthetic fixture",
            tooltip: "Synthetic fixture only",
            isRefreshing: refreshing,
            attention: attention,
            isStale: stale,
            width: width,
            orbitProvider: orbitProvider,
            orbitRemainingPercent: remaining)
    }

    private func host(width: CGFloat = 132) -> (NSWindow, MidasMenuBarView) {
        let frame = NSRect(x: 0, y: 0, width: width, height: 24)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = MidasMenuBarView(frame: frame)
        window.contentView = view
        return (window, view)
    }

    @Test func geometryReservesSeparateMarkReadingAndBadgeSlots() {
        let bounds = CGRect(x: 0, y: 0, width: 132, height: 24)
        let geometry = MidasMenuBarView.geometry(in: bounds)
        #expect(geometry.mark.width == 16)
        #expect(geometry.mark.maxX < geometry.title.minX)
        #expect(geometry.title.maxX < geometry.badge.minX)
        #expect(bounds.contains(geometry.mark))
        #expect(bounds.contains(geometry.title))
        #expect(bounds.contains(geometry.badge))
    }

    @Test func orbitKeepsAmountBeforeRingWithinNativeBar() {
        let bounds = CGRect(x: 0, y: 0, width: 110, height: 24)
        let geometry = MidasMenuBarView.geometry(in: bounds, orbit: true)
        #expect(geometry.title.maxX + MidasMenuBarLayout.readingGap == geometry.mark.minX)
        #expect(bounds.contains(geometry.mark))
        #expect(bounds.contains(geometry.title))
        #expect(geometry.mark.height == 18)
    }

    @Test func orbitRefreshRespectsReduceMotionAndWarning() {
        let (window, view) = self.host(width: 110)
        defer { window.close() }
        let active = self.presentation(refreshing: true, width: 110, orbitProvider: .codex, remaining: 72)
        view.update(presentation: active, reduceMotion: false)
        #expect(view.isRefreshAnimating)
        view.update(presentation: active, reduceMotion: true)
        #expect(!view.isRefreshAnimating)
        view.update(presentation: self.presentation(
            attention: true,
            width: 110,
            orbitProvider: .codex,
            remaining: 8), reduceMotion: false)
        #expect(!view.isRefreshAnimating)
    }

    @Test func adornmentNeverInterceptsNativeStatusButtonInteraction() {
        let view = MidasMenuBarView(frame: NSRect(x: 0, y: 0, width: 132, height: 24))
        #expect(view.hitTest(NSPoint(x: 12, y: 12)) == nil)
        #expect(!view.acceptsFirstResponder)
    }

    @Test func initialAndUnchangedReadingsStayStill() {
        let (window, view) = self.host()
        defer { window.close() }
        view.update(presentation: self.presentation(), reduceMotion: false)
        #expect(!view.isReadingAnimating)
        #expect(!view.isRefreshAnimating)
        view.update(presentation: self.presentation(), reduceMotion: false)
        #expect(!view.isReadingAnimating)
        view.update(presentation: self.presentation("$43.20"), reduceMotion: false)
        // Offscreen Core Animation may discard completed transitions before this assertion runs.
        #expect(view.readingTransitionCount == 1)
    }

    @Test func refreshAnimationStopsForReducedMotionAndRemoval() {
        let (window, view) = self.host()
        defer { window.close() }
        view.update(presentation: self.presentation(refreshing: true), reduceMotion: false)
        #expect(view.isRefreshAnimating)
        view.update(presentation: self.presentation("$43.20", refreshing: true), reduceMotion: true)
        #expect(!view.isRefreshAnimating)
        #expect(!view.isReadingAnimating)
        view.update(presentation: self.presentation(), reduceMotion: false)
        view.update(presentation: self.presentation(refreshing: true), reduceMotion: false)
        #expect(view.isRefreshAnimating)
        view.removeFromSuperview()
        #expect(!view.isRefreshAnimating)
    }

    @Test func warningWinsOverRefreshMotion() {
        let (window, view) = self.host()
        defer { window.close() }
        view.update(presentation: self.presentation(refreshing: true, attention: true), reduceMotion: false)
        #expect(!view.isRefreshAnimating)
    }

    /// Native offscreen fixtures; no status bar items, stores, probes, or real account values.
    @Test func exportFixturesWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["MIDAS_MENUBAR_PREVIEW_OUTPUT"] else { return }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let fixtures = [
            ("orbit-compact", self.presentation(
                "$13.9k",
                width: MidasMenuBarLayout.width(title: "$13.9k", orbit: true),
                orbitProvider: .codex,
                remaining: 72)),
            ("orbit-compact-missing", self.presentation(
                "—",
                width: MidasMenuBarLayout.width(title: "—", orbit: true),
                orbitProvider: .codex)),
            ("orbit-compact-private", self.presentation(
                "••••",
                width: MidasMenuBarLayout.width(title: "••••", orbit: true),
                orbitProvider: .codex)),
            ("ledger-compact", self.presentation(
                "≈$42.80", width: MidasMenuBarLayout.width(title: "≈$42.80", orbit: false))),
            ("focus-compact", self.presentation(
                "C 72%", width: MidasMenuBarLayout.width(title: "C 72%", orbit: false))),
            ("constellation-compact", self.presentation(
                "C 72%  U 54%  M —", width: MidasMenuBarLayout.width(title: "C 72%  U 54%  M —", orbit: false))),
            ("orbit-codex", self.presentation("$13.9k", width: 110, orbitProvider: .codex, remaining: 72)),
            ("orbit-cursor", self.presentation("$13.9k", width: 110, orbitProvider: .cursor, remaining: 54)),
            ("orbit-meta-neutral", self.presentation("$13.9k", width: 110, orbitProvider: .meta)),
            ("orbit-exhausted", self.presentation(
                "$13.9k",
                attention: true,
                width: 110,
                orbitProvider: .codex,
                remaining: 0)),
            ("orbit-low", self.presentation(
                "$13.9k",
                attention: true,
                width: 110,
                orbitProvider: .codex,
                remaining: 8)),
            ("orbit-refresh", self.presentation(
                "$13.9k",
                refreshing: true,
                width: 110,
                orbitProvider: .codex,
                remaining: 72)),
            ("orbit-stale", self.presentation(
                "$13.9k",
                stale: true,
                width: 110,
                orbitProvider: .codex,
                remaining: 72)),
            ("orbit-private", self.presentation("••••", width: 110, orbitProvider: .codex, remaining: 72)),
            ("ready", self.presentation()),
            ("large", self.presentation("$12,345.67")),
            ("ledger-wide", self.presentation("$123k + €45k", width: 130)),
            ("focus", self.presentation("72% · 15%", width: 120)),
            ("constellation", self.presentation("CX 72% · CL 86% · CU 54%", width: 190)),
            ("loading", self.presentation(refreshing: true)),
            ("attention", self.presentation(attention: true)),
            ("stale", self.presentation(stale: true)),
            ("missing", self.presentation("—")),
        ]
        for (name, presentation) in fixtures {
            for dark in [false, true] {
                let (window, view) = self.host(width: presentation.width)
                defer { window.close() }
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.backgroundColor = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.94, alpha: 1)
                view.update(presentation: presentation, reduceMotion: true)
                view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                #expect(self.hasReadingPixels(
                    bitmap,
                    width: presentation.width,
                    orbit: presentation.orbitProvider != nil))
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: output)
                    .appendingPathComponent("midas-menubar-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private func hasReadingPixels(_ bitmap: NSBitmapImageRep, width: CGFloat, orbit: Bool) -> Bool {
        let scale = CGFloat(bitmap.pixelsWide) / width
        guard let background = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else { return false }
        let rect = MidasMenuBarView.geometry(in: CGRect(x: 0, y: 0, width: width, height: 24), orbit: orbit).title
        for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(color.alphaComponent - background.alphaComponent) > 0.2
                    || abs(color.redComponent - background.redComponent) > 0.2
                {
                    return true
                }
            }
        }
        return false
    }
}
