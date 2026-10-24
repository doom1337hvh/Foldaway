// Draws Foldaway's app icon and writes Resources/AppIcon.icns and docs/icon.png.
//
//   swift scripts/make-icon.swift
//
// A rounded square in the macOS icon grid, with a MacBook whose screen is closing ahead of
// its lid: a pane of frosted glass tipping toward you on the hinge, the top already dark.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

func quad(_ points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: points)
    path.closeSubpath()
    return path
}

func drawIcon(in context: CGContext) {
    // Core Graphics' origin is bottom-left; flip so y grows downward like the layout below.
    context.translateBy(x: 0, y: canvas)
    context.scaleBy(x: 1, y: -1)

    // The body: 824 pt with a continuous-looking corner, per Apple's icon grid.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, 0.35))
    context.addPath(bodyPath)
    context.setFillColor(color(0x000000))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    context.drawLinearGradient(gradient([color(0x2E1065), color(0x1E1B4B), color(0x0B0A1A)]),
                               start: CGPoint(x: 512, y: body.minY), end: CGPoint(x: 512, y: body.maxY), options: [])
    // A soft glow behind the screen, like light spilling from it.
    context.drawRadialGradient(gradient([color(0xC084FC, 0.35), color(0xC084FC, 0)]),
                               startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 470), endRadius: 430, options: [])

    // The lid: a black bezel with a fine aluminium edge.
    let lid = CGRect(x: 196, y: 236, width: 632, height: 418)
    let lidPath = CGPath(roundedRect: lid, cornerWidth: 34, cornerHeight: 34, transform: nil)
    context.addPath(lidPath)
    context.setFillColor(color(0x060608))
    context.fillPath()
    context.addPath(lidPath)
    context.setStrokeColor(color(0xA1A1AA))
    context.setLineWidth(5)
    context.strokePath()

    // The screen, and the glass on it: hinged along the screen's bottom edge, tipped toward
    // you so its top edge is lower and wider. Above it, the screen has already gone dark.
    let screen = lid.insetBy(dx: 20, dy: 20)
    context.saveGState()
    context.addPath(CGPath(roundedRect: screen, cornerWidth: 18, cornerHeight: 18, transform: nil))
    context.clip()
    let hingeY = screen.maxY - 14
    let topY: CGFloat = 418
    let top = (left: screen.minX + 10, right: screen.maxX - 10)
    let pane = quad([CGPoint(x: top.left, y: topY), CGPoint(x: top.right, y: topY),
                     CGPoint(x: screen.maxX - 40, y: hingeY), CGPoint(x: screen.minX + 40, y: hingeY)])
    context.addPath(pane)
    context.clip()
    // The wallpaper seen through the frost: the same colours as the README's clips.
    context.drawLinearGradient(gradient([color(0x5B21B6), color(0xBE185D), color(0xF97316)]),
                               start: CGPoint(x: screen.minX, y: topY), end: CGPoint(x: screen.maxX, y: hingeY), options: [])
    // Windows, blurred by the frost: soft light panels, sharper toward the hinge.
    for (rect, alpha) in [(CGRect(x: 250, y: 452, width: 300, height: 150), 0.55),
                          (CGRect(x: 500, y: 478, width: 270, height: 130), 0.75)] as [(CGRect, CGFloat)] {
        for spread in stride(from: 26, through: 0, by: -2) {
            let path = CGPath(roundedRect: rect.insetBy(dx: CGFloat(-spread), dy: CGFloat(-spread)),
                              cornerWidth: 18 + CGFloat(spread), cornerHeight: 18 + CGFloat(spread), transform: nil)
            context.addPath(path)
            context.setFillColor(color(0xFFF7ED, alpha * 0.07))
            context.fillPath()
        }
    }
    // Frost toward the top, then darker, slipping into black at the far edge.
    context.drawLinearGradient(gradient([color(0xDDE1EA, 0.35), color(0xDDE1EA, 0)]),
                               start: CGPoint(x: 512, y: topY), end: CGPoint(x: 512, y: hingeY), options: [])
    context.drawLinearGradient(gradient([color(0x000000, 0.95), color(0x000000, 0.35), color(0x000000, 0)], [0, 0.35, 1]),
                               start: CGPoint(x: 512, y: topY), end: CGPoint(x: 512, y: hingeY), options: [])
    context.restoreGState()
    // A bright rim where light catches the glass's top edge.
    context.saveGState()
    context.addPath(CGPath(roundedRect: screen, cornerWidth: 18, cornerHeight: 18, transform: nil))
    context.clip()
    context.move(to: CGPoint(x: top.left, y: topY))
    context.addLine(to: CGPoint(x: top.right, y: topY))
    context.setStrokeColor(color(0xFFFFFF, 0.28))
    context.setLineWidth(3)
    context.strokePath()
    context.restoreGState()

    // The base, seen from just above, with the notch for opening the lid.
    let base = quad([CGPoint(x: 168, y: 660), CGPoint(x: 856, y: 660), CGPoint(x: 904, y: 708), CGPoint(x: 120, y: 708)])
    context.saveGState()
    context.addPath(base)
    context.clip()
    context.drawLinearGradient(gradient([color(0xE5E7EB), color(0x9CA3AF)]),
                               start: CGPoint(x: 512, y: 660), end: CGPoint(x: 512, y: 708), options: [])
    context.restoreGState()
    context.addPath(CGPath(roundedRect: CGRect(x: 452, y: 656, width: 120, height: 14), cornerWidth: 7, cornerHeight: 7, transform: nil))
    context.setFillColor(color(0x6B7280))
    context.fillPath()
    context.restoreGState()
}

func png(size: Int) -> Data {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    context.interpolationQuality = .high
    drawIcon(in: context)
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
try png(size: 1024).write(to: root.appendingPathComponent("docs/icon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns and docs/icon.png" : "iconutil failed")
