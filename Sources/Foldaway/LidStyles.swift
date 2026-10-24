import AppKit
import QuartzCore

/// What a style draws with: the picture of the screen, and where things are on it.
struct EffectCanvas {
    let frost: Frost
    /// The screen, in points.
    let size: CGSize
    let scale: CGFloat
    /// The camera notch, in layer coordinates (from the bottom left), if there is one.
    let notch: CGRect?
}

/// One way for the screen to close. `LidOverlay` puts its layer over the screen, tells it how
/// far the lid has closed, and takes it to black over the last stretch.
@MainActor
protocol LidEffect: AnyObject {
    /// Everything it draws, filling the screen.
    var layer: CALayer { get }
    /// How far shut it starts going dark, from 0 to 1.
    var darkFrom: CGFloat { get }
    /// 0 is the screen as it really is; 1 is shut.
    func setProgress(_ p: CGFloat)
    /// Puts the pointer at `point`, in the screen's layer coordinates, on whatever part of the
    /// picture is there, so it moves with it.
    func place(pointer: CALayer, at point: CGPoint)
}

extension LidStyle {
    @MainActor
    func makeEffect(_ canvas: EffectCanvas) -> LidEffect {
        switch self {
        case .glass: GlassEffect(canvas)
        case .notch: NotchEffect(canvas)
        case .fold: FoldEffect(canvas)
        case .lockScreen: LockScreenEffect(canvas)
        case .tv: TVEffect(canvas)
        }
    }
}

/// A layer showing `image`, filling `bounds`.
@MainActor
private func imageLayer(_ image: CGImage?, _ bounds: CGRect, scale: CGFloat) -> CALayer {
    let layer = CALayer()
    layer.frame = bounds
    layer.contents = image
    layer.contentsScale = scale
    return layer
}

/// Puts `pointer` in `parent` at `point`, as its `index`th sublayer, under whatever shades the
/// picture, so the pointer darkens with it.
@MainActor
private func adopt(_ pointer: CALayer, into parent: CALayer, at index: UInt32 = 0, point: CGPoint) {
    if pointer.superlayer !== parent {
        pointer.removeFromSuperlayer()
        parent.insertSublayer(pointer, at: index)
    }
    pointer.position = point
}

/// A layer of plain black, to darken what's under it by its opacity.
@MainActor
private func shadeLayer(_ bounds: CGRect) -> CALayer {
    let layer = CALayer()
    layer.frame = bounds
    layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    layer.opacity = 0
    return layer
}

/// A perspective as seen from about an arm's length away: 2.8 screen heights.
private func perspective(_ size: CGSize) -> CATransform3D {
    var transform = CATransform3DIdentity
    transform.m34 = -1 / (2.8 * size.height)
    return transform
}

// MARK: Frosted glass

/// The screen becomes a pane of frosted glass that swings shut on the hinge. The further the
/// glass gets from where the screen was, the more it blurs, frosts over and darkens, the top
/// edge most, slipping into black.
@MainActor
private final class GlassEffect: LidEffect {
    /// How far the pane swings toward you when the lid is all but shut, in radians.
    private static let maxTilt = 72 * CGFloat.pi / 180
    /// The blur at the pane's top edge once the frost is at full strength, in points.
    private static let maxBlur: CGFloat = 36
    /// How the blur grows from the hinge to the top: above 1, the bottom stays sharp longer.
    private static let blurCurve: CGFloat = 1.7

    let layer = CALayer()
    let darkFrom: CGFloat = 0.82
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

