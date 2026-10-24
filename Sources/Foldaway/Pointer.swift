import AppKit

/// Hides the pointer while the glass is up; otherwise it would float over a screen that's
/// closing. macOS only lets the frontmost app hide the pointer, so this asks the WindowServer,
/// through a private setting, to let Foldaway do it from the background. If that setting ever
/// goes away, the pointer simply stays.
@MainActor
enum Pointer {
    private static var isHidden = false

    static func hide() {
        guard !isHidden else { return }
        allowFromBackground()
        if CGDisplayHideCursor(CGMainDisplayID()) == .success { isHidden = true }
    }

    static func show() {
        guard isHidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        isHidden = false
    }

    private static func allowFromBackground() {
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let everywhere = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let connection = dlsym(everywhere, "_CGSDefaultConnection"),
              let setProperty = dlsym(everywhere, "CGSSetConnectionProperty")
        else { return }
        let id = unsafeBitCast(connection, to: DefaultConnection.self)()
        _ = unsafeBitCast(setProperty, to: SetProperty.self)(id, id, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}
