import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var preferences: Preferences!
    private var controller: BlurController!
    private var statusItem: StatusItemController!
    private var settings: SettingsPanel!
    private var hotkey: Hotkey?

    nonisolated override init() { super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences = Preferences()
        controller = BlurController(preferences: preferences)
        settings = SettingsPanel(preferences: preferences, controller: controller)
        statusItem = StatusItemController(preferences: preferences, controller: controller, settings: settings)
        controller.isTuning = { [weak settings] in settings?.isVisible ?? false }
        hotkey = Hotkey { [weak self] in self?.controller.blurNow() }
        if hotkey == nil { FileLog.write("could not register \(Hotkey.title)") }

        FileLog.write("launched, screen recording granted: \(ScreenSnapshot.hasPermission())")
        askForPermissionIfNeeded()
    }

    /// `awayblur://preview/on` and friends, so the look can be driven from a
    /// terminal instead of the menu while tuning.
    func application(_ application: NSApplication, open urls: [URL]) {
        FileLog.write("url: \(urls.map(\.absoluteString).joined(separator: ", "))")
        for url in urls where url.scheme == "awayblur" {
            let action = url.lastPathComponent
            switch (url.host, action) {
            case ("blur", _): controller.blurNow()
            case ("preview", "sharp"):
                controller.pinned = 0
                controller.isPreviewing = true
            case ("preview", "on"):
                controller.pinned = nil
                controller.isPreviewing = true
            case ("preview", "off"):
                controller.pinned = nil
                controller.isPreviewing = false
            case ("preview", "toggle"): controller.isPreviewing.toggle()
            case ("settings", _): settings.show()
            default: break
            }
        }
    }

    /// Raises the system prompt on a first run. It blocks until the person
    /// answers, so it cannot happen on the main thread.
    private func askForPermissionIfNeeded() {
        guard !ScreenSnapshot.hasPermission() else { return }
        Task.detached(priority: .utility) {
            let granted = ScreenSnapshot.requestPermission()
            FileLog.write("permission prompt answered: \(granted)")
        }
    }
}
