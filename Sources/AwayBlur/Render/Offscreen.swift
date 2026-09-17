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

    /// Mean absolute difference per channel, 0-255. Level zero must be the
    /// screen itself, or the overlay blinks the moment it arrives.
    static func difference(_ a: CGImage, _ b: CGImage) -> String {
        func bytes(_ image: CGImage) -> [UInt8]? {
            let width = image.width, height = image.height
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let data = context.data else { return nil }
            return Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: width * height * 4),
                                             count: width * height * 4))
        }
        guard a.width == b.width, a.height == b.height,
              let left = bytes(a), let right = bytes(b) else { return "sizes differ" }
        var total = 0.0
        var worst = 0
        for index in 0..<left.count where index % 4 != 3 {
            let delta = abs(Int(left[index]) - Int(right[index]))
            total += Double(delta)
            worst = max(worst, delta)
        }
        let mean = total / Double(left.count / 4 * 3)
        return String(format: "mean %.3f, worst %d (of 255)", mean, worst)
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
    func renderToImage(picture: Picture, size: CGSize, look: FrameLook, maxRadius: Double,
                       stamp: Stamp? = nil, caption: Stamp? = nil) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: BlurRenderer.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = makeTexture(descriptor) else { return nil }
        guard render(picture: picture, into: target, look: look, maxRadius: maxRadius,
                     stamp: stamp, caption: caption) else { return nil }

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

extension Offscreen {

    /// A white block in the top left corner of a black field: one long
    /// straight vertical edge and one horizontal one.
    static func quadrant(width: Int, height: Int, at fraction: CGPoint) -> CGImage? {
        guard let space = CGColorSpace(name: BlurRenderer.colourSpace),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        // CoreGraphics counts from the bottom; the block sits at the top left.
        let blockWidth = Double(width) * fraction.x
        let blockHeight = Double(height) * fraction.y
        context.fill(CGRect(x: 0, y: Double(height) - blockHeight, width: blockWidth, height: blockHeight))
        return context.makeImage()
    }

    /// A flat field, for looking at something drawn on top of it.
    static func flat(width: Int, height: Int, level: Double) -> CGImage? {
        guard let space = CGColorSpace(name: BlurRenderer.colourSpace),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.setFillColor(CGColor(red: level, green: level, blue: level, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func luminance(_ image: CGImage) -> (values: [Double], width: Int, height: Int)? {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        // In linear light. The blur happens there, and an edge's midpoint is
        // only preserved in the space the averaging happened in; measuring the
        // sRGB bytes instead tilts every edge towards its darker side.
        var curve = [Double](repeating: 0, count: 256)
        for value in 0..<256 {
            let normalised = Double(value) / 255
            curve[value] = normalised <= 0.04045
                ? normalised / 12.92
                : pow((normalised + 0.055) / 1.055, 2.4)
        }
        var values = [Double](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let offset = index * 4
            values[index] = (curve[Int(pixels[offset])] + curve[Int(pixels[offset + 1])] + curve[Int(pixels[offset + 2])]) / 3
        }
        return (values, width, height)
    }

    /// Where an edge sits, to a fraction of a pixel: the centre of mass of the
    /// slope across it. A symmetric blur leaves this exactly where it was, so
    /// any movement is the blur moving the picture.
    static func edgePosition(_ image: CGImage, vertical: Bool, around centre: Int,
                             span: Int, across: ClosedRange<Int>) -> Double? {
        guard let (values, width, height) = luminance(image) else { return nil }
        let length = vertical ? width : height
        let low = max(1, centre - span), high = min(length - 2, centre + span)
        guard low < high else { return nil }

        var profile = [Double](repeating: 0, count: high - low + 1)
        var rows = 0
        for other in across where other >= 0 && other < (vertical ? height : width) {
            rows += 1
            for (index, position) in (low...high).enumerated() {
                let offset = vertical ? other * width + position : position * width + other
                profile[index] += values[offset]
            }
        }
        guard rows > 0 else { return nil }

        var sum = 0.0, weighted = 0.0
        for index in 1..<(profile.count - 1) {
            let slope = abs(profile[index + 1] - profile[index - 1])
            sum += slope
            weighted += slope * Double(low + index)
        }
        guard sum > 0 else { return nil }
        return weighted / sum
    }
}
