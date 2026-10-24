// Records the README's clips from the built app:
//
//   scripts/build.sh && swift scripts/make-video.swift              every scene
//   scripts/build.sh && swift scripts/make-video.swift tour closing just these
//
// For each scene, Foldaway covers the built-in screen with a made-up desktop and closes a
// make-believe lid over it (`-demo <scene>`, see Sources/Foldaway/DemoScene.swift).
// ScreenCaptureKit records only Foldaway's own windows, so nothing else on your screen gets
// in; the Settings scene is placed on a backdrop with a drawn pointer that follows the script.
// Writes docs/demo.gif (the tour, at the top of the README) and docs/clips/<scene>.gif, plus
// docs/demo.mp4 for sharing (large, so not committed). GitHub won't play a video from the
// repository, hence GIFs.
//
// Needs the Screen Recording permission for the terminal it runs in, and a MacBook. A running
// Foldaway is quit first; reopen it afterwards.
import AppKit
import AVFoundation
import CoreImage
import ScreenCaptureKit
import UniformTypeIdentifiers

// The system cursor's artwork only loads once there's an application object.
_ = NSApplication.shared

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let appBundle = root.appendingPathComponent("build/Foldaway.app")
let app = appBundle.appendingPathComponent("Contents/MacOS/Foldaway")
let bundleID = "io.github.doom1337hvh.Foldaway"
let clockFile = FileManager.default.temporaryDirectory.appendingPathComponent("foldaway-demo-clock")

guard let screen = NSScreen.screens.first(where: { screen in
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
        .map { CGDisplayIsBuiltin($0) != 0 } ?? false
}) else { fatalError("Run this on a MacBook, with its own screen on.") }
let scale = screen.backingScaleFactor
let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID

let fps = 60.0
/// The whole screen changes in these clips, which makes for big GIFs: fewer frames, and the
/// lid scenes at a smaller size, keep them light.
let gifFPS = 15.0
/// Width of the lid scenes' GIFs, in pixels.
let lidGIFWidth: CGFloat = 960
/// Seconds recorded before a scene starts.
let preRoll = 0.8

/// Settings for the scenes, as launch arguments, which are never saved: the defaults. (A
/// scene shows no menu bar icon either way.)
let settings = [
    "isEnabled": "<true/>", "unfoldOnOpen": "<true/>", "closeAngle": "<real>10</real>", "showMenuBarIcon": "<true/>",
    "lidStyle": "<integer>0</integer>",
]

// MARK: The scenes

/// A clip. Its timings follow the scene's lid in DemoScene.swift; keep the two in step.
struct Scene {
    let name: String
    /// Seconds recorded after the scene starts.
    let length: Double
    /// The pointer: seconds from the scene's start, and points from the Settings window's top
    /// left. Empty: no pointer.
    var path: [(t: Double, x: CGFloat, y: CGFloat)] = []
    /// When the mouse button is held down, dragging.
    var drags: [ClosedRange<Double>] = []
    /// Recorded around the Settings window rather than the whole screen.
    var isSettings = false
    /// The README's main clip, also written as an MP4.
    var isTour = false
    /// Settings of its own, on top of `settings`.
    var extraSettings: [String: String] = [:]

    var output: URL {
        root.appendingPathComponent(isTour ? "docs/demo.gif" : "docs/clips/\(name).gif")
    }
}

// The "Screen is shut by" slider, from the Settings window's top left: 10° at x 283, 30° at
// x 352, y 227.
let scenes: [Scene] = [
    Scene(name: "tour", length: 5.7, isTour: true),
    Scene(name: "closing", length: 3.6),
    Scene(name: "opening", length: 2.8),
    Scene(name: "partway", length: 4.0),
    Scene(name: "notch", length: 5.7, extraSettings: ["lidStyle": "<integer>1</integer>"]),
    Scene(name: "fold", length: 5.7, extraSettings: ["lidStyle": "<integer>2</integer>"]),
    Scene(name: "lock-screen", length: 5.7, extraSettings: ["lidStyle": "<integer>4</integer>"]),
    Scene(name: "tv", length: 5.7, extraSettings: ["lidStyle": "<integer>5</integer>"]),
    Scene(name: "settings", length: 6.0,
          path: [(-1, 250, 480), (0.4, 250, 480), (1.3, 283, 227), (1.6, 283, 227), (2.6, 352, 227), (3.8, 352, 227),
                 (4.8, 283, 227), (5.6, 250, 480)],
          drags: [1.5...2.65, 3.75...4.85], isSettings: true),
]

func pointer(_ scene: Scene, at t: Double) -> (point: CGPoint, pressed: Bool)? {
    guard let last = scene.path.last else { return nil }
    var position = CGPoint(x: last.x, y: last.y)
    for (from, to) in zip(scene.path, scene.path.dropFirst()) where t >= from.t && t <= to.t {
        let linear = to.t > from.t ? (t - from.t) / (to.t - from.t) : 1
        let eased = linear * linear * (3 - 2 * linear)
        position = CGPoint(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased)
        break
    }
    return (position, scene.drags.contains { $0.contains(t) })
}

