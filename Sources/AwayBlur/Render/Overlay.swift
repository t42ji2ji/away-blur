import AppKit
import QuartzCore

/// Borderless, above everything including the menu bar and full screen
/// spaces, never takes focus, never takes clicks.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class MetalHostView: NSView {
    init(layer metalLayer: CALayer, scale: CGFloat) {
        super.init(frame: .zero)
        metalLayer.contentsScale = scale
        self.layer = metalLayer
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Setting a layer's frame is an animatable change, and the first one
        // runs from a zero-sized layer to a full-screen one over a quarter of
        // a second: the overlay arrives and the whole picture scales up into
        // place. Nothing here should ever animate.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.frame = bounds
        CATransaction.commit()
    }
}

/// One screen's frozen picture and the window it is drawn in.
@MainActor
final class Overlay {
    let displayID: CGDirectDisplayID
    let window: OverlayWindow
    let layer: CAMetalLayer
    var picture: BlurRenderer.Picture?

    /// Over everything, including the menu bar.
    static let awayLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))

    init(screen: NSScreen, displayID: CGDirectDisplayID, renderer: BlurRenderer) {
        self.displayID = displayID
        let scale = screen.backingScaleFactor
        layer = renderer.makeLayer(scale: scale)
        layer.drawableSize = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)

        let view = MetalHostView(layer: layer, scale: scale)
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        view.autoresizingMask = [.width, .height]

        window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = Overlay.awayLevel
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.setFrame(screen.frame, display: false)
        // Nothing is drawn yet, and an empty overlay must not be visible even
        // for one frame.
        window.alphaValue = 0
        view.layoutSubtreeIfNeeded()
    }

    func show() {
        window.orderFrontRegardless()
    }

    /// Fades in the sharp copy over the real screen. The two are the same
    /// picture, so nothing is visible in the crossing — it only hides whatever
    /// discontinuity there is in the instant the overlay takes over.
    func reveal(over duration: TimeInterval = 0.08) {
        guard window.alphaValue < 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    func close() {
        window.orderOut(nil)
        window.close()
        picture = nil
    }
}
