import AppKit

/// The README's clips, recorded by scripts/make-video.swift. Launched with `-demo <scene>`,
/// Foldaway covers the built-in screen with a made-up desktop and closes a make-believe lid
/// over it, with its real glass. It doesn't read the real lid or save any settings.
enum DemoScene: String {
    /// The README's main clip: the lid closes, stays shut a moment, and opens again.
    case tour
    /// A slow close.
    case closing
    /// Opening, from shut.
    case opening
    /// The lid stops partway, and the glass swings back open.
    case partway
    case settings

    /// The scene asked for on the command line, if any. (`-demo tour` lands in UserDefaults'
    /// argument domain, which is never saved.)
    static let current = UserDefaults.standard.string(forKey: "demo").flatMap(DemoScene.init(rawValue:))

    /// The make-believe lid: angles at seconds from the scene's start. Opening starts before
    /// the scene, so it begins shut. scripts/make-video.swift records each scene for a set
    /// length, so keep the two in step.
    var lid: [(time: Double, angle: Double)] {
        switch self {
        case .tour: [(0, 118), (0.4, 118), (2.8, 0), (3.0, 0), (5.0, 118)]
        case .closing: [(0, 118), (0.4, 118), (3.4, 0)]
        case .opening: [(-2.4, 118), (-2.2, 118), (-1.5, 0), (-0.4, 0), (1.8, 118)]
        case .partway: [(0, 118), (0.5, 118), (1.5, 70)]
        case .settings: []
        }
    }

    /// The Settings scene drags the "Screen is shut by" slider up to 30° and back, 30 times
    /// a second.
    private static var sliderSteps: [(time: Double, angle: Double)] {
        func drag(from: Double, to: Double, start: Double, end: Double) -> [(time: Double, angle: Double)] {
            stride(from: start, through: end, by: 1.0 / 30).map { time in
                let x = (time - start) / (end - start)
                return (time, (from + (to - from) * x * x * (3 - 2 * x)).rounded())
            }
        }
        return drag(from: 10, to: 30, start: 1.6, end: 2.6) + drag(from: 30, to: 10, start: 3.8, end: 4.8)
    }

    /// Starts the scene, and writes the moment it starts (`CACurrentMediaTime`) to the file
    /// given with `-demoClock`, for the recording to keep pace with.
    @MainActor
    func run(lid watcher: LidWatcher, settings: SettingsWindowController, prefs: Preferences) {
        func begin(at start: TimeInterval) {
            guard let clock = UserDefaults.standard.string(forKey: "demoClock") else { return }
            try? String(start).write(toFile: clock, atomically: true, encoding: .utf8)
        }
        if self == .settings {
            watcher.reading.angle = 118
            settings.show()
            begin(at: CACurrentMediaTime() + 1.6)
            for (time, angle) in Self.sliderSteps {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.6 + time))
                    prefs.closeAngle = angle
                }
            }
            return
        }
        guard let screen = NSScreen.builtIn else { return }
        DemoDesktop.show(on: screen)
        // Time for the desktop to reach the screen before the glass's picture is taken, and for
        // the recording to get going.
        let start = CACurrentMediaTime() + 1.6 + max(0, -(lid.first?.time ?? 0))
        begin(at: start)
        watcher.play(lid, start: start)
    }
}

/// A made-up desktop over the whole built-in screen, under the glass: a wallpaper, a menu bar,
/// a couple of windows and a Dock, so the clips never show anyone's real screen.
@MainActor
enum DemoDesktop {
    private static var window: NSWindow?

    static func show(on screen: NSScreen) {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        // Over the real menu bar and Dock; under the glass.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.contents = image(size: screen.frame.size, scale: screen.backingScaleFactor, notch: screen.notchRect)
        view.layer?.contentsGravity = .resize
        window.contentView = view
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        CATransaction.flush()
        self.window = window
    }

    private static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static func gradient(_ colors: [CGColor]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    }