// MARK: Drawing

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

/// A context of `size` points drawn at `pixelScale`, with the origin at the top left, like a screen.
func makeContext(_ size: CGSize, pixelScale: CGFloat) -> CGContext {
    let context = CGContext(data: nil, width: Int(size.width * pixelScale), height: Int(size.height * pixelScale),
                            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.translateBy(x: 0, y: size.height * pixelScale)
    context.scaleBy(x: pixelScale, y: -pixelScale)
    context.interpolationQuality = .high
    return context
}

/// A gentle two-colour wallpaper behind the Settings window; a GIF's 256 colours would band a
/// busier one.
func makeBackdrop(_ size: CGSize, pixelScale: CGFloat) -> CGImage {
    let context = makeContext(size, pixelScale: pixelScale)
    context.drawLinearGradient(gradient([color(0x3B1F7A), color(0x7A1F5C)]), start: .zero,
                               end: CGPoint(x: size.width, y: size.height), options: [])
    return context.makeImage()!
}

let arrow = NSCursor.arrow

/// The backdrop, Foldaway's windows and the pointer, at `time` seconds into the scene.
func compose(_ context: CGContext, size: CGSize, backdrop: CGImage?, capture: CGImage?, scene: Scene,
             anchor: CGPoint, time: Double) -> CGImage? {
    context.setFillColor(color(0x000000))
    context.fill(CGRect(origin: .zero, size: size))
    for image in [backdrop, capture].compactMap({ $0 }) {
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        context.restoreGState()
    }
    if let (position, pressed) = pointer(scene, at: time) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let factor: CGFloat = pressed ? 0.85 : 1
        let imageSize = CGSize(width: arrow.image.size.width * factor, height: arrow.image.size.height * factor)
        let origin = CGPoint(x: anchor.x + position.x - arrow.hotSpot.x * factor,
                             y: anchor.y + position.y - arrow.hotSpot.y * factor)
        arrow.image.draw(in: CGRect(origin: origin, size: imageSize))
        NSGraphicsContext.restoreGraphicsState()
    }
    return context.makeImage()
}

// MARK: Capture

/// Keeps the latest frame ScreenCaptureKit delivers.
final class Capture: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CGImage?
    private let images = CIContext()

    var latest: CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return frame
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: status) == .complete,
              let pixels = buffer.imageBuffer
        else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        guard let cgImage = images.createCGImage(image, from: image.extent) else { return }
        lock.lock()
        frame = cgImage
        lock.unlock()
    }
}

func run(_ path: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    try? process.run()
    process.waitUntilExit()
}

/// Launches Foldaway on `scene` the way Finder would, so it comes to the front (and its
/// Settings window looks active), and returns its process.
func launch(_ scene: Scene) async throws -> pid_t {
    let running = { Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier)) }
    let before = running()
    run("/usr/bin/open", ["-n", appBundle.path, "--args", "-demo", scene.name, "-demoClock", clockFile.path]
        + settings.merging(scene.extraSettings) { $1 }.sorted { $0.key < $1.key }.flatMap { ["-\($0.key)", $0.value] })
    for _ in 0..<50 {
        if let pid = running().subtracting(before).first { return pid }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw NSError(domain: "make-video", code: 4, userInfo: [NSLocalizedDescriptionKey: "\(scene.name): didn't launch"])
}

