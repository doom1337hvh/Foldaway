import AppKit
import ScreenCaptureKit

/// Takes a picture of a whole display with ScreenCaptureKit.
enum ScreenSnapshot {
    /// The display at full resolution, normally pointer and all: the glass takes the pointer
    /// with it, and the real one hides while the glass is up.
    static func capture(_ displayID: CGDirectDisplayID, pointer: Bool = true) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            configuration.width = Int((filter.contentRect.width * scale).rounded())
            configuration.height = Int((filter.contentRect.height * scale).rounded())
            configuration.captureResolution = .best
            configuration.showsCursor = pointer
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            return nil
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// The MacBook's own screen, the one in the lid, while it's on.
    static var builtIn: NSScreen? {
        screens.first { screen in screen.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false }
    }
}