    init(_ canvas: EffectCanvas) {
        let size = canvas.size
        layer.sublayerTransform = perspective(size)
        pane.bounds = CGRect(origin: .zero, size: size)
        pane.anchorPoint = CGPoint(x: 0.5, y: 0)
        pane.position = CGPoint(x: size.width / 2, y: 0)
        pane.contents = canvas.frost.sharp
        pane.contentsScale = canvas.scale
        pane.masksToBounds = true
        pane.cornerRadius = 10
        pane.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer.addSublayer(pane)

        for level in canvas.frost.levels {
            let copy = imageLayer(level.image, pane.bounds, scale: canvas.scale)
            let mask = CAGradientLayer()
            mask.frame = copy.bounds
            mask.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)]
            copy.mask = mask
            pane.addSublayer(copy)
            levels.append((mask, level.radius))
        }
        // Gradients run from the hinge (0) to the top edge (1).
        for gradient in [haze, shade, sheen, edge] {
            gradient.frame = pane.bounds
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            gradient.contentsScale = canvas.scale
            pane.addSublayer(gradient)
        }
    }

    func setProgress(_ p: CGFloat) {
        // Tips slowly at first and faster toward the end, like the last stretch of a closing
        // lid, so it only looks shut as the lid really shuts.
        let closing = pow(p, 2.2)
        pane.transform = CATransform3DMakeRotation(Self.maxTilt * closing, 1, 0, 0)

        // The frost builds over most of the way, reaching full strength near the end.
        let frost = smoothstep(0, 0.85, p)
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
    }

    func place(pointer: CALayer, at point: CGPoint) {
        // Over the blurred copies, which don't have it in, and under the haze and shading.
        adopt(pointer, into: pane, at: UInt32(levels.count), point: point)
    }
}

// MARK: Into the notch

/// The screen draws itself up into the camera notch: it narrows to the notch's width and
/// shortens to a pill, softening and dimming as it goes, until the notch swallows it, like the
/// Dynamic Island closing.
@MainActor
private final class NotchEffect: LidEffect {
    let layer = CALayer()
    let darkFrom: CGFloat = 0.94
    private let card = CALayer()
    private let blur: CALayer
    private let dim: CALayer
    private let size: CGSize
    /// Where it ends up: just inside the notch, so the notch hides it; or, on a screen without
    /// one, a small pill at the top.
    private let target: CGRect

    init(_ canvas: EffectCanvas) {
        size = canvas.size
        if let notch = canvas.notch {
            target = notch.insetBy(dx: 6, dy: 3).offsetBy(dx: 0, dy: 3)
        } else {
            target = CGRect(x: size.width / 2 - 90, y: size.height - 36, width: 180, height: 30)
        }
        card.contents = canvas.frost.sharp
        card.contentsScale = canvas.scale
        card.contentsGravity = .resizeAspectFill
        card.masksToBounds = true
        card.cornerCurve = .continuous
        blur = imageLayer(canvas.frost.levels[min(2, canvas.frost.levels.count - 1)].image, .zero, scale: canvas.scale)
        blur.contentsGravity = .resizeAspectFill
        dim = shadeLayer(.zero)
        card.addSublayer(blur)
        card.addSublayer(dim)
        layer.addSublayer(card)
    }

    func setProgress(_ p: CGFloat) {
        let t = smoothstep(0, 1, p)
        // The height gives way sooner than the width, so it becomes a pill on its way in.
        let width = lerp(size.width, target.width, t)
        let height = lerp(size.height, target.height, pow(t, 0.7))
        let top = lerp(size.height, target.maxY, t)
        let centre = lerp(size.width / 2, target.midX, t)
        card.frame = CGRect(x: centre - width / 2, y: top - height, width: width, height: height)
        card.cornerRadius = lerp(10, min(width, height) / 2, t)
        blur.frame = card.bounds
        dim.frame = card.bounds
        blur.opacity = Float(smoothstep(0.05, 0.5, p))
        dim.opacity = Float(0.55 * smoothstep(0.3, 1, p))
    }

    func place(pointer: CALayer, at point: CGPoint) {
        // The card shows the screen scaled to fill it and centred.
        let card = card.bounds.size
        let scale = max(card.width / size.width, card.height / size.height)
        // Over the blurred copy, which doesn't have it in, and under the dimming.
        adopt(pointer, into: self.card, at: 1, point: CGPoint(x: (point.x - size.width / 2) * scale + card.width / 2,
                                                       y: (point.y - size.height / 2) * scale + card.height / 2))
        pointer.transform = CATransform3DMakeScale(scale, scale, 1)
    }
}

// MARK: Fold

/// A crease down the middle, and both halves swing toward each other, darkening at the crease,
/// like a foldable phone closing in your hands.
@MainActor
private final class FoldEffect: LidEffect {
    let layer = CALayer()
    let darkFrom: CGFloat = 0.82
    private var halves: [(layer: CALayer, shade: CAGradientLayer, angle: CGFloat)] = []
    /// Where the right half starts, in points: a pixel before the crease.
    private var rightStart: CGFloat = 0
    private var crease: CGFloat = 0

