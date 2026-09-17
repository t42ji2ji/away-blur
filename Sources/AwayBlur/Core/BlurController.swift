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
    private let camera = FaceCheck()
    private var stamp: MTLTexture?
    private var blinkStamp: MTLTexture?
    private var blinkAgainAt: CFTimeInterval = 0
    private var blinkingUntil: CFTimeInterval = 0
    private var caption: MTLTexture?
    private var captionText = ""
    private var captionLines: [String] = []
    private var captionTurn = 0
    private var captionSince: CFTimeInterval = 0
    private var awaySince: CFTimeInterval = 0
    private var lastWaiting: String?

    /// A shake, in cat pixels, decaying on k squared so it starts hard and
    /// settles rather than rattling evenly to the end. The offset is rounded
    /// to whole screen pixels per display — a fraction of a pixel here and the
    /// art goes soft for as long as it lasts.
    private var shakeUntil: CFTimeInterval = 0
    private var shakeOver: CFTimeInterval = 0.5
    private var shakeCells: Double = 0
    private var shakeOffset = CGPoint.zero
    private var twitchAt: CFTimeInterval = 0

    private func shake(_ cells: Double, over duration: CFTimeInterval) {
        shakeCells = cells
        shakeOver = duration
        shakeUntil = CACurrentMediaTime() + duration
    }

    private func updateShake() {
        let now = CACurrentMediaTime()
        if now >= twitchAt {
            if twitchAt != 0 { shake(0.7, over: 0.28) }
            twitchAt = now + Double.random(in: 18...45)
        }
        guard now < shakeUntil else {
            shakeOffset = .zero
            return
        }
        let remaining = (shakeUntil - now) / shakeOver
        let amplitude = shakeCells * remaining * remaining
        shakeOffset = CGPoint(x: Double.random(in: -1...1) * amplitude,
                              y: Double.random(in: -1...1) * amplitude)
    }

    /// A line arrives letter by letter, sits long enough to read twice, then
    /// is eaten from the right.
    private static let arriving: CFTimeInterval = 0.65
    private static let holding: CFTimeInterval = 5.2
    private static let leaving: CFTimeInterval = 0.45
    private(set) var lastFaceSeen: CFTimeInterval = 0
    private var watchers: [Any] = []
    private var cancellables: Set<AnyCancellable> = []

    /// Long enough to take your hand off the keyboard after asking for a
    /// preview, before the same keyboard is what takes it away again.
    private static let previewGrace: CFTimeInterval = 1.5
    /// Longer than a preview's: whoever asked for this may be getting up.
    private static let blurNowGrace: CFTimeInterval = 4

    /// True while the settings panel is up. That is the one case where the
    /// blur may ignore the keyboard: you are dragging sliders, the panel
    /// floats above the overlay, and its toggle is right there.
    var isTuning: () -> Bool = { false }

    /// Holds the blur up regardless of whether anyone is typing, so the look
    /// can be tuned while looking at it.
    var isPreviewing = false {
        didSet {
            guard isPreviewing != oldValue else { return }
            previewStarted = isPreviewing ? CACurrentMediaTime() : 0
            if !isPreviewing { grace = BlurController.previewGrace }
            decide()
        }
    }

    private var previewStarted: CFTimeInterval = 0

    /// Holds the ramp at one value, for looking at a single frame of it.
    var pinned: Double? {
        didSet { if isShowing { drawFrame() } }
    }

    private var grace: CFTimeInterval = BlurController.previewGrace

    private var withinPreviewGrace: Bool {
        CACurrentMediaTime() - previewStarted <= grace
    }

    /// Takes the screen now, without waiting out the idle clock. It behaves
    /// like the real thing from there: a hand on the keyboard takes it back.
    func blurNow() {
        guard hasPermission else { return }
        if isShowing, !isPreviewing { return }
        grace = BlurController.blurNowGrace
        pinned = nil
        isPreviewing = true
    }

    /// Takes the screen back, whatever put it away.
    func clear() {
        isPreviewing = false
        guard isShowing else { return }
        phase = .falling
        startLink()
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
            // A preview holds while the settings panel is open, and for its
            // first moment either way. Both have to agree with the rule in
            // `decide()` that ends a preview, or the two take turns and the
            // overlay flickers.
            if isPreviewing, isTuning() || withinPreviewGrace { return true }
            // Otherwise a hand on the keyboard or mouse takes it down.
            return idle >= 0.4
        }
        guard hasPermission, CACurrentMediaTime() >= retryAfter else { return false }
        if isPreviewing { return true }
        guard preferences.isEnabled, !Presence.displayHeldAwake() else { return false }
        return idle >= preferences.idleDelay
    }

    private func decide() {
        // A preview is not a mode you can get stuck in: touch anything and it
        // is over, the same as the real thing.
        if isPreviewing, !isTuning(), !withinPreviewGrace, Presence.idleSeconds() < 0.4 {
            isPreviewing = false
        }
        // Going away is not reversible. Whatever started the fade — a hand on
        // the keyboard, the menu, a preview ending — has already been decided,
        // and standing still for half a second in the middle of a long fade
        // should not drag the screen back up.
        guard phase != .falling else { return }
        let wanted = shouldShow()
        switch (wanted, phase) {
        case (true, .hidden):
            beginShowing()
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
            // The idle clock has run out; before taking the screen, see whether
            // anyone is actually sitting there. A face only ever holds the blur
            // back — never causes it — so every failure here reads as nobody.
            if let self, self.preferences.usesCamera, !self.isPreviewing,
               CACurrentMediaTime() - self.lastFaceSeen > self.preferences.cameraRecheck {
                let seen = await self.camera.look()
                self.lastFaceSeen = seen ? CACurrentMediaTime() : 0
                if seen {
                    self.retryAfter = CACurrentMediaTime() + self.preferences.cameraRecheck
                    self.isCapturing = false
                    FileLog.write("camera saw a face; not asking again for \(Int(self.preferences.cameraRecheck))s")
                    return
                }
                FileLog.write("camera saw nobody")
            }
            var pictures: [CGDirectDisplayID: BlurRenderer.Picture] = [:]
            for (_, id) in screens {
                guard let image = await ScreenSnapshot.capture(display: id) else { continue }
                if UserDefaults.standard.bool(forKey: "dumpCaptures") {
                    _ = Offscreen.write(image, to: FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Logs/AwayBlur-frozen-\(id).png"))
                }
                let made: BlurRenderer.Picture? = await Task.detached(priority: .userInitiated) {
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

    private func present(screens: [(NSScreen, CGDirectDisplayID)], pictures: [CGDirectDisplayID: BlurRenderer.Picture]) {
        guard let renderer else { return }
        for (screen, id) in screens {
            guard let picture = pictures[id] else { continue }
            let overlay = Overlay(screen: screen, displayID: id, renderer: renderer)
            overlay.picture = picture
            overlays.append(overlay)
        }
        for overlay in overlays {
            FileLog.write("display \(overlay.displayID): window \(overlay.window.frame.size), layer bounds \(overlay.layer.bounds.size), drawable \(overlay.layer.drawableSize), scale \(overlay.layer.contentsScale)")
        }
        FileLog.write("presenting \(overlays.count) overlay(s)")
        guard !overlays.isEmpty else { return }
        awaySince = CACurrentMediaTime()
        twitchAt = 0
        shakeUntil = 0
        lastWaiting = nil
        captionSince = 0
        captionTurn = 0
        captionLines = []
        let face = chosenFace()
        stamp = renderer.makeStamp(face: face)
        blinkStamp = renderer.makeStamp(face: face, blinking: true)
        blinkAgainAt = 0
        progress = 0
        // Held, not rising: the ramp only starts once the sharp copy is up.
        phase = .held
        drawFrame(revealing: true)
        overlays.forEach { $0.show() }
        schedulePoll(interval: 0.06)
    }

    // MARK: - The ramp

    private func startLink() {
        if let link {
            link.preferredFrameRateRange = .default
            return
        }
        guard let screen = NSScreen.main else { return }
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
        if pinned != nil, phase == .rising { phase = .held }

        drawFrame()

        // Nothing moves while it is held except the cat, and a cat drifting
        // up and down does not need every frame the display can give.
        if phase == .held {
            if preferences.showsCat || preferences.showsCaption {
                link?.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            } else {
                stopLink()
            }
        }
    }

    /// The face for this run. Random means a different one each time the
    /// screen goes, which is the only place the choice is ever made.
    private func chosenFace() -> Face {
        preferences.catFace == "random"
            ? (Cat.faces.randomElement() ?? Cat.faces[0])
            : Cat.face(named: preferences.catFace)
    }

    /// Whole pixels per cell, whole pixels of travel, centred. Fractions of a
    /// pixel anywhere here and the art goes soft.
    /// Cats blink often and briefly, and not on a metronome.
    private func updateBlink() {
        let now = CACurrentMediaTime()
        guard now >= blinkAgainAt else { return }
        blinkingUntil = now + 0.13
        blinkAgainAt = now + Double.random(in: 2.4...6.5)
    }

    /// Picks the line and how much of it is showing, once per frame.
    private func updateCaption() {
        guard preferences.showsCaption, let renderer else { return }
        let now = CACurrentMediaTime()
        let cycle = BlurController.arriving + BlurController.holding + BlurController.leaving
        if captionSince == 0 || now - captionSince > cycle {
            if captionSince != 0 { captionTurn += 1 }
            captionSince = now
            captionLines = Caption.lines(awayFor: now - awaySince,
                                         includingWork: preferences.look == .ambient)
            // Something over there started waiting on you while you were gone.
            // The shake is the part you notice from across a room; the line
            // only tells you which one once you have looked.
            let waiting = preferences.look == .ambient ? Sessions.waiting() : nil
            if let waiting, waiting != lastWaiting { shake(2.2, over: 0.8) }
            lastWaiting = waiting
        }
        guard !captionLines.isEmpty else { return }
        let line = captionLines[captionTurn % captionLines.count]
        let elapsed = now - captionSince

        let shown: String
        if elapsed < BlurController.arriving {
            shown = Caption.scrambled(line, progress: elapsed / BlurController.arriving,
                                      seed: Int(now * 14))
        } else if elapsed < BlurController.arriving + BlurController.holding {
            shown = line
        } else {
            shown = Caption.erased(line, progress: (elapsed - BlurController.arriving
                                                    - BlurController.holding) / BlurController.leaving)
        }
        guard shown != captionText else { return }
        captionText = shown
        caption = shown.isEmpty ? nil : renderer.makeCaption(shown)
    }

    private func captionPlacement(on overlay: Overlay, progress: Double) -> BlurRenderer.Stamp? {
        guard preferences.showsCaption, let caption else { return nil }
        let size = overlay.layer.drawableSize
        let catCell = (size.height * preferences.catSize / Double(Cat.body.height)).rounded(.down)
        let cell = max(2, (catCell * 0.45).rounded())
        let span = CGSize(width: Double(caption.width) * cell, height: Double(caption.height) * cell)
        let catBottom = preferences.showsCat
            ? (size.height + Double(Cat.body.height) * max(2, catCell)) / 2
            : size.height / 2
        return BlurRenderer.Stamp(
            texture: caption,
            origin: CGPoint(x: ((size.width - span.width) / 2).rounded(),
                            y: (catBottom + catCell * 2.6).rounded()),
            cell: cell,
            alpha: ease(progress))
    }

    private func ease(_ progress: Double) -> Double {
        let value = min(max((progress - 0.3) / 0.5, 0), 1)
        return value * value * (3 - 2 * value)
    }

    private func placement(on overlay: Overlay, progress: Double) -> BlurRenderer.Stamp? {
        guard preferences.showsCat, let stamp else { return nil }
        let shut = CACurrentMediaTime() < blinkingUntil
        let texture = (shut ? blinkStamp : stamp) ?? stamp
        let size = overlay.layer.drawableSize
        let columns = Double(stamp.width), rows = Double(stamp.height)
        let cell = max(2, (size.height * preferences.catSize / rows).rounded(.down))
        let span = CGSize(width: columns * cell, height: rows * cell)
        let float = (sin(CACurrentMediaTime() * 2 * .pi / 2.6) * cell * 1.5).rounded()
        let shakeX = (shakeOffset.x * cell).rounded()
        let shakeY = (shakeOffset.y * cell).rounded()
        return BlurRenderer.Stamp(
            texture: texture,
            origin: CGPoint(x: ((size.width - span.width) / 2 + shakeX).rounded(),
                            y: ((size.height - span.height) / 2 + float + shakeY).rounded()),
            cell: cell,
            alpha: ease(progress))
    }

    private func drawFrame(revealing: Bool = false) {
        guard let renderer else { return }
        let settings = preferences.current
        let shown = pinned ?? progress
        let look = FrameLook(settings: settings, progress: shown)
        if preferences.showsCat {
            updateBlink()
            updateShake()
        }
        updateCaption()
        for overlay in overlays {
            guard let picture = overlay.picture else { continue }
            var arrived: (@Sendable () -> Void)?
            if revealing {
                arrived = { [weak self] in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.revealed() }
                    }
                }
            }
            renderer.render(picture: picture, into: overlay.layer, look: look,
                            maxRadius: settings.blurRadius, time: 0,
                            stamp: placement(on: overlay, progress: shown),
                            caption: captionPlacement(on: overlay, progress: shown),
                            onScreen: arrived)
        }
    }

    /// The first frame is on screen. Fade the overlay in, then start the ramp.
    private func revealed() {
        guard phase == .held, progress == 0 else { return }
        overlays.forEach { $0.reveal() }
        guard pinned == nil else { return }
        phase = .rising
        startLink()
    }

    private func finishHiding() {
        stopLink()
        overlays.forEach { $0.close() }
        overlays.removeAll()
        stamp = nil
        blinkStamp = nil
        caption = nil
        captionText = ""
        captionSince = 0
        phase = .hidden
        progress = 0
        // A preview never outlives its own overlay. Anything that takes the
        // screen back has to end the preview too, or it comes right back.
        isPreviewing = false
        // Never come straight back: a blur that reappears faster than a hand
        // can reach the menu bar is a trap.
        retryAfter = max(retryAfter, CACurrentMediaTime() + 1)
        schedulePoll(interval: 0.25)
    }

    /// Takes it down with no animation, and gives up any preview with it.
    ///
    /// Everything that calls this is the system saying something changed under
    /// us. Holding a preview through that is how the overlay came straight
    /// back up a moment later, over and over, with no way to reach the menu.
    private func hideNow() {
        isPreviewing = false
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
