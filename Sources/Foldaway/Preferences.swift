import Foundation
import Observation

/// How the screen closes ahead of the lid.
enum LidStyle: Int, CaseIterable, Identifiable {
    case glass = 0
    case notch = 1
    case fold = 2
    // 3 was Blinds, removed; it falls back to Frosted glass.
    case lockScreen = 4
    case tv = 5

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .glass: "Frosted glass"
        case .notch: "Into the notch"
        case .fold: "Fold"
        case .lockScreen: "Lock screen"
        case .tv: "TV off"
        }
    }

    var detail: String {
        switch self {
        case .glass: "The screen turns to frosted glass and tips shut on the hinge."
        case .notch: "The screen draws itself up into the camera notch."
        case .fold: "A crease down the middle, and the halves fold toward each other."
        case .lockScreen: "The screen softens into your wallpaper with a big clock, like a phone locking."
        case .tv: "The picture squashes to a glowing line and shrinks to a dot, like an old TV."
        }
    }
}

@Observable @MainActor
final class Preferences {
    private enum Key {
        static let isEnabled = "isEnabled"
        static let unfoldOnOpen = "unfoldOnOpen"
        static let closeAngle = "closeAngle"
        static let startAngle = "startAngle"
        static let style = "lidStyle"
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
    /// The lid angle where the screen starts to close, in degrees; above it, adjusting the
    /// screen does nothing. At the top of the range, it starts as soon as the lid moves.
    var startAngle: Double {
        didSet { save(startAngle, Key.startAngle) }
    }
    static let startAngles = 30.0...130.0
    var startsRightAway: Bool { startAngle >= Self.startAngles.upperBound }
    var style: LidStyle {
        didSet { save(style.rawValue, Key.style) }
    }
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
            // Well below where anyone works with the screen, so tilting an open screen back
            // and forth never sets it off, and still 60° to close in.
            Key.startAngle: 70.0,
            Key.style: LidStyle.glass.rawValue,
            Key.showMenuBarIcon: true,
        ])
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        unfoldOnOpen = defaults.bool(forKey: Key.unfoldOnOpen)
        closeAngle = min(max(defaults.double(forKey: Key.closeAngle), Self.closeAngles.lowerBound),
                         Self.closeAngles.upperBound)
        startAngle = min(max(defaults.double(forKey: Key.startAngle), Self.startAngles.lowerBound),
                         Self.startAngles.upperBound)
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
        style = LidStyle(rawValue: defaults.integer(forKey: Key.style)) ?? .glass
    }

    /// A demo scene (`DemoScene`) changes settings on screen, but never saves them.
    private func save(_ value: Any, _ key: String) {
        guard DemoScene.current == nil else { return }
        defaults.set(value, forKey: key)
    }
}
