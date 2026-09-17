import AppKit
import Combine
import Metal
import QuartzCore

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// Decides when the screen goes away, and drives the ramp when it does.
@MainActor
final class BlurController {

    private enum Phase { case hidden, rising, held, falling }

    private let preferences: Preferences
    private let renderer: BlurRenderer?

    private var overlays: [Overlay] = []
    private var phase: Phase = .hidden
    private var progress: Double = 0
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var poll: Timer?
    private var isCapturing = false
    /// Set after a failed capture so a missing permission cannot turn into a
    /// few hundred ScreenCaptureKit calls a minute.
    private var retryAfter: CFTimeInterval = 0
    private var permission = (checked: CFTimeInterval(0), granted: false)
    private var watchers: [Any] = []
    private var cancellables: Set<AnyCancellable> = []

    /// Holds the blur up regardless of whether anyone is typing, so the look
    /// can be tuned while looking at it.
    var isPreviewing = false {
        didSet { if isPreviewing != oldValue { decide() } }
    }

    var isShowing: Bool { phase != .hidden }
    var isWorking: Bool { renderer != nil }

    init(preferences: Preferences) {
        self.preferences = preferences
        self.renderer = BlurRenderer()
        watch()
        schedulePoll(interval: 0.25)
    }

    // MARK: - Deciding

    private func schedulePoll(interval: TimeInterval) {
        poll?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.decide() }
        }
        timer.tolerance = interval * 0.4
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    /// Cached, because this is asked several times a second.
    var hasPermission: Bool {
        let now = CACurrentMediaTime()
        if now - permission.checked > 3 {
            permission = (now, ScreenSnapshot.hasPermission())
        }
        return permission.granted
    }

    private func shouldShow() -> Bool {
        let idle = Presence.idleSeconds()
        if isShowing {
            // Once it is up, only a hand on the keyboard or mouse takes it down.
            return isPreviewing || idle >= 0.4
        }
        guard hasPermission, CACurrentMediaTime() >= retryAfter else { return false }
        if isPreviewing { return true }
        guard preferences.isEnabled, !Presence.displayHeldAwake() else { return false }
        return idle >= preferences.current.idleDelay
    }

    private func decide() {
        let wanted = shouldShow()
        switch (wanted, phase) {
        case (true, .hidden):
            beginShowing()
        case (true, .falling):
            phase = .rising
            startLink()
        case (false, .rising), (false, .held):
            phase = .falling
            startLink()
        default:
            break
        }
    }

    // MARK: - Putting it up

    private func beginShowing() {
        guard !isCapturing else { return }
        guard let renderer else { FileLog.write("no renderer: Metal is unavailable"); return }
        isCapturing = true
        let screens = NSScreen.screens.compactMap { screen -> (NSScreen, CGDirectDisplayID)? in
            guard let id = screen.displayID else { return nil }
            return (screen, id)
        }
        guard !screens.isEmpty else { isCapturing = false; return }

        Task { [weak self] in
            var pictures: [CGDirectDisplayID: MTLTexture] = [:]
            for (_, id) in screens {
                guard let image = await ScreenSnapshot.capture(display: id) else { continue }
                let made: MTLTexture? = await Task.detached(priority: .userInitiated) {
                    renderer.makePicture(from: image)
                }.value
                if let made { pictures[id] = made }
            }
            guard let self else { return }
            self.isCapturing = false
            if pictures.isEmpty {
                // Almost always a missing permission. Back off rather than
                // hammer ScreenCaptureKit.
                self.retryAfter = CACurrentMediaTime() + 10
                FileLog.write("no picture captured; not trying again for 10s")
                return
            }
            // A hand came back while we were capturing.
            guard self.shouldShow(), self.phase == .hidden else { return }
            self.present(screens: screens, pictures: pictures)
        }
    }

    private func present(screens: [(NSScreen, CGDirectDisplayID)], pictures: [CGDirectDisplayID: MTLTexture]) {
        guard let renderer else { return }
        for (screen, id) in screens {
            guard let picture = pictures[id] else { continue }
            let overlay = Overlay(screen: screen, displayID: id, renderer: renderer)
            overlay.picture = picture
            overlays.append(overlay)
        }
        FileLog.write("presenting \(overlays.count) overlay(s)")
        guard !overlays.isEmpty else { return }
        progress = 0
        phase = .rising
        drawFrame()
        overlays.forEach { $0.show() }
        schedulePoll(interval: 0.06)
        startLink()
    }

    // MARK: - The ramp

    private func startLink() {
        guard link == nil, let screen = NSScreen.main else { return }
        lastTick = 0
        let created = screen.displayLink(target: self, selector: #selector(tick))
        created.add(to: .main, forMode: .common)
        link = created
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let delta = lastTick == 0 ? 1.0 / 60 : min(now - lastTick, 0.1)
        lastTick = now
        let settings = preferences.current

        switch phase {
        case .rising:
            progress = min(1, progress + delta / max(settings.fadeIn, 0.02))
            if progress >= 1 { phase = .held }
        case .falling:
            progress = max(0, progress - delta / max(settings.fadeOut, 0.02))
            if progress <= 0 {
                finishHiding()
                return
            }
        case .hidden, .held:
            break
        }

        drawFrame()

        // Nothing moves while it is held, so stop asking the display for frames.
        if phase == .held { stopLink() }
    }

    private func drawFrame() {
        guard let renderer else { return }
        let settings = preferences.current
        let look = FrameLook(settings: settings, progress: progress)
        for overlay in overlays {
            guard let picture = overlay.picture else { continue }
            renderer.render(picture: picture, into: overlay.layer, look: look,
                            maxRadius: settings.blurRadius, time: 0)
        }
    }

    private func finishHiding() {
        stopLink()
        overlays.forEach { $0.close() }
        overlays.removeAll()
        phase = .hidden
        progress = 0
        schedulePoll(interval: 0.25)
    }

    /// Takes it down with no animation: the display is going dark anyway.
    private func hideNow() {
        guard isShowing else { return }
        finishHiding()
    }

    // MARK: - Live tuning

    /// Redraws the held frame after a slider moves.
    func settingsChanged() {
        guard isShowing else { return }
        if phase == .held { drawFrame() } else { startLink() }
    }

    // MARK: - System

    private func watch() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            watchers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideNow() }
            })
        }
        watchers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideNow() }
            })
        watchers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideNow() }
            })

        preferences.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.settingsChanged() }
            .store(in: &cancellables)
    }
}
