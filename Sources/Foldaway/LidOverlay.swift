import AppKit
import QuartzCore

/// A window over the whole built-in screen in which the screen becomes a pane of frosted glass
/// that swings shut on the hinge, ahead of the real lid. The further the glass gets from where
/// the screen was, the more it blurs, frosts over and darkens, the top edge most; behind it is
/// black, as if the screen had already closed.
@MainActor
final class LidOverlay {
    /// How far the pane swings toward you when the lid is all but shut, in radians.
    private static let maxTilt = 72 * CGFloat.pi / 180
    /// The blur at the pane's top edge once the frost is at full strength, in points.
    private static let maxBlur: CGFloat = 36
    /// How the blur grows from the hinge to the top: above 1, the bottom stays sharp longer.
    private static let blurCurve: CGFloat = 1.7

    let screen: NSScreen
    private let window: NSWindow
    /// Gives the pane perspective, as seen from about where you sit.
    private let stage = CALayer()
    /// The glass, hinged along the bottom of the screen.
    private let pane = CALayer()
    /// Ever more blurred copies of the screen over the sharp one, each shown from the height
    /// at which the blur reaches its radius.
    private var levels: [(mask: CAGradientLayer, radius: CGFloat)] = []
    private let haze = CAGradientLayer()
    private let shade = CAGradientLayer()
    private let sheen = CAGradientLayer()
    /// Melts the top edge into the black behind, rather than ending in a hard line.
    private let edge = CAGradientLayer()
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// How visible the glass is against the black, kept from changing faster than over a
    /// quarter of a second, so coming back from black is as gentle as going to it.
    private var brightness: CGFloat = 1
    private var lastUpdate: CFTimeInterval?

    /// Whether the glass has gone fully dark.
    var isDark: Bool { brightness < 0.01 }

    init(frost: Frost, screen: NSScreen) {
        self.screen = screen
        let frame = screen.frame
        window = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        // Fades in over the real screen, so not opaque, though it's black throughout.
        window.isOpaque = false
        window.backgroundColor = .black
        window.alphaValue = 0
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        // Over everything, the menu bar and full-screen apps included.
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = .black
        window.contentView = view
        let scale = window.backingScaleFactor
        let size = frame.size

        stage.frame = view.bounds
        var perspective = CATransform3DIdentity
        // About an arm's length away: 2.8 screen heights.
        perspective.m34 = -1 / (2.8 * size.height)
        stage.sublayerTransform = perspective
        view.layer?.addSublayer(stage)

        pane.bounds = CGRect(origin: .zero, size: size)
        pane.anchorPoint = CGPoint(x: 0.5, y: 0)
        pane.position = CGPoint(x: size.width / 2, y: 0)
        pane.contents = frost.sharp
        pane.contentsScale = scale
        pane.masksToBounds = true
        pane.cornerRadius = 10
        pane.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        stage.addSublayer(pane)

        for level in frost.levels {
            let layer = CALayer()
            layer.frame = pane.bounds
            layer.contents = level.image
            layer.contentsScale = scale
            let mask = CAGradientLayer()
            mask.frame = layer.bounds
            mask.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)]
            layer.mask = mask
            pane.addSublayer(layer)
            levels.append((mask, level.radius))
        }
        // Gradients run from the hinge (0) to the top edge (1).
        for layer in [haze, shade, sheen, edge] {
            layer.frame = pane.bounds
            layer.startPoint = CGPoint(x: 0.5, y: 0)
            layer.endPoint = CGPoint(x: 0.5, y: 1)
            layer.contentsScale = scale
            pane.addSublayer(layer)
        }
        setProgress(0)
        CATransaction.flush()
        window.orderFrontRegardless()
    }

    /// Shows the glass `progress` of the way shut: 0 is the screen as it really is, 1 is
    /// closed and dark.
    func setProgress(_ progress: Double) {
        let p = CGFloat(min(max(progress, 0), 1))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if reduceMotion {
            // With Reduce Motion, the screen only dims.
            brightness = 1 - p
            pane.opacity = Float(brightness)
            return
        }
        // Tips slowly at first and faster toward the end, like the last stretch of a closing
        // lid, so it only looks shut as the lid really shuts.
        let closing = pow(p, 2.2)
        pane.transform = CATransform3DMakeRotation(Self.maxTilt * closing, 1, 0, 0)

        // The frost builds over most of the way, reaching full strength near the end.
        let frost = Self.smoothstep(0, 0.85, p)
        // Blur grows from nothing at the hinge to `maxBlur` at the top: each copy fades in
        // between the height where the blur reaches the previous copy's radius and its own.
        let topBlur = max(Self.maxBlur * frost, 0.001)
        func height(forBlur radius: CGFloat) -> CGFloat { pow(radius / topBlur, 1 / Self.blurCurve) }
        var previous: CGFloat = 0
        for (mask, radius) in levels {
            let start = height(forBlur: previous)
            let end = max(height(forBlur: radius), start + 0.001)
            mask.startPoint = CGPoint(x: 0.5, y: start)
            mask.endPoint = CGPoint(x: 0.5, y: end)
            previous = radius
        }
        // Frosted white, more toward the top.
        haze.colors = [CGColor(srgbRed: 0.86, green: 0.87, blue: 0.9, alpha: 0),
                       CGColor(srgbRed: 0.86, green: 0.87, blue: 0.9, alpha: 0.22 * frost)]
        // Darker as it turns away from you.
        shade.colors = [CGColor(gray: 0, alpha: 0.06 * closing), CGColor(gray: 0, alpha: 0.12 * frost + 0.5 * closing)]
        // A soft band of light that slides down the glass as it tips.
        let band = 1 - 0.7 * closing
        sheen.colors = [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0.1 * frost * (1 - closing)), CGColor(gray: 1, alpha: 0)]
        sheen.locations = [NSNumber(value: Double(band - 0.18)), NSNumber(value: Double(band)), NSNumber(value: Double(band + 0.12))]
        // The top edge slips into the dark, over more of the pane the further it's tipped.
        let fade = 0.05 + 0.25 * closing
        edge.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: min(1, 0.2 + frost))]
        edge.locations = [NSNumber(value: Double(1 - fade)), 1]
        // Over the last stretch it goes dark, as the screen would going out of sight.
        let now = CACurrentMediaTime()
        let step = lastUpdate.map { CGFloat(min(now - $0, 0.05)) } ?? 0
        lastUpdate = now
        let change = 1 - Self.smoothstep(0.82, 1, p) - brightness
        brightness += min(max(change, -step / 0.25), step / 0.25)
        pane.opacity = Float(brightness)
    }

    /// How much the glass covers the real screen, for fading in and out.
    func setOpacity(_ opacity: Double) {
        window.alphaValue = CGFloat(min(max(opacity, 0), 1))
    }

    func close() {
        window.orderOut(nil)
    }

    private static func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// Stays exactly where it's put, even over the menu bar, which AppKit would otherwise push it
/// down from.
private final class OverlayWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
