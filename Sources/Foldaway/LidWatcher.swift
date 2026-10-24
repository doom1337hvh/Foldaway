import AppKit
import Observation
import QuartzCore

/// The latest lid angle, for Settings.
@Observable @MainActor
final class LidReading {
    var angle: Double?
}

/// Follows the lid. When it starts closing, takes a picture of the built-in screen and turns
/// it into glass that swings shut ahead of the lid, frame by frame, so the screen looks closed
/// before the lid is. Opening the lid swings it back open.
@MainActor
final class LidWatcher: NSObject {
    let reading = LidReading()
    var hasSensor: Bool { sensor != nil }
    /// Called when "Play It Now" finishes.
    var onPlayed: (() -> Void)?

    private enum Phase {
        /// Watching for the lid to start closing.
        case idle
        /// Following the lid every frame.
        case following
        /// Shut, waiting for the lid to open.
        case shut
    }

    private let prefs: Preferences
    private let sensor: LidSensor?
    private var phase = Phase.idle
    private var isWatching = false
    /// The last few tenths of a second of angles, to notice the lid starting to close.
    private var history: [(time: TimeInterval, angle: Double)] = []
    /// Where the lid rested before it started closing: the glass is fully open there.
    private var restAngle = 120.0
    private var overlay: LidOverlay?
    private var frost: Frost?
    /// When the picture was taken: one taken at the first sign of movement goes stale if the
    /// lid doesn't go on to close.
    private var frostTakenAt: TimeInterval = 0
    private var isPreparing = false
    private var followingSince: TimeInterval = 0

    /// The sensor's latest new value, and how fast the lid was moving by it.
    private var latest: (time: TimeInterval, angle: Double)?
    private var velocity = 0.0
    private var lastRead: TimeInterval = 0
    private var lastMoved: TimeInterval = 0
    private var movedFrom = 0.0
    /// How shut the glass looks, and how fast that's changing: a spring following the lid.
    private var shown = 0.0
    private var shownVelocity = 0.0
    /// How far the glass has faded in over the real screen, eased on its own clock, so the
    /// effect always starts and ends gently however the lid moves.
    private var presence = 0.0
    private var lastFrame: TimeInterval?

    private var pollTimer: Timer?
    private var displayLink: CADisplayLink?
    /// Made-up angles over time, for "Play It Now" and the README's clips, in place of the
    /// sensor's.
    private var script: LidScript?

    init(prefs: Preferences) {
        self.prefs = prefs
        sensor = LidSensor()
        super.init()
        sensor?.onReport = { [weak self] angle in self?.sample(angle) }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// Watches the lid while the effect is on.
    func update() {
        if prefs.isEnabled && sensor != nil {
            startWatching()
        } else if script == nil {
            stopWatching()
        }
    }

    /// Closes and reopens the lid in make-believe, so the effect can be seen without closing
    /// it. `closing` is how long the lid takes to shut, in seconds.
    func play(closing: TimeInterval = 1.2) {
        let from = max(currentAngle() ?? 120, 100)
        play([(0, from), (closing, 0), (closing + 0.8, 0), (closing * 2 + 0.8, from)])
    }

    /// Moves a make-believe lid through `keyframes`: angles at seconds from `start`.
    func play(_ keyframes: [(time: Double, angle: Double)], start: TimeInterval = CACurrentMediaTime()) {
        guard script == nil else { return }
        stopWatching()
        script = LidScript(keyframes: keyframes, start: start)
        // The make-believe lid is noticed closing just like the real one.
        startPolling()
    }

    /// Puts everything back, for when Foldaway quits.
    func stop() {
        stopWatching()
    }

    private func startWatching() {
        guard !isWatching else { return }
        isWatching = true
        sensor?.startListening()
        startPolling()
    }

    private func stopWatching() {
        isWatching = false
        sensor?.stopListening()
        letGo()
        stopPolling()
    }

    private func currentAngle() -> Double? {
        if let script { return script.angle(at: CACurrentMediaTime()) }
        return sensor?.read()
    }

    // MARK: Watching for the lid to close

    /// Ten times a second is as often as the sensor changes, and enough to catch the lid as it
    /// starts to close, at under a millisecond per reading.
    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let angle = self.currentAngle() else { return }
                self.sample(angle)
                if let script = self.script, self.phase == .idle, script.isFinished(at: CACurrentMediaTime()) {
                    self.letGo()
                }
            }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func sample(_ angle: Double) {
        let now = CACurrentMediaTime()
        observe(angle, at: now)
        switch phase {
        case .idle:
            if frost != nil, now - frostTakenAt > 2 { frost = nil }
            // At the first sign of the lid moving down, the picture is made ready, so the glass
            // can appear the moment it's clearly closing.
            if (history.map(\.angle).max() ?? angle) - angle >= 1.5, frost == nil, let screen = NSScreen.builtIn {
                prepare(screen)
            }
            // Closing: falling at least 15° a second.
            guard let oldest = history.first, now - oldest.time >= 0.05,
                  (angle - oldest.angle) / (now - oldest.time) < -15
            else { return }
            restAngle = min(max(history.map(\.angle).max() ?? angle, prefs.closeAngle + 40), 140)
            follow()
        case .shut:
            if angle > prefs.closeAngle + 3 {
                prefs.unfoldOnOpen ? follow() : letGo()
            }
        case .following:
            break
        }
    }

