import AppKit

/// Shared measurement and drawing metrics. Text keeps its native menu-bar size instead of shrinking to fit a preset.
enum MidasMenuBarLayout {
    static let horizontalInset: CGFloat = 6
    static let readingGap: CGFloat = 5
    static let markWidth: CGFloat = 16
    static let orbitWidth: CGFloat = 18
    static let badgeWidth: CGFloat = 12
    static let badgeGap: CGFloat = 4

    static var font: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    }

    static func readingWidth(_ title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: self.font]).width)
    }

    static func width(title: String, orbit: Bool) -> CGFloat {
        let adornments = orbit ? self.orbitWidth : self.markWidth + self.badgeGap + self.badgeWidth
        // Keep a bounded footprint even for pathological values.
        // The full reading remains in accessibility text and the panel.
        return min(220, max(24, self.horizontalInset * 2 + self.readingGap + adornments + self.readingWidth(title)))
    }

    /// Fallback raster scale when no screen is available (headless tests, early launch).
    static let fallbackRenderScale: CGFloat = 2

    /// Raster scale for the caller's status item. Pass the status button (or its window) so the
    /// icon bitmap matches the screen the menu bar is drawn on. Falls back to 2.0 without a screen.
    /// Call on the main thread; AppKit window/screen state is main-thread only.
    static func renderScale(for view: NSView?) -> CGFloat {
        self.renderScale(for: view?.window)
    }

    /// Raster scale for a status item window. See ``renderScale(for:)``.
    static func renderScale(for window: NSWindow?) -> CGFloat {
        guard let scale = window?.screen?.backingScaleFactor, scale.isFinite, scale > 0 else {
            return self.fallbackRenderScale
        }
        return self.clampedRenderScale(scale)
    }

    /// Best-effort raster scale for menu-bar icons when the caller has no button reference.
    /// Prefers an actual status-bar window's screen, then the main screen, then 2.0.
    /// Safe from any thread: off the main thread it returns the last main-thread value (initially 2.0).
    static var currentMenuBarRenderScale: CGFloat {
        if Thread.isMainThread {
            let resolved = self.resolveLiveMenuBarRenderScale()
            self.renderScaleCache.store(resolved)
            return resolved
        }
        return self.renderScaleCache.load()
    }

    /// Explicit override when non-nil (normalized), otherwise ``currentMenuBarRenderScale``.
    static func resolvedRenderScale(_ override: CGFloat?) -> CGFloat {
        guard let override else { return self.currentMenuBarRenderScale }
        guard override.isFinite, override > 0 else { return self.fallbackRenderScale }
        return self.clampedRenderScale(override)
    }

    private static func clampedRenderScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, 1), 3)
    }

    private static func resolveLiveMenuBarRenderScale() -> CGFloat {
        let statusBarScales = (NSApp?.windows ?? []).compactMap { window -> CGFloat? in
            guard NSStringFromClass(type(of: window)).contains("StatusBar") else { return nil }
            guard let scale = window.screen?.backingScaleFactor, scale.isFinite, scale > 0 else { return nil }
            return scale
        }
        if let scale = statusBarScales.max() {
            return self.clampedRenderScale(scale)
        }
        if let main = NSScreen.main?.backingScaleFactor, main.isFinite, main > 0 {
            return self.clampedRenderScale(main)
        }
        return self.fallbackRenderScale
    }

    private static let renderScaleCache = MenuBarRenderScaleCache()

    private final class MenuBarRenderScaleCache: @unchecked Sendable {
        private var value: CGFloat = MidasMenuBarLayout.fallbackRenderScale
        private let lock = NSLock()

        func load() -> CGFloat {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.value
        }

        func store(_ value: CGFloat) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.value = value
        }
    }
}
