import AppKit
import CodexBarCore
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
    private let orbitLayer = CALayer()
    private let orbitTrack = CAShapeLayer()
    private let orbitProgress = CAShapeLayer()
    private let orbitLogo = CALayer()
    private let orbitSatellite = CALayer()
    private let orbitDot = CAShapeLayer()
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
        self.layer?.addSublayer(self.orbitLayer)
        self.orbitLayer.addSublayer(self.orbitTrack)
        self.orbitLayer.addSublayer(self.orbitProgress)
        self.orbitLayer.addSublayer(self.orbitLogo)
        self.orbitLayer.addSublayer(self.orbitSatellite)
        self.orbitSatellite.addSublayer(self.orbitDot)
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

    static func geometry(in bounds: CGRect, orbit: Bool = false) -> Geometry {
        let inset = MidasMenuBarLayout.horizontalInset
        let gap = MidasMenuBarLayout.readingGap
        if orbit {
            let size = MidasMenuBarLayout.orbitWidth
            let orb = CGRect(x: bounds.maxX - inset - size, y: bounds.midY - size / 2, width: size, height: size)
            let reading = CGRect(
                x: bounds.minX + inset,
                y: bounds.midY - 8.5,
                width: max(0, orb.minX - gap - bounds.minX - inset),
                height: 17)
            return Geometry(mark: orb, title: reading, badge: orb)
        }
        let mark = CGRect(x: bounds.minX + inset, y: bounds.midY - 8, width: 16, height: 16)
        // Reserve only the small indicator slot so refresh/stale/warning transitions do not shift neighbors.
        let badge = CGRect(x: bounds.maxX - inset - 12, y: bounds.midY - 6, width: 12, height: 12)
        let title = CGRect(
            x: mark.maxX + gap,
            y: bounds.midY - 8.5,
            width: max(0, badge.minX - MidasMenuBarLayout.badgeGap - mark.maxX - gap),
            height: 17)
        return Geometry(mark: mark, title: title, badge: badge)
    }

    func update(presentation: MidasMenuBarPresentation, reduceMotion: Bool) {
        guard self.presentation != presentation || self.reduceMotion != reduceMotion else { return }
        let readingChanged = self.presentation.map { $0.title != presentation.title } ?? false
        if self.presentation?.orbitProvider != presentation.orbitProvider {
            self.badgeLayer.removeAllAnimations()
            self.orbitSatellite.removeAllAnimations()
            self.refreshAnimationAttempted = false
        }
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
            let font = MidasMenuBarLayout.font
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.markLayer.isHidden = presentation.orbitProvider != nil
            self.badgeLayer.isHidden = presentation.orbitProvider != nil
            self.orbitLayer.isHidden = presentation.orbitProvider == nil
            self.markLayer.fillColor = color.cgColor
            self.titleLayer.alignmentMode = .left
            self.titleLayer.font = font as CTFont
            self.titleLayer.fontSize = font.pointSize
            self.titleLayer.foregroundColor = color.cgColor
            self.titleLayer.string = presentation.title
            self.titleLayer.opacity = presentation.orbitProvider == nil && presentation
                .isStale && !highlighted ? 0.7 : 1
            self.badgeLayer.contents = self.badgeImage(presentation: presentation, color: color)
            self.configureOrbit(presentation, color: color)
            CATransaction.commit()
        }
        self.needsLayout = true
    }

    override func layout() {
        super.layout()
        let geometry = Self.geometry(in: self.bounds, orbit: self.presentation?.orbitProvider != nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.markLayer.frame = geometry.mark
        self.markLayer.path = Self.markPath()
        self.titleLayer.frame = geometry.title
        self.badgeLayer.frame = geometry.badge
        self.orbitLayer.frame = geometry.mark
        self.orbitTrack.frame = self.orbitLayer.bounds
        self.orbitProgress.frame = self.orbitLayer.bounds
        self.orbitLogo.frame = CGRect(x: 2.5, y: 2.5, width: 13, height: 13)
        self.orbitSatellite.frame = self.orbitLayer.bounds
        self.orbitDot.frame = CGRect(x: 7.5, y: 15, width: 3, height: 3)
        let scale = self.window?.backingScaleFactor ?? 2
        self.titleLayer.contentsScale = scale
        self.markLayer.contentsScale = scale
        self.badgeLayer.contentsScale = scale
        self.orbitLogo.contentsScale = scale
        self.orbitTrack.contentsScale = scale
        self.orbitProgress.contentsScale = scale
        self.orbitDot.contentsScale = scale
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
            self.orbitSatellite.removeAllAnimations()
            self.titleLayer.removeAllAnimations()
        } else {
            self.refreshAppearance()
            self.updateRefreshAnimation()
        }
    }

    var isRefreshAnimating: Bool {
        self.badgeLayer.animation(forKey: "refreshRotation") != nil
            || self.orbitSatellite.animation(forKey: "refreshRotation") != nil
    }

    var isReadingAnimating: Bool {
        self.titleLayer.animation(forKey: "readingFade") != nil
    }

    private func updateRefreshAnimation() {
        guard let presentation, presentation.isRefreshing, !presentation.attention, !self.reduceMotion,
              self.window != nil
        else {
            self.badgeLayer.removeAnimation(forKey: "refreshRotation")
            self.orbitSatellite.removeAnimation(forKey: "refreshRotation")
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
        let target = presentation.orbitProvider == nil ? self.badgeLayer : self.orbitSatellite
        target.add(rotation, forKey: "refreshRotation")
    }

    /// Ring geometry measures remaining capacity; only its separate satellite can rotate.
    private func configureOrbit(_ presentation: MidasMenuBarPresentation, color: NSColor) {
        guard let provider = presentation.orbitProvider else { return }
        let path = CGMutablePath()
        path.addArc(
            center: CGPoint(x: 9, y: 9),
            radius: 8,
            startAngle: .pi / 2,
            endAngle: -.pi * 3 / 2,
            clockwise: true)
        let known = presentation.orbitRemainingPercent != nil
        let tint = presentation.attention ? NSColor.systemOrange : color
        for ring in [self.orbitTrack, self.orbitProgress] {
            ring.path = path
            ring.fillColor = nil
            ring.lineWidth = 1.5
            ring.lineCap = .butt
        }
        self.orbitTrack.strokeColor = color.withAlphaComponent(known ? 0.25 : 0.45).cgColor
        self.orbitTrack.lineDashPattern = known ? nil : [2, 2]
        self.orbitProgress.strokeColor = tint.cgColor
        self.orbitProgress.strokeEnd = CGFloat(presentation.orbitRemainingPercent ?? 0) / 100
        self.orbitLayer.opacity = presentation.isStale ? 0.65 : 1
        self.orbitDot.path = presentation.attention
            ? CGPath(rect: CGRect(x: 0, y: 0, width: 3, height: 3), transform: nil)
            : CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 3, height: 3), transform: nil)
        self.orbitDot.fillColor = tint.cgColor
        self.orbitDot.isHidden = !presentation.attention && !presentation.isRefreshing
        if let source = MidasProviderLogoLoader.image(for: provider, size: 26, dark: false, role: .menuBar) {
            let image = NSImage(size: NSSize(width: 22, height: 22))
            image.lockFocus()
            source.draw(in: NSRect(x: 0, y: 0, width: 22, height: 22))
            color.setFill()
            NSRect(x: 0, y: 0, width: 22, height: 22).fill(using: .sourceIn)
            image.unlockFocus()
            self.orbitLogo.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        } else {
            self.orbitLogo.contents = nil
        }
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