    /// Notes a reading: for Settings, for spotting the lid starting to move, and for how fast
    /// it's moving between the sensor's updates.
    private func observe(_ angle: Double, at now: TimeInterval) {
        reading.angle = angle
        history.append((now, angle))
        history.removeAll { now - $0.time > 0.3 }
        if let latest, abs(angle - latest.angle) < 0.05 {
            // Nothing new from the sensor. If nothing's come for a while, the lid has stopped.
            if now - latest.time > 0.25 { velocity = 0 }
        } else {
            if let latest, now - latest.time > 0.02 {
                velocity = min(max((angle - latest.angle) / (now - latest.time), -400), 400)
            }
            latest = (now, angle)
        }
        if abs(angle - movedFrom) >= 1.5 {
            movedFrom = angle
            lastMoved = now
        }
    }

    // MARK: Following the lid

    private func follow() {
        guard let screen = NSScreen.builtIn else { return letGo() }
        if phase == .idle {
            followingSince = CACurrentMediaTime()
            shown = 0
            shownVelocity = 0
            presence = 0
        }
        phase = .following
        stopPolling()
        if frost == nil || CACurrentMediaTime() - frostTakenAt > 2 {
            frost = nil
            prepare(screen)
        }
        lastFrame = nil
        lastMoved = CACurrentMediaTime()
        if displayLink == nil {
            let link = screen.displayLink(target: self, selector: #selector(frame))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    /// Takes the picture of the screen and makes the glass from it, off the main thread.
    private func prepare(_ screen: NSScreen) {
        guard !isPreparing, let displayID = screen.displayID else { return }
        isPreparing = true
        let scale = screen.backingScaleFactor
        let notch = screen.notchRect
        // The README's clips show the made-up desktop's wallpaper, not yours.
        let wallpaper = prefs.style == .lockScreen && DemoScene.current == nil
            ? NSWorkspace.shared.desktopImageURL(for: screen) : nil
        Task { @MainActor in
            let snapshot = await ScreenSnapshot.capture(displayID)
            let frost = await Task.detached(priority: .userInitiated) {
                snapshot.flatMap { Frost.make(from: $0, pointScale: scale, notch: notch, wallpaper: wallpaper) }
            }.value
            isPreparing = false
            if let frost {
                self.frost = frost
                frostTakenAt = CACurrentMediaTime()
            } else if phase != .idle {
                // Without a picture (no Screen Recording permission), there's nothing to show.
                letGo()
            }
        }
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        // The sensor changes about ten times a second; reading it every frame would be waste.
        if now - lastRead >= 1.0 / 60 {
            lastRead = now
            guard let angle = currentAngle() else { return letGo() }
            observe(angle, at: now)
        }
        guard let latest else { return }
        // Where the lid most likely is by now, between the sensor's updates; looking only a
        // little ahead, so the glass never gets ahead of the lid.
        let predicted = latest.angle + velocity * min(now - latest.time, 0.07)
        let target = min(max((restAngle - predicted) / (restAngle - prefs.closeAngle), 0), 1)
        let still = now - lastMoved
        // Stopped partway, say tilting the screen to a new angle, it swings back open and
        // lets go.
        let goal = (still > 1.2 && target < 0.9) || now - followingSince > 15 ? 0 : target

        // A critically damped spring toward the goal: smooth, no overshoot.
        let step = lastFrame.map { min(now - $0, 0.05) } ?? 1.0 / 120
        lastFrame = now
        let stiffness = 20.0
        shownVelocity += (stiffness * stiffness * (goal - shown) - 2 * stiffness * shownVelocity) * step
        shown = min(max(shown + shownVelocity * step, 0), 1)

        // Done once it's back open and the lid has settled; then it fades away.
        let isDone = goal == 0 && shown < 0.01 && still > 0.3
        if overlay == nil {
            guard !isDone else { return letGo() }
            guard goal > 0.001, let frost, let screen = NSScreen.builtIn else { return }
            overlay = LidOverlay(frost: frost, screen: screen, style: prefs.style)
        }
        // Fades in over a third of a second, however far the lid has already moved, and out
        // the same way.
        presence = isDone ? max(presence - step / 0.35, 0) : min(presence + step / 0.35, 1)
        let fadeIn = Self.smoothstep(presence)
        overlay?.setOpacity(Self.smoothstep(min(presence * 2, 1)))
        overlay?.setProgress(shown * fadeIn)
        // The overlay draws a live pointer; the real one hides once the overlay covers it, and
        // comes back before the overlay goes.
        if presence >= 1 { Pointer.hide() } else if isDone { Pointer.show() }

        if isDone, presence <= 0 {
            letGo()
        } else if target >= 1, shown > 0.995, presence >= 1, overlay?.isDark == true {
            shut()
        }
    }

    private static func smoothstep(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Shut. The Mac usually sleeps now; the screen stays dark until the lid opens.
    private func shut() {
        phase = .shut
        displayLink?.invalidate()
        displayLink = nil
        startPolling()
    }

    /// Back to watching, with the screen as it really is.
    private func letGo() {
        displayLink?.invalidate()
        displayLink = nil
        overlay?.close()
        overlay = nil
        frost = nil
        shown = 0
        shownVelocity = 0
        presence = 0
        phase = .idle
        Pointer.show()
        if script != nil {
            script = nil
            update()
            onPlayed?()
        }
        if isWatching { startPolling() } else { stopPolling() }
    }

    /// With the lid shut and a display plugged in, the built-in screen turns off; the glass
    /// mustn't be moved over to another screen.
    @objc private func screensChanged() {
        if let overlay, !NSScreen.screens.contains(overlay.screen) { letGo() }
    }
}

/// A make-believe lid: angles at seconds from `start`, eased from one to the next.
private struct LidScript {
    let keyframes: [(time: Double, angle: Double)]
    let start: TimeInterval

    /// Done, with time for the glass to fade away.
    func isFinished(at time: TimeInterval) -> Bool {
        time - start > (keyframes.last?.time ?? 0) + 1.5
    }

    func angle(at time: TimeInterval) -> Double {
        let t = time - start
        guard let first = keyframes.first, let last = keyframes.last else { return 120 }
        if t <= first.time { return first.angle }
        for (from, to) in zip(keyframes, keyframes.dropFirst()) where t <= to.time {
            let x = to.time > from.time ? (t - from.time) / (to.time - from.time) : 1
            return from.angle + (to.angle - from.angle) * x * x * (3 - 2 * x)
        }
        return last.angle
    }
}
