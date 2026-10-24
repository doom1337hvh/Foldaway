import Foundation
import Observation

@Observable @MainActor
final class Preferences {
    private enum Key {
        static let isEnabled = "isEnabled"
        static let unfoldOnOpen = "unfoldOnOpen"
        static let closeAngle = "closeAngle"
        static let showMenuBarIcon = "showMenuBarIcon"
    }

    @ObservationIgnored var onEnabledChange: (() -> Void)?
    @ObservationIgnored var onMenuBarIconChange: (() -> Void)?
    @ObservationIgnored private let defaults = UserDefaults.standard

    var isEnabled: Bool {
        didSet {
            save(isEnabled, Key.isEnabled)
            onEnabledChange?()
        }
    }
    /// Opening the lid swings the glass back open, rather than the screen just appearing.
    var unfoldOnOpen: Bool {
        didSet { save(unfoldOnOpen, Key.unfoldOnOpen) }
    }
    /// The lid angle by which the screen has closed, in degrees: low to close with the lid,
    /// higher to close well before it.
    var closeAngle: Double {
        didSet { save(closeAngle, Key.closeAngle) }
    }
    static let closeAngles = 5.0...45.0
    var showMenuBarIcon: Bool {
        didSet {
            save(showMenuBarIcon, Key.showMenuBarIcon)
            onMenuBarIconChange?()
        }
    }

    init() {
        defaults.register(defaults: [
            Key.isEnabled: true,
            Key.unfoldOnOpen: true,
            Key.closeAngle: 10.0,
            Key.showMenuBarIcon: true,
        ])
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        unfoldOnOpen = defaults.bool(forKey: Key.unfoldOnOpen)
        closeAngle = min(max(defaults.double(forKey: Key.closeAngle), Self.closeAngles.lowerBound),
                         Self.closeAngles.upperBound)
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
    }

    /// A demo scene (`DemoScene`) changes settings on screen, but never saves them.
    private func save(_ value: Any, _ key: String) {
        guard DemoScene.current == nil else { return }
        defaults.set(value, forKey: key)
    }
}
