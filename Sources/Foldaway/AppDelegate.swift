import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let prefs = Preferences()
    private let permissions = Permissions()
    private lazy var lid = LidWatcher(prefs: prefs)
    private lazy var settings = SettingsWindowController(prefs: prefs, permissions: permissions, lid: lid)
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        // Prints what macOS reports, for troubleshooting:
        //   open -n -W --stdout /dev/stdout /Applications/Foldaway.app --args --check
        if arguments.contains("--check") {
            print("Screen Recording: \(CGPreflightScreenCaptureAccess() ? "allowed" : "not allowed")")
            print("Lid angle: \(LidSensor()?.read().map { "\(Int($0))°" } ?? "no sensor")")
            exit(0)
        }
        // Closes and opens the screen once, then quits: for checking the effect and recording
        // clips. The number is how long the make-believe lid takes to shut, in seconds.
        //   open -n Foldaway.app --args --play 1.2
        if let index = arguments.firstIndex(of: "--play") {
            lid.onPlayed = { NSApp.terminate(nil) }
            lid.play(closing: arguments.dropFirst(index + 1).first.flatMap(Double.init) ?? 1.2)
            return
        }
        // A scene for the README's clips (see DemoScene).
        if let demo = DemoScene.current {
            demo.run(lid: lid, settings: settings, prefs: prefs)
            return
        }
        // Opened straight from Downloads, macOS runs a temporary copy of the app, and the
        // permission given to that copy doesn't stick.
        if Bundle.main.bundlePath.contains("/AppTranslocation/") {
            let alert = NSAlert()
            alert.messageText = "Move Foldaway to Applications"
            alert.informativeText = "macOS runs apps opened straight from Downloads from a temporary copy, and the permission Foldaway needs wouldn't stick to it. Drag Foldaway into your Applications folder, then open it from there."
            alert.addButton(withTitle: "Quit")
            NSApp.activate()
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        prefs.onEnabledChange = { [weak self] in self?.updateWatching() }
        prefs.onMenuBarIconChange = { [weak self] in self?.updateStatusItem() }
        updateStatusItem()
        updateWatching()
        if !permissions.screenRecording || !lid.hasSensor {
            permissions.watchUntilGranted()
            settings.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Brings the pointer back if the glass is up.
        lid.stop()
    }

    /// Opening Foldaway again while it runs shows Settings, even with the menu bar icon hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return false
    }

    private func updateWatching() {
        lid.update()
        statusItem?.button?.appearsDisabled = !prefs.isEnabled
    }

    private func updateStatusItem() {
        if prefs.showMenuBarIcon, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = Self.menuBarImage
            item.button?.appearsDisabled = !prefs.isEnabled
            let menu = NSMenu()
            // Rebuilt each time it opens, so it's up to date.
            menu.delegate = self
            item.menu = menu
            statusItem = item
        } else if !prefs.showMenuBarIcon, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        permissions.refresh()
        menu.removeAllItems()
        if !permissions.screenRecording {
            let warning = NSMenuItem(title: "Allow Screen Recording…", action: #selector(showSettings), keyEquivalent: "")
            warning.target = self
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(warning)
            menu.addItem(.separator())
        }
        let toggle = NSMenuItem(title: "Close the Screen with the Lid", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = prefs.isEnabled ? .on : .off
        menu.addItem(toggle)
        let style = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        let styles = NSMenu()
        for option in LidStyle.allCases {
            let item = NSMenuItem(title: option.label, action: #selector(pickStyle(_:)), keyEquivalent: "")
            item.target = self
            item.tag = option.rawValue
            item.state = prefs.style == option ? .on : .off
            styles.addItem(item)
        }
        style.submenu = styles
        menu.addItem(style)
        let play = NSMenuItem(title: "Play It Now", action: #selector(playNow), keyEquivalent: "")
        play.target = self
        menu.addItem(play)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Foldaway", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
    }

    @objc private func toggleEnabled() {
        prefs.isEnabled.toggle()
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        prefs.style = LidStyle(rawValue: sender.tag) ?? .glass
    }

    @objc private func playNow() {
        // Once the menu has closed, so it isn't in the picture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.lid.play()
        }
    }

    @objc private func showSettings() {
        settings.show()
    }

    private static let menuBarImage: NSImage? = {
        let image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "Foldaway")
        image?.isTemplate = true
        return image
    }()
}