    init(_ canvas: EffectCanvas) {
        let size = canvas.size
        let image = canvas.frost.sharp
        layer.sublayerTransform = perspective(CGSize(width: size.height * 0.75, height: size.height * 0.75))
        // Split on a whole pixel. The right half starts a pixel early and overlaps the left, so
        // no hairline of black shows at the crease.
        let pixels = (width: image.width, height: image.height)
        let split = pixels.width / 2
        let unit = size.width / CGFloat(pixels.width)
        let crease = CGFloat(split) * unit
        self.crease = crease
        rightStart = crease - unit
        let rightPixels = pixels.width - split + 1
        let sides: [(crop: CGRect, width: CGFloat, anchor: CGFloat, corners: CACornerMask, angle: CGFloat)] = [
            (CGRect(x: 0, y: 0, width: split, height: pixels.height), crease, 1,
             [.layerMinXMinYCorner, .layerMinXMaxYCorner], 0.47 * .pi),
            (CGRect(x: split - 1, y: 0, width: rightPixels, height: pixels.height), CGFloat(rightPixels) * unit,
             1 / CGFloat(rightPixels), [.layerMaxXMinYCorner, .layerMaxXMaxYCorner], -0.47 * .pi),
        ]
        for side in sides {
            let half = imageLayer(image.cropping(to: side.crop), CGRect(x: 0, y: 0, width: side.width, height: size.height),
                                  scale: canvas.scale)
            half.anchorPoint = CGPoint(x: side.anchor, y: 0.5)
            half.position = CGPoint(x: crease, y: size.height / 2)
            half.masksToBounds = true
            half.cornerCurve = .continuous
            half.maskedCorners = side.corners
            // Darker toward the crease, as the halves turn to face each other.
            let shade = CAGradientLayer()
            shade.frame = half.bounds
            shade.startPoint = CGPoint(x: 0, y: 0.5)
            shade.endPoint = CGPoint(x: 1, y: 0.5)
            let light = CGColor(gray: 0, alpha: 0.05), dark = CGColor(gray: 0, alpha: 0.7)
            shade.colors = side.angle > 0 ? [light, dark] : [dark, light]
            shade.opacity = 0
            half.addSublayer(shade)
            layer.addSublayer(half)
            halves.append((half, shade, side.angle))
        }
    }

    func setProgress(_ p: CGFloat) {
        let closing = pow(p, 1.4)
        for half in halves {
            half.layer.transform = CATransform3DMakeRotation(half.angle * closing, 0, 1, 0)
            half.layer.cornerRadius = 28 * closing
            half.shade.opacity = Float(closing)
        }
        // It draws back a little as it folds, so its edges stay in sight.
        layer.transform = CATransform3DMakeScale(1 - 0.3 * smoothstep(0, 1, p), 1 - 0.3 * smoothstep(0, 1, p), 1)
    }

    func place(pointer: CALayer, at point: CGPoint) {
        if point.x < crease {
            adopt(pointer, into: halves[0].layer, point: point)
        } else {
            adopt(pointer, into: halves[1].layer, point: CGPoint(x: point.x - rightStart, y: point.y))
        }
    }
}

// MARK: Lock screen

/// The screen softens into a blur of the wallpaper with a large clock and the date, like an
/// iPhone locking, then goes dark.
@MainActor
private final class LockScreenEffect: LidEffect {
    let layer = CALayer()
    let darkFrom: CGFloat = 0.88
    private let softened: CALayer
    private let wallpaper: CALayer
    private let clock: CALayer
    private let clockHeight: CGFloat
    private let size: CGSize

    init(_ canvas: EffectCanvas) {
        size = canvas.size
        let bounds = CGRect(origin: .zero, size: size)
        let levels = canvas.frost.levels
        layer.addSublayer(imageLayer(canvas.frost.sharp, bounds, scale: canvas.scale))
        softened = imageLayer(levels[min(1, levels.count - 1)].image, bounds, scale: canvas.scale)
        wallpaper = imageLayer(canvas.frost.wallpaper ?? levels.last?.image, bounds, scale: canvas.scale)
        wallpaper.contentsGravity = .resizeAspectFill
        wallpaper.masksToBounds = true
        // Slightly darker, so the clock stands out the way it does on a phone.
        let tint = shadeLayer(bounds)
        tint.opacity = 0.2
        wallpaper.addSublayer(tint)
        let clockImage = Self.clockImage(width: size.width, scale: canvas.scale)
        clockHeight = CGFloat(clockImage?.height ?? 0) / canvas.scale
        clock = imageLayer(clockImage, CGRect(x: 0, y: 0, width: size.width, height: clockHeight), scale: canvas.scale)
        for sublayer in [softened, wallpaper, clock] {
            sublayer.opacity = 0
            layer.addSublayer(sublayer)
        }
    }

