import AppKit
import CoreImage

/// The picture of the screen the glass is made from: sharp, plus a few ever more blurred
/// copies to blend between, so the blur can grow smoothly from the hinge to the top edge.
struct Frost: @unchecked Sendable {
    struct Level {
        let image: CGImage
        /// How blurred it is, in points.
        let radius: CGFloat
    }

    let sharp: CGImage
    /// From least to most blurred.
    let levels: [Level]

    /// Blur radii in points. Each is made from a smaller copy of the picture, since a blurred
    /// picture needs few pixels; that keeps it quick.
    private static let radii: [(points: CGFloat, scale: CGFloat)] = [(2.5, 0.5), (7, 0.25), (16, 0.125), (36, 0.0625)]
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Makes the glass from a picture of the screen, adding the screen's own notch and rounded
    /// top corners, so the pane looks like the screen itself as it tips away from the bezel.
    /// - Parameters:
    ///   - pointScale: pixels per point.
    ///   - notch: the notch, in points from the top-left corner, if there is one.
    static func make(from snapshot: CGImage, pointScale: CGFloat, notch: CGRect?) -> Frost? {
        guard let sharp = shaped(snapshot, pointScale: pointScale, notch: notch) else { return nil }
        let input = CIImage(cgImage: sharp)
        var levels: [Level] = []
        for (points, scale) in radii {
            let small = input.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1,
            ])
            let blurred = small.clampedToExtent()
                .applyingGaussianBlur(sigma: Double(points * pointScale * scale) / 2)
                .cropped(to: small.extent)
            guard let image = context.createCGImage(blurred, from: small.extent) else { return nil }
            levels.append(Level(image: image, radius: points))
        }
        return Frost(sharp: sharp, levels: levels)
    }

    private static func shaped(_ snapshot: CGImage, pointScale: CGFloat, notch: CGRect?) -> CGImage? {
        let width = snapshot.width
        let height = snapshot.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: snapshot.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        // Core Graphics counts from the bottom; the notch is measured from the top.
        let corner = 10 * pointScale
        let outline = CGMutablePath()
        outline.move(to: CGPoint(x: 0, y: 0))
        outline.addLine(to: CGPoint(x: bounds.maxX, y: 0))
        outline.addArc(tangent1End: CGPoint(x: bounds.maxX, y: bounds.maxY),
                       tangent2End: CGPoint(x: 0, y: bounds.maxY), radius: corner)
        outline.addArc(tangent1End: CGPoint(x: 0, y: bounds.maxY), tangent2End: CGPoint(x: 0, y: 0), radius: corner)
        outline.closeSubpath()
        context.addPath(outline)
        context.clip()
        context.draw(snapshot, in: bounds)
        if let notch {
            let rect = CGRect(x: notch.minX * pointScale, y: CGFloat(height) - notch.maxY * pointScale,
                              width: notch.width * pointScale, height: notch.height * pointScale + 1)
            let radius = min(8 * pointScale, rect.width / 2, rect.height / 2)
            let shape = CGMutablePath()
            shape.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            shape.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY),
                         radius: radius)
            shape.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY),
                         radius: radius)
            shape.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            shape.closeSubpath()
            context.addPath(shape)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
        }
        return context.makeImage()
    }
}

extension NSScreen {
    /// The camera notch, in points from the screen's top-left corner, on MacBooks with one.
    var notchRect: CGRect? {
        guard safeAreaInsets.top > 0, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return nil }
        return CGRect(x: left.maxX, y: 0, width: right.minX - left.maxX, height: safeAreaInsets.top)
    }
}