/// Launches Foldaway on `scene`, records it, and writes its GIF (and MP4 for the tour).
func record(_ scene: Scene) async throws {
    run("/usr/bin/pkill", ["-x", "Foldaway"])
    try await Task.sleep(for: .seconds(1))
    try? FileManager.default.removeItem(at: clockFile)
    let pid = try await launch(scene)
    defer { kill(pid, SIGTERM) }

    // Wait for Foldaway's windows: the Settings window, or the made-up desktop.
    var found: (SCShareableContent, SCRunningApplication, SCWindow)?
    for _ in 0..<60 where found == nil {
        try await Task.sleep(for: .milliseconds(100))
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let foldaway = content.applications.first(where: { $0.processID == pid }) else { continue }
        let windows = content.windows.filter { $0.owningApplication?.processID == pid }
        if let window = windows.first(where: { scene.isSettings ? $0.windowLayer == 0 : $0.frame.width >= screen.frame.width }) {
            found = (content, foldaway, window)
        }
    }
    guard let (content, foldaway, window) = found,
          let display = content.displays.first(where: { $0.displayID == displayID })
    else { throw NSError(domain: "make-video", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(scene.name): no windows"]) }

    // The area recorded, in screen points from the top left, where the pointer's coordinates
    // start within it, and the size of the clip's pixels.
    let region: CGRect
    let anchor: CGPoint
    let gifScale: CGFloat
    if scene.isSettings {
        let frame = window.frame
        region = CGRect(x: frame.minX - 40, y: frame.minY - 40, width: frame.width + 80, height: frame.height + 80)
        anchor = CGPoint(x: 40, y: 40)
        gifScale = scale
    } else {
        region = CGRect(origin: .zero, size: screen.frame.size)
        anchor = .zero
        gifScale = lidGIFWidth / region.width
    }
    let size = region.size
    let pixelWidth = Int(size.width * scale), pixelHeight = Int(size.height * scale)

    let configuration = SCStreamConfiguration()
    configuration.sourceRect = region
    configuration.width = pixelWidth
    configuration.height = pixelHeight
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.colorSpaceName = CGColorSpace.sRGB
    configuration.backgroundColor = .clear
    configuration.showsCursor = false
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    configuration.queueDepth = 8
    let capture = Capture()
    let stream = SCStream(filter: SCContentFilter(display: display, including: [foldaway], exceptingWindows: []),
                          configuration: configuration, delegate: nil)
    try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture"))
    try await stream.startCapture()

    // The scene writes its start time (CACurrentMediaTime) once it begins.
    var start: Double?
    for _ in 0..<200 where start == nil {
        start = (try? String(contentsOf: clockFile, encoding: .utf8)).flatMap(Double.init)
        if start == nil { try await Task.sleep(for: .milliseconds(50)) }
    }
    guard let start else { throw NSError(domain: "make-video", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(scene.name): didn't start"]) }

    // The GIF, and for the tour an MP4 at full size.
    let frameCount = Int((preRoll + scene.length) * fps)
    let gifStep = Int(fps / (scene.isSettings ? 20 : gifFPS))
    try FileManager.default.createDirectory(at: scene.output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: scene.output)
    let gif = CGImageDestinationCreateWithURL(scene.output as CFURL, UTType.gif.identifier as CFString, frameCount / gifStep + 1, nil)!
    CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let delay = Double(gifStep) / fps
    let gifFrame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                    kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
    let gifContext = makeContext(size, pixelScale: gifScale)
    let backdrop = scene.isSettings ? makeBackdrop(size, pixelScale: gifScale) : nil

    var video: (writer: AVAssetWriter, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor,
                context: CGContext)?
    if scene.isTour {
        let url = root.appendingPathComponent("docs/demo.mp4")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: pixelWidth, AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 16_000_000,
                                              AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                              AVVideoExpectedSourceFrameRateKey: Int(fps)],
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: pixelWidth, kCVPixelBufferHeightKey as String: pixelHeight,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        video = (writer, input, adaptor, makeContext(size, pixelScale: scale))
    }

    let firstFrame = start - preRoll
    for index in 0..<frameCount {
        let time = Double(index) / fps
        // Keep pace with the app, a frame behind so the capture has caught up.
        while CACurrentMediaTime() < firstFrame + time + 1 / fps { usleep(1000) }
        let captured = capture.latest
        let sceneTime = time - preRoll

        if index % gifStep == 0,
           let still = compose(gifContext, size: size, backdrop: backdrop, capture: captured, scene: scene,
                               anchor: anchor, time: sceneTime) {
            CGImageDestinationAddImage(gif, still, gifFrame)
        }
        guard let video, let composed = compose(video.context, size: size, backdrop: nil, capture: captured,
                                                scene: scene, anchor: anchor, time: sceneTime)
        else { continue }
        while !video.input.isReadyForMoreMediaData { usleep(500) }
        var buffer: CVPixelBuffer?
        if let pool = video.adaptor.pixelBufferPool,
           CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer {
            CVPixelBufferLockBaseAddress(buffer, [])
            CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: pixelWidth, height: pixelHeight,
                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?
                .draw(composed, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            video.adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
        }
    }

    CGImageDestinationFinalize(gif)
    if let video {
        video.input.markAsFinished()
        await video.writer.finishWriting()
    }
    try await stream.stopCapture()
    try? FileManager.default.removeItem(at: clockFile)
    let bytes = (try? FileManager.default.attributesOfItem(atPath: scene.output.path)[.size] as? Int) ?? 0
    print("  \(scene.name): \(scene.output.path.replacingOccurrences(of: root.path + "/", with: "")) (\(bytes / 1024) KB)")
}

guard FileManager.default.isExecutableFile(atPath: app.path) else { fatalError("Build the app first: scripts/build.sh") }
let requested = Set(CommandLine.arguments.dropFirst())
for scene in scenes where requested.isEmpty || requested.contains(scene.name) {
    do {
        try await record(scene)
    } catch {
        print("  \(scene.name) failed: \(error.localizedDescription)")
    }
}
