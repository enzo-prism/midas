import AppKit
import CoreText
import QuartzCore

/// A passive adornment: the native status button retains every mouse and keyboard interaction.
@MainActor
final class MidasMenuBarView: NSView {
    struct Geometry {
        let mark: CGRect
        let title: CGRect
        let badge: CGRect
    }

    private let markLayer = CAShapeLayer()
    private let titleLayer = CATextLayer()
    private let badgeLayer = CALayer()
    private var presentation: MidasMenuBarPresentation?
    private var reduceMotion = false
    private var refreshAnimationAttempted = false
    private(set) var readingTransitionCount = 0
    private var highlightObservation: NSKeyValueObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.addSublayer(self.markLayer)
        self.layer?.addSublayer(self.titleLayer)
        self.layer?.addSublayer(self.badgeLayer)
        self.titleLayer.alignmentMode = .left
        self.titleLayer.truncationMode = .end
        self.setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(frame:)")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    static func geometry(in bounds: CGRect) -> Geometry {
        let mark = CGRect(x: 6, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let badge = CGRect(x: bounds.width - 18, y: (bounds.height - 12) / 2, width: 12, height: 12)
        let title = CGRect(x: 28, y: (bounds.height - 17) / 2, width: max(0, badge.minX - 32), height: 17)
        return Geometry(mark: mark, title: title, badge: badge)
    }

    func update(presentation: MidasMenuBarPresentation, reduceMotion: Bool) {
        guard self.presentation != presentation || self.reduceMotion != reduceMotion else { return }
        let readingChanged = self.presentation.map { $0.title != presentation.title } ?? false
        if !presentation.isRefreshing { self.refreshAnimationAttempted = false }
        self.presentation = presentation
        self.reduceMotion = reduceMotion
        self.refreshAppearance()
        if readingChanged, !reduceMotion, self.window != nil {
            self.readingTransitionCount += 1
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.18
            self.titleLayer.add(fade, forKey: "readingFade")
        }
        if reduceMotion { self.titleLayer.removeAllAnimations() }
        self.updateRefreshAnimation()
    }

    /// Native cell highlighting and inherited effective appearance drive colors without polling.
    func refreshAppearance() {
        guard let presentation = self.presentation else { return }
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            let highlighted = (self.superview as? NSButton)?.cell?.isHighlighted == true
            // A status button highlight is not a selected menu row; retain its inherited label appearance.
            let color = NSColor.labelColor
            let nominalFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            let measuredWidth = (presentation.title as NSString).size(withAttributes: [.font: nominalFont]).width
            let availableWidth = Self.geometry(in: CGRect(
                x: 0,
                y: 0,
                width: presentation.width,
                height: self.bounds.height)).title.width
            let fittedSize = max(9, min(13, 13 * availableWidth / max(1, measuredWidth)))
            let font = NSFont.monospacedDigitSystemFont(ofSize: (fittedSize * 2).rounded(.down) / 2, weight: .medium)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.markLayer.fillColor = color.cgColor
            self.titleLayer.font = font as CTFont
            self.titleLayer.fontSize = font.pointSize
            self.titleLayer.foregroundColor = color.cgColor
            self.titleLayer.string = presentation.title
            self.titleLayer.opacity = presentation.isStale && !highlighted ? 0.7 : 1
            self.badgeLayer.contents = self.badgeImage(presentation: presentation, color: color)
            CATransaction.commit()
        }
        self.needsLayout = true
    }

    override func layout() {
        super.layout()
        let geometry = Self.geometry(in: self.bounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.markLayer.frame = geometry.mark
        self.markLayer.path = Self.markPath()
        self.titleLayer.frame = geometry.title
        self.badgeLayer.frame = geometry.badge
        let scale = self.window?.backingScaleFactor ?? 2
        self.titleLayer.contentsScale = scale
        self.markLayer.contentsScale = scale
        self.badgeLayer.contentsScale = scale
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.refreshAppearance()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        self.highlightObservation?.invalidate()
        self.highlightObservation = (self.superview as? NSButton)?.cell?.observe(\.isHighlighted) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshAppearance() }
        }
        self.refreshAppearance()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if self.window == nil {
            self.badgeLayer.removeAllAnimations()
            self.titleLayer.removeAllAnimations()
        } else {
            self.refreshAppearance()
            self.updateRefreshAnimation()
        }
    }

    var isRefreshAnimating: Bool {
        self.badgeLayer.animation(forKey: "refreshRotation") != nil
    }

    var isReadingAnimating: Bool {
        self.titleLayer.animation(forKey: "readingFade") != nil
    }

    private func updateRefreshAnimation() {
        guard let presentation, presentation.isRefreshing, !presentation.attention, !self.reduceMotion,
              self.window != nil
        else {
            self.badgeLayer.removeAnimation(forKey: "refreshRotation")
            return
        }
        guard !self.refreshAnimationAttempted else { return }
        self.refreshAnimationAttempted = true
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = -Double.pi * 2
        rotation.duration = 1
        rotation.repeatCount = 30
        rotation.isRemovedOnCompletion = true
        self.badgeLayer.add(rotation, forKey: "refreshRotation")
    }

    private func badgeImage(presentation: MidasMenuBarPresentation, color: NSColor) -> CGImage? {
        let symbol: String
        if presentation.attention {
            symbol = "exclamationmark"
        } else if presentation.isRefreshing {
            symbol = "arrow.clockwise"
        } else if presentation.isStale {
            symbol = "circle.fill"
        } else if presentation.isPartial {
            symbol = "circle.lefthalf.filled"
        } else {
            return nil
        }
        guard let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(
                pointSize: presentation.isStale && !presentation.isRefreshing && !presentation.attention ? 4 : 10,
                weight: .semibold))
        else { return nil }
        let image = NSImage(size: NSSize(width: 12, height: 12))
        image.lockFocus()
        let size = icon.size
        icon.draw(in: NSRect(
            x: (12 - size.width) / 2,
            y: (12 - size.height) / 2,
            width: size.width,
            height: size.height))
        color.setFill()
        NSRect(x: 0, y: 0, width: 12, height: 12).fill(using: .sourceIn)
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static func markPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 8, y: 0))
        path.addCurve(to: CGPoint(x: 16, y: 8), control1: CGPoint(x: 9.4, y: 5.9), control2: CGPoint(x: 10.1, y: 6.6))
        path.addCurve(to: CGPoint(x: 8, y: 16), control1: CGPoint(x: 10.1, y: 9.4), control2: CGPoint(x: 9.4, y: 10.1))
        path.addCurve(to: CGPoint(x: 0, y: 8), control1: CGPoint(x: 6.6, y: 10.1), control2: CGPoint(x: 5.9, y: 9.4))
        path.addCurve(to: CGPoint(x: 8, y: 0), control1: CGPoint(x: 5.9, y: 6.6), control2: CGPoint(x: 6.6, y: 5.9))
        path.closeSubpath()
        return path
    }
}