    func setProgress(_ p: CGFloat) {
        softened.opacity = Float(smoothstep(0, 0.2, p))
        wallpaper.opacity = Float(smoothstep(0.08, 0.45, p))
        // The clock settles into place as it fades in.
        let arrive = smoothstep(0.2, 0.55, p)
        clock.opacity = Float(arrive)
        clock.position = CGPoint(x: size.width / 2, y: size.height * 0.7 + 14 * (1 - arrive))
        clock.transform = CATransform3DMakeScale(lerp(1.06, 1, arrive), lerp(1.06, 1, arrive), 1)
    }

    func place(pointer: CALayer, at point: CGPoint) {
        // Over the sharp screen, under everything that softens it away: a lock screen has no
        // pointer of its own.
        adopt(pointer, into: layer, at: 1, point: point)
    }

    /// A lock, the date, and the time in large rounded figures, without AM or PM, as on a phone.
    private static func clockImage(width: CGFloat, scale: CGFloat) -> CGImage? {
        let now = Date()
        let usesAMPM = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? false
        let time = DateFormatter()
        time.dateFormat = usesAMPM ? "h:mm" : "HH:mm"
        let date = DateFormatter()
        date.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
            let font = NSFont.systemFont(ofSize: size, weight: weight)
            return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? font
        }
        let white = NSColor(white: 1, alpha: 0.94)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.25)
        shadow.shadowBlurRadius = 16
        let timeText = NSAttributedString(string: time.string(from: now), attributes: [
            .font: rounded(150, .semibold), .foregroundColor: white, .shadow: shadow,
        ])
        let dateText = NSAttributedString(string: date.string(from: now), attributes: [
            .font: rounded(24, .semibold), .foregroundColor: white, .shadow: shadow,
        ])
        let height: CGFloat = 280
        guard let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        if let lock = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [white]))) {
            lock.draw(in: CGRect(x: (width - lock.size.width) / 2, y: height - 30, width: lock.size.width, height: lock.size.height))
        }
        dateText.draw(at: CGPoint(x: (width - dateText.size().width) / 2, y: height - 76))
        timeText.draw(at: CGPoint(x: (width - timeText.size().width) / 2, y: height - 84 - timeText.size().height))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}

// MARK: TV off

/// An old television switching off: the picture squashes to a glowing line, the line shrinks to
/// a dot, and the dot fades.
@MainActor
private final class TVEffect: LidEffect {
    let layer = CALayer()
    let darkFrom: CGFloat = 0.9
    private let picture: CALayer
    private let glow: CALayer

    init(_ canvas: EffectCanvas) {
        let bounds = CGRect(origin: .zero, size: canvas.size)
        picture = imageLayer(canvas.frost.sharp, bounds, scale: canvas.scale)
        glow = CALayer()
        glow.frame = bounds
        glow.backgroundColor = CGColor(gray: 1, alpha: 1)
        glow.opacity = 0
        picture.addSublayer(glow)
        // The line and the dot shine onto the dark around them.
        picture.shadowColor = CGColor(srgbRed: 0.85, green: 0.92, blue: 1, alpha: 1)
        picture.shadowOffset = .zero
        picture.shadowRadius = 14
        picture.shadowPath = CGPath(rect: bounds, transform: nil)
        layer.addSublayer(picture)
    }

    func setProgress(_ p: CGFloat) {
        let squash = smoothstep(0, 0.6, p)
        let shrink = smoothstep(0.6, 0.9, p)
        let height = lerp(1, 0.004, pow(squash, 1.4))
        let width = lerp(lerp(1, 1.04, squash), 0.004, shrink)
        picture.transform = CATransform3DMakeScale(width, height, 1)
        glow.opacity = Float(0.85 * smoothstep(0.15, 0.6, p))
        picture.shadowOpacity = Float(0.9 * smoothstep(0.35, 0.65, p))
    }

    func place(pointer: CALayer, at point: CGPoint) {
        adopt(pointer, into: picture, point: point)
    }
}
