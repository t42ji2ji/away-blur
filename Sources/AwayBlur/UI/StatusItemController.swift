import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let item: NSStatusItem
    private let preferences: Preferences
    private let controller: BlurController
    private let settings: SettingsPanel

    init(preferences: Preferences, controller: BlurController, settings: SettingsPanel) {
        self.preferences = preferences
        self.controller = controller
        self.settings = settings
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.image = StatusItemController.symbol()
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refreshIcon()
    }

    private static func symbol() -> NSImage? {
        for name in ["moon.haze.fill", "cloud.fog.fill", "circle.dotted"] {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Away Blur") { return image }
        }
        return nil
    }

    private func refreshIcon() {
        item.button?.alphaValue = preferences.isEnabled ? 1 : 0.4
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let now = NSMenuItem(title: "Blur now  \(Hotkey.describe(keyCode: preferences.hotkeyCode, modifiers: preferences.hotkeyModifiers))",
                             action: #selector(blurNow), keyEquivalent: "")
        now.target = self
        menu.addItem(now)
        menu.addItem(.separator())

        if controller.isShowing {
            let clear = NSMenuItem(title: "Clear the screen now", action: #selector(clearNow), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
            menu.addItem(.separator())
        }

        let enabled = NSMenuItem(title: "Blur when I'm away", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = preferences.isEnabled ? .on : .off
        menu.addItem(enabled)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Look", action: nil, keyEquivalent: ""))
        for look in Look.allCases {
            let entry = NSMenuItem(title: "  \(look.title)", action: #selector(pickLook(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = look.rawValue
            entry.state = preferences.look == look ? .on : .off
            menu.addItem(entry)
        }

        menu.addItem(.separator())
        let camera = NSMenuItem(title: "Check the camera before blurring",
                                action: #selector(toggleCamera), keyEquivalent: "")
        camera.target = self
        camera.state = preferences.usesCamera ? .on : .off
        menu.addItem(camera)
        if preferences.usesCamera, FaceCheck.isDenied {
            let denied = NSMenuItem(title: "  Camera access is off — open System Settings",
                                    action: #selector(openCameraSettings), keyEquivalent: "")
            denied.target = self
            menu.addItem(denied)
        }

        menu.addItem(.separator())
        let preview = NSMenuItem(title: "Preview the look now", action: #selector(togglePreview), keyEquivalent: "p")
        preview.target = self
        preview.state = controller.isPreviewing ? .on : .off
        menu.addItem(preview)

        let panel = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        panel.target = self
        menu.addItem(panel)

        if !controller.hasPermission {
            menu.addItem(.separator())
            let missing = NSMenuItem(title: "Screen Recording is off — open System Settings",
                                     action: #selector(openPrivacySettings), keyEquivalent: "")
            missing.target = self
            menu.addItem(missing)
        }

        if !controller.isWorking {
            menu.addItem(.separator())
            let broken = NSMenuItem(title: "Metal is unavailable — nothing will blur", action: nil, keyEquivalent: "")
            broken.isEnabled = false
            menu.addItem(broken)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Away Blur", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleEnabled() {
        preferences.isEnabled.toggle()
        refreshIcon()
    }

    @objc private func pickLook(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let look = Look(rawValue: raw) else { return }
        preferences.look = look
    }

    @objc private func togglePreview() {
        controller.isPreviewing.toggle()
    }

    @objc private func openSettings() {
        settings.show()
    }

    @objc private func blurNow() {
        controller.blurNow()
    }

    @objc private func clearNow() {
        controller.clear()
    }

    @objc private func toggleCamera() {
        if preferences.usesCamera {
            preferences.usesCamera = false
            return
        }
        Task {
            let granted = FaceCheck.isAuthorized ? true : await FaceCheck.requestAccess()
            preferences.usesCamera = granted
            if !granted { openCameraSettings() }
        }
    }

    @objc private func openCameraSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
        NSWorkspace.shared.open(url)
    }

    @objc private func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
