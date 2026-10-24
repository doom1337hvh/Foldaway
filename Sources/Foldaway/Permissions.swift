import AppKit
import Observation

/// Foldaway needs one permission: Screen Recording, to take a picture of the screen as the lid
/// starts to close, so the picture can fold.
@Observable @MainActor
final class Permissions {
    private(set) var screenRecording = CGPreflightScreenCaptureAccess()
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var timer: Timer?

    func refresh() {
        let screenRecording = CGPreflightScreenCaptureAccess()
        guard screenRecording != self.screenRecording else { return }
        self.screenRecording = screenRecording
        onChange?()
    }

    /// Checks every second while it's missing, so folding starts the moment it's allowed.
    func watchUntilGranted() {
        guard timer == nil, !screenRecording else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                if self.screenRecording {
                    self.timer?.invalidate()
                    self.timer = nil
                }
            }
        }
    }

    /// Shows macOS's own prompt the first time; after that, opens System Settings.
    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        watchUntilGranted()
    }
}
