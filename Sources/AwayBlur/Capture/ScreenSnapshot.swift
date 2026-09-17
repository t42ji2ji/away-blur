import AppKit
import CoreGraphics
import ScreenCaptureKit

/// One still of a display, at its own pixel size.
///
/// A live stream would cost 30 frames a second for a picture that is frozen
/// anyway; the screen is only ever captured at the moment it goes away.
enum ScreenSnapshot {

    static func capture(display id: CGDirectDisplayID) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
            // Our own windows must never end up in the picture: the settings
            // panel is on screen while you tune, and the overlay itself may
            // still be fading out.
            let ours = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])

            let configuration = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            configuration.width = Int(filter.contentRect.width * scale)
            configuration.height = Int(filter.contentRect.height * scale)
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = BlurRenderer.colourSpace
            configuration.captureResolution = .best
            configuration.showsCursor = false
            configuration.scalesToFit = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            FileLog.write("captured display \(id): \(image.width)x\(image.height)")
            return image
        } catch {
            FileLog.write("capture failed on display \(id): \(error)")
            return nil
        }
    }

    /// Whether Screen Recording has been granted, without asking for it.
    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Raises the system prompt, once, the first time it is called.
    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
