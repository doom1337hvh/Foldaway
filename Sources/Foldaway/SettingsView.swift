import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// The "Launch at login" switch. A class rather than `@State`, because the Command Line Tools
/// don't ship the plugin for SwiftUI's `@State` macro.
@Observable @MainActor
final class LoginItem {
    private(set) var status = SMAppService.mainApp.status
    private(set) var error: String?

    var isEnabled: Bool {
        get { status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            status = SMAppService.mainApp.status
        }
    }
}

/// Creates the Settings window when it's opened and releases it when it's closed.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let prefs: Preferences
    private let permissions: Permissions
    private let lid: LidWatcher
    private var window: NSWindow?

    init(prefs: Preferences, permissions: Permissions, lid: LidWatcher) {
        self.prefs = prefs
        self.permissions = permissions
        self.lid = lid
    }

    func show() {
        if window == nil {
            let view = SettingsView(prefs: prefs, permissions: permissions, reading: lid.reading,
                                    hasSensor: lid.hasSensor, loginItem: LoginItem(),
                                    play: { [weak lid] in lid?.play() })
            let host = NSHostingController(rootView: view)
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "Foldaway Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        permissions.refresh()
    }
}

private struct SettingsView: View {
    @Bindable var prefs: Preferences
    var permissions: Permissions
    var reading: LidReading
    let hasSensor: Bool
    @Bindable var loginItem: LoginItem
    let play: () -> Void

    var body: some View {
        Form {
            if !permissions.screenRecording {
                Section {
                    LabeledContent {
                        Button("Allow…", action: permissions.requestScreenRecording)
                    } label: {
                        Text("Screen Recording")
                        Text("To take a picture of the screen as the lid starts to close, to make the glass from. Nothing is saved or sent anywhere.")
                    }
                } header: {
                    Text("Permission")
                } footer: {
                    Text("After allowing it, macOS may ask you to quit and reopen Foldaway.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if hasSensor {
                    Toggle(isOn: $prefs.isEnabled) {
                        Text("Close the screen with the lid")
                        Text("As you close the lid, the screen closes ahead of it, in the style below.")
                    }
                    Picker(selection: $prefs.style) {
                        ForEach(LidStyle.allCases) { Text($0.label).tag($0) }
                    } label: {
                        Text("Style")
                        Text(prefs.style.detail)
                    }
                    LabeledContent {
                        HStack {
                            Slider(value: $prefs.closeAngle, in: Preferences.closeAngles, step: 1)
                                .frame(width: 150)
                            Text("\(Int(prefs.closeAngle))°")
                                .monospacedDigit()
                                .frame(width: 32, alignment: .trailing)
                        }
                    } label: {
                        Text("Screen is shut by")
                        Text("The lid angle where the screen has closed. Lower closes it with the lid; higher, well before it.")
                    }
                    Toggle(isOn: $prefs.unfoldOnOpen) {
                        Text("Open it with the lid too")
                        Text("When off, the screen just appears as you open the lid.")
                    }
                    LabeledContent {
                        Button("Play It Now", action: play)
                            .disabled(!permissions.screenRecording)
                    } label: {
                        Text("Try it")
                        Text("Closes and opens the screen without touching the lid.")
                    }
                    LabeledContent("Lid angle") {
                        Text(reading.angle.map { "\(Int($0))°" } ?? "–")
                            .monospacedDigit()
                    }
                } else {
                    Text("This Mac doesn't report its lid angle, so Foldaway can't follow the lid. It needs a MacBook with a lid angle sensor.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Lid")
            }

            Section {
                Toggle(isOn: $loginItem.isEnabled) {
                    Text("Launch at login")
                    Text("Foldaway only works while it's running.")
                }
                if loginItem.status == .requiresApproval {
                    LabeledContent("Needs your approval in System Settings.") {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    .foregroundStyle(.secondary)
                }
                if let error = loginItem.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Toggle(isOn: $prefs.showMenuBarIcon) {
                    Text("Show menu bar icon")
                    if !prefs.showMenuBarIcon {
                        Text("To get back here, open Foldaway again.")
                    }
                }
            } footer: {
                HStack {
                    Text("Foldaway \(Self.version)")
                    Spacer()
                    Link("GitHub", destination: URL(string: "https://github.com/doom1337hvh/Foldaway")!)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}
