import AppKit
import CoreGraphics
import Foundation

/// The app icon, and the little cat in the menu bar.
///
/// The icon is a frame of the app rather than a picture of it: a few coloured
/// shapes put through the same blur the screen gets, with the same cat left
/// sharp on top. Whatever the frost looks like, the icon looks like that.
enum Icon {

    /// Apple's icon grid: the shape is 824 of 1024 across, cornered at 185.
    private static let inset = 100.0 / 1024
    private static let corner = 185.0 / 1024

    /// Something with a bit of structure to it. Blurred, a linear gradient is
    /// just a gradient; overlapping fields keep some weather in the colour.
    private static func field(size: Int) -> CGImage? {
        guard let space = CGColorSpace(name: BlurRenderer.colourSpace),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let side = Double(size)
        context.setFillColor(CGColor(red: 0.13, green: 0.15, blue: 0.24, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let blobs: [(x: Double, y: Double, r: Double, colour: CGColor)] = [
            (0.22, 0.78, 0.42, CGColor(red: 0.42, green: 0.55, blue: 0.95, alpha: 1)),
            (0.82, 0.70, 0.36, CGColor(red: 0.95, green: 0.62, blue: 0.48, alpha: 1)),
            (0.68, 0.20, 0.44, CGColor(red: 0.36, green: 0.72, blue: 0.70, alpha: 1)),
            (0.16, 0.18, 0.30, CGColor(red: 0.85, green: 0.42, blue: 0.62, alpha: 1)),
        ]
        for blob in blobs {
            context.setFillColor(blob.colour)
            context.fillEllipse(in: CGRect(x: (blob.x - blob.r) * side, y: (blob.y - blob.r) * side,
                                           width: blob.r * 2 * side, height: blob.r * 2 * side))
        }
        return context.makeImage()
    }

    static func render(_ renderer: BlurRenderer, size: Int) -> CGImage? {
        guard let source = field(size: size),
              let picture = renderer.makePicture(from: source),
              let stamp = renderer.makeStamp(face: Cat.face(named: "(･ω･)")) else { return nil }

        let side = Double(size)
        let cell = max(1, (side * 0.42 / Double(Cat.body.height)).rounded())
        let span = CGSize(width: Double(Cat.body.width) * cell, height: Double(Cat.body.height) * cell)
        let placed = BlurRenderer.Stamp(
            texture: stamp,
            origin: CGPoint(x: ((side - span.width) / 2).rounded(),
                            y: ((side - span.height) / 2).rounded()),
            cell: cell, alpha: 1)
        guard let frosted = renderer.renderToImage(
            picture: picture, size: CGSize(width: size, height: size),
            look: FrameLook(blur: 1, dim: 0.10, wash: 0.18, grain: 0),
            maxRadius: side * 0.09, stamp: placed) else { return nil }

        // Mask to the shape macOS expects; nothing masks it for you.
        guard let space = CGColorSpace(name: BlurRenderer.colourSpace),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let shape = CGRect(x: inset * side, y: inset * side,
                           width: side * (1 - 2 * inset), height: side * (1 - 2 * inset))
        let path = CGPath(roundedRect: shape, cornerWidth: corner * side, cornerHeight: corner * side,
                          transform: nil)
        context.addPath(path)
        context.clip()
        context.draw(frosted, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    /// The menu bar cat: a template image, so the system colours it.
    static func menuBar(cell: Int = 2) -> NSImage? {
        let bytes = Cat.stamp(face: Cat.face(named: "(･ω･)"))
        let columns = Cat.body.width, rows = Cat.body.height
        let width = columns * cell, height = rows * cell
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for row in 0..<rows {
            for column in 0..<columns where bytes[row * columns + column] > 0 {
                context.fill(CGRect(x: column * cell, y: (rows - 1 - row) * cell,
                                    width: cell, height: cell))
            }
        }
        guard let image = context.makeImage() else { return nil }
        let made = NSImage(cgImage: image, size: NSSize(width: width / cell, height: height / cell))
        made.isTemplate = true
        return made
    }
}
