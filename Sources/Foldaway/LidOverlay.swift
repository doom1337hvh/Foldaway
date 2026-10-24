import AppKit
import QuartzCore

/// A window over the whole built-in screen in which the screen closes ahead of the real lid, in
/// the chosen style (see LidStyles.swift). Behind it is black, as if the screen had already
/// closed.
@MainActor
final class LidOverlay {
    let screen: NSScreen
    private let window: NSWindow
    private let effect: LidEffect
    /// A live pointer, drawn into the effect so it moves with the screen as it closes, while
    /// the real one is hidden. None in the README's clips.
    private let pointer: CALayer?
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// How visible the effect is against the black, kept from changing faster than over a
    /// quarter of a second, so coming back from black is as gentle as going to it.
    private var brightness: CGFloat = 1
    private var lastUpdate: CFTimeInterval?

    /// Whether the screen has gone fully dark.
    var isDark: Bool { brightness < 0.01 }

    init(frost: Frost, screen: NSScreen, style: LidStyle) {
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
        // The notch in layer coordinates, which count from the bottom.
        let notch = screen.notchRect.map {
            CGRect(x: $0.minX, y: frame.height - $0.maxY, width: $0.width, height: $0.height)
        }
        effect = style.makeEffect(EffectCanvas(frost: frost, size: frame.size, scale: window.backingScaleFactor,
                                               notch: notch))
        effect.layer.frame = view.bounds
        view.layer?.addSublayer(effect.layer)
        if DemoScene.current == nil {
            // Whichever pointer is showing: the arrow, a text cursor, and so on.
            let cursor = NSCursor.currentSystem ?? .arrow
            let image = cursor.image
            let pointer = CALayer()
            pointer.bounds = CGRect(origin: .zero, size: image.size)
            // The hot spot counts from the top left; layers count from the bottom.
            pointer.anchorPoint = CGPoint(x: cursor.hotSpot.x / image.size.width, y: 1 - cursor.hotSpot.y / image.size.height)
            pointer.contentsScale = window.backingScaleFactor
            pointer.contents = Self.bitmap(image, scale: window.backingScaleFactor)
            self.pointer = pointer
        } else {
            pointer = nil
        }
        setProgress(0)
        CATransaction.flush()
        window.orderFrontRegardless()
    }

    /// Shows the screen `progress` of the way shut: 0 is the screen as it really is, 1 is
    /// closed and dark.
    func setProgress(_ progress: Double) {
        let p = CGFloat(min(max(progress, 0), 1))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if reduceMotion {
            // With Reduce Motion, the screen only dims.
            effect.setProgress(0)
            movePointer()
            brightness = 1 - p
            effect.layer.opacity = Float(brightness)
            return
        }
        effect.setProgress(p)
        movePointer()
        // Over the last stretch it goes dark, as the screen would going out of sight.
        let now = CACurrentMediaTime()
        let step = lastUpdate.map { CGFloat(min(now - $0, 0.05)) } ?? 0
        lastUpdate = now
        let change = 1 - smoothstep(effect.darkFrom, 1, p) - brightness
        brightness += min(max(change, -step / 0.25), step / 0.25)
        effect.layer.opacity = Float(brightness)
    }

    /// The pointer's picture, drawn out: macOS's pointer images are drawn on demand, which a
    /// layer can't do by itself.
    private static func bitmap(_ image: NSImage, scale: CGFloat) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(image.size.width * scale), height: Int(image.size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// Puts the drawn pointer where the mouse is now, on the closing screen.
    private func movePointer() {
        guard let pointer else { return }
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x - screen.frame.minX, y: mouse.y - screen.frame.minY)
        pointer.isHidden = !CGRect(origin: .zero, size: screen.frame.size).contains(point)
        effect.place(pointer: pointer, at: point)
    }

    /// How much the effect covers the real screen, for fading in and out.
    func setOpacity(_ opacity: Double) {
        window.alphaValue = CGFloat(min(max(opacity, 0), 1))
    }

    func close() {
        window.orderOut(nil)
    }
}

/// Stays exactly where it's put, even over the menu bar, which AppKit would otherwise push it
/// down from.
private final class OverlayWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}

func lerp(_ from: CGFloat, _ to: CGFloat, _ t: CGFloat) -> CGFloat {
    from + (to - from) * t
}