    private static func text(_ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular,
                             color: NSColor = .white) {
        NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
        ]).draw(at: point)
    }

    private static func symbol(_ name: String, in rect: CGRect, size: CGFloat, color: NSColor = .white) {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        image.draw(in: CGRect(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2,
                              width: image.size.width, height: image.size.height))
    }

    /// The desktop, in points from the top left.
    static func image(size: CGSize, scale: CGFloat, notch: CGRect?) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        // The wallpaper: a gentle two-colour one, since a GIF's 256 colours would band the
        // blurred glass over a busier one.
        context.drawLinearGradient(gradient([color(0x3B1F7A), color(0x7A1F5C)]), start: .zero,
                                   end: CGPoint(x: size.width, y: size.height), options: [])

        // The menu bar, with the camera housing in the middle.
        let barHeight = max(notch?.height ?? 0, 28)
        context.setFillColor(color(0x000000, 0.12))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: barHeight))
        var x: CGFloat = 22
        for (index, item) in ["Finder", "File", "Edit", "View", "Go", "Window", "Help"].enumerated() {
            let font = NSFont.systemFont(ofSize: 13, weight: index == 0 ? .bold : .regular)
            text(item, at: CGPoint(x: x, y: (barHeight - font.boundingRectForFont.height) / 2 + 1), size: 13,
                 weight: index == 0 ? .bold : .regular)
            x += NSAttributedString(string: item, attributes: [.font: font]).size().width + 20
        }
        var right = size.width - 18
        let clock = NSAttributedString(string: "Sat 9:41", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        right -= clock.size().width
        text("Sat 9:41", at: CGPoint(x: right, y: (barHeight - clock.size().height) / 2), size: 13, weight: .medium)
        for name in ["switch.2", "magnifyingglass", "wifi", "battery.75percent"] {
            right -= 34
            symbol(name, in: CGRect(x: right, y: 0, width: 26, height: barHeight), size: 14)
        }
        if let notch {
            context.addPath(CGPath(roundedRect: notch.insetBy(dx: 0, dy: -10).offsetBy(dx: 0, dy: -10),
                                   cornerWidth: 9, cornerHeight: 9, transform: nil))
            context.setFillColor(color(0x000000))
            context.fillPath()
        }

        // A photo library.
        let photos = CGRect(x: size.width * 0.08, y: size.height * 0.13, width: size.width * 0.5, height: size.height * 0.56)
        drawWindow(context, photos, title: "Library", background: color(0xF5F5F7))
        let columns = 4, rows = 3, gap: CGFloat = 8
        let grid = CGRect(x: photos.minX + 16, y: photos.minY + 60, width: photos.width - 32, height: photos.height - 76)
        let tile = CGSize(width: (grid.width - gap * CGFloat(columns - 1)) / CGFloat(columns),
                          height: (grid.height - gap * CGFloat(rows - 1)) / CGFloat(rows))
        let palettes: [(UInt32, UInt32)] = [(0xFF9A8B, 0xFF6A88), (0x4FACFE, 0x00F2FE), (0x43E97B, 0x38F9D7),
                                            (0xFA709A, 0xFEE140), (0x30CFD0, 0x330867), (0xA18CD1, 0xFBC2EB),
                                            (0xF6D365, 0xFDA085), (0x5EE7DF, 0xB490CA), (0x0BA360, 0x3CBA92),
                                            (0xFF0844, 0xFFB199), (0x6A11CB, 0x2575FC), (0xFDDB92, 0xD1FDFF)]
        for index in 0..<(columns * rows) {
            let cell = CGRect(x: grid.minX + CGFloat(index % columns) * (tile.width + gap),
                              y: grid.minY + CGFloat(index / columns) * (tile.height + gap),
                              width: tile.width, height: tile.height)
            context.saveGState()
            context.addPath(CGPath(roundedRect: cell, cornerWidth: 6, cornerHeight: 6, transform: nil))
            context.clip()
            let (top, bottom) = palettes[index]
            context.drawLinearGradient(gradient([color(top), color(bottom)]), start: CGPoint(x: cell.minX, y: cell.minY),
                                       end: CGPoint(x: cell.maxX, y: cell.maxY), options: [])
            // A sun, or a moon, low over each one.
            let sun = CGRect(x: cell.minX + cell.width * (0.25 + 0.4 * CGFloat(index % 3) / 2), y: cell.minY + cell.height * 0.3,
                             width: cell.height * 0.3, height: cell.height * 0.3)
            context.setFillColor(color(0xFFFFFF, 0.55))
            context.fillEllipse(in: sun)
            context.setFillColor(color(0x000000, 0.18))
            context.fill(CGRect(x: cell.minX, y: cell.minY + cell.height * 0.68, width: cell.width, height: cell.height * 0.32))
            context.restoreGState()
        }

        // A note.
        let note = CGRect(x: size.width * 0.52, y: size.height * 0.26, width: size.width * 0.38, height: size.height * 0.46)
        drawWindow(context, note, title: "Notes", background: color(0xFFFBEB))
        text("Weekend in Lisbon", at: CGPoint(x: note.minX + 28, y: note.minY + 70), size: 24, weight: .bold,
             color: NSColor(white: 0.12, alpha: 1))
        for (index, line) in ["Tram 28 up through Alfama", "Pastéis de nata, still warm", "Sunset at Senhora do Monte",
                              "LX Factory on Sunday morning", "Day trip to Sintra"].enumerated() {
            text("•  " + line, at: CGPoint(x: note.minX + 30, y: note.minY + 122 + CGFloat(index) * 32), size: 16,
                 color: NSColor(white: 0.25, alpha: 1))
        }

        // The Dock.
        let icons: [(String, UInt32, UInt32)] = [("folder.fill", 0x5AC8FA, 0x007AFF), ("safari.fill", 0x5AC8FA, 0x0A84FF),
                                                 ("message.fill", 0x5EF16A, 0x14B83A), ("photo.fill", 0xFFB86B, 0xFF5E7A),
                                                 ("music.note", 0xFF6482, 0xFC3C44), ("envelope.fill", 0x6AC4FF, 0x1E7CF2),
                                                 ("calendar", 0xFF7B6B, 0xF2412F), ("note.text", 0xFFE36B, 0xF7B500),
                                                 ("gearshape.fill", 0xB0B3BA, 0x6E7178)]
        let iconSize: CGFloat = 54, iconGap: CGFloat = 10
        let dockWidth = CGFloat(icons.count) * iconSize + CGFloat(icons.count - 1) * iconGap + 24
        let dock = CGRect(x: (size.width - dockWidth) / 2, y: size.height - iconSize - 30, width: dockWidth, height: iconSize + 16)
        context.addPath(CGPath(roundedRect: dock, cornerWidth: 24, cornerHeight: 24, transform: nil))
        context.setFillColor(color(0xFFFFFF, 0.22))
        context.setStrokeColor(color(0xFFFFFF, 0.35))
        context.setLineWidth(1)
        context.drawPath(using: .fillStroke)
        for (index, (name, top, bottom)) in icons.enumerated() {
            let icon = CGRect(x: dock.minX + 12 + CGFloat(index) * (iconSize + iconGap), y: dock.minY + 8,
                              width: iconSize, height: iconSize)
            context.saveGState()
            context.addPath(CGPath(roundedRect: icon, cornerWidth: 13, cornerHeight: 13, transform: nil))
            context.clip()
            context.drawLinearGradient(gradient([color(top), color(bottom)]), start: CGPoint(x: icon.midX, y: icon.minY),
                                       end: CGPoint(x: icon.midX, y: icon.maxY), options: [])
            context.restoreGState()
            symbol(name, in: icon, size: 24)
        }
        return context.makeImage()
    }

    private static func drawWindow(_ context: CGContext, _ frame: CGRect, title: String, background: CGColor) {
        let shape = CGPath(roundedRect: frame, cornerWidth: 16, cornerHeight: 16, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 18), blur: 40, color: color(0x000000, 0.45))
        context.addPath(shape)
        context.setFillColor(background)
        context.fillPath()
        context.restoreGState()
        context.setStrokeColor(color(0x000000, 0.12))
        context.setLineWidth(0.5)
        context.addPath(shape)
        context.strokePath()
        for (index, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            context.setFillColor(color(UInt32(hex)))
            context.fillEllipse(in: CGRect(x: frame.minX + 18 + CGFloat(index) * 20, y: frame.minY + 18, width: 12, height: 12))
        }
        text(title, at: CGPoint(x: frame.minX + 92, y: frame.minY + 15), size: 13, weight: .semibold,
             color: NSColor(white: 0.2, alpha: 1))
    }
}
