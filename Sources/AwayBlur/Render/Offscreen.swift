import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Renders the look into a file instead of onto the screen.
///
/// Both for measuring — a blur must not move the picture, and the only way to
/// know is to render a known pattern and find it again — and for trying a look
/// without covering the screen to do it.
enum Offscreen {

    /// A black field with one white dot. One mark and no neighbours means the
    /// centre of mass over the whole frame is the mark, however wide it spreads.
    static func oneDot(width: Int, height: Int, at fraction: CGPoint) -> CGImage? {
        guard let space = CGColorSpace(name: BlurRenderer.colourSpace),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Wide and soft on purpose: anything smaller than a texel of the mip
        // level being sampled snaps to that level's grid, and what you measure
        // is the snapping, not the blur.
        let radius = 250.0
        let x = Double(width) * fraction.x
        let y = Double(height) * fraction.y
        guard let gradient = CGGradient(colorsSpace: space,
                                        colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                                                 CGColor(red: 0, green: 0, blue: 0, alpha: 1)] as CFArray,
                                        locations: [0, 1]) else { return nil }
        context.drawRadialGradient(gradient, startCenter: CGPoint(x: x, y: y), startRadius: 0,
                                   endCenter: CGPoint(x: x, y: y), endRadius: radius,
                                   options: [])
        return context.makeImage()
    }

    /// A black field with white dots on a known grid, plus a fine grid of
    /// lines. Any drift shows up as the dots leaving their marks.
    static func testPattern(width: Int, height: Int, step: Int = 8) -> CGImage? {
        guard let space = CGColorSpace(name: BlurRenderer.colourSpace),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let radius = 6.0
        for row in 1..<step {
            for column in 1..<step {
                let x = Double(width) * Double(column) / Double(step)
                let y = Double(height) * Double(row) / Double(step)
                context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            }
        }
        return context.makeImage()
    }

    /// The centre of mass of the brightness in one region, in pixels.
    static func centroid(of image: CGImage, in rect: CGRect) -> CGPoint? {
        let width = image.width
        let height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var sum = 0.0, sumX = 0.0, sumY = 0.0
        for y in Int(rect.minY)..<min(Int(rect.maxY), height) {
            for x in Int(rect.minX)..<min(Int(rect.maxX), width) {
                let offset = (y * width + x) * 4
                let weight = Double(pixels[offset]) + Double(pixels[offset + 1]) + Double(pixels[offset + 2])
                sum += weight
                sumX += weight * Double(x)
                sumY += weight * Double(y)
            }
        }
        guard sum > 0 else { return nil }
        return CGPoint(x: sumX / sum, y: sumY / sum)
    }

    static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}

extension BlurRenderer {

    /// One pass into a texture we can read back, with no window involved.
    func renderToImage(picture: Picture, size: CGSize, look: FrameLook, maxRadius: Double) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = makeTexture(descriptor) else { return nil }
        guard render(picture: picture, into: target, look: look, maxRadius: maxRadius) else { return nil }

        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let space = CGColorSpace(name: BlurRenderer.colourSpace),
              let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        return context.makeImage()
    }
}
