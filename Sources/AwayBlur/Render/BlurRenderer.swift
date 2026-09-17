import CoreGraphics
import Foundation
import Metal
import MetalPerformanceShaders
import QuartzCore

/// Device, pipeline and pyramid, shared by every screen's overlay.
final class BlurRenderer {

    static let colourSpace = CGColorSpace.displayP3

    /// Deliberately not an `_srgb` format. With one, the sampler hands the
    /// shader linear light and the averaging happens there, which is what a
    /// real lens does: a white pixel averaged with a black one comes back at
    /// half the light, and half the light still reads as bright. Anything
    /// bright then swells into the dark around it as the radius grows, and on
    /// a dark screen with a bright panel in one corner the whole picture looks
    /// like it is sliding that way. Averaging the stored values instead keeps
    /// every edge where it is.
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let pyramid: MPSImageGaussianPyramid

    /// A frozen screen, and the fraction of its texture the screen occupies.
    struct Picture {
        let texture: MTLTexture
        let cover: SIMD2<Float>
    }

    /// A pixel stamp placed on the frosted screen.
    struct Stamp {
        let texture: MTLTexture
        /// Top left, in drawable pixels. Whole numbers only.
        let origin: CGPoint
        /// Drawable pixels per sprite pixel. A whole number, never below one.
        let cell: Double
        let alpha: Double
    }

    private struct Uniforms {
        var frame: SIMD4<Float>
        var look: SIMD4<Float>
        var misc: SIMD4<Float>
        var cover: SIMD4<Float>
        var stamp: SIMD4<Float>
        var grid: SIMD4<Float>
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: BlurShaders.source, options: nil)
        } catch {
            FileLog.write("shader failed to compile: \(error)")
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullScreenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "blurFragment")
        descriptor.colorAttachments[0].pixelFormat = BlurRenderer.pixelFormat
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.pyramid = MPSImageGaussianPyramid(device: device, centerWeight: 0.375)
    }

    func makeLayer(scale: CGFloat) -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = BlurRenderer.pixelFormat
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.contentsScale = scale
        layer.colorspace = CGColorSpace(name: BlurRenderer.colourSpace)
        // No implicit animation on anything, ever.
        layer.actions = ["bounds": NSNull(), "position": NSNull(),
                         "frame": NSNull(), "contents": NSNull(), "drawableSize": NSNull()]
        return layer
    }

    /// Every mip level is the one above it halved, rounded down, so an odd
    /// size loses half a texel and the whole level's grid slides half a texel
    /// off the original. It accumulates with each level, and since level zero
    /// is the top left corner the picture visibly creeps towards the bottom
    /// right as the radius grows. Sizing the picture so every halving down to
    /// the levels we actually sample is exact is what stops it.
    private static func aligned(_ value: Int) -> Int {
        let step = 256
        return max(step, Int((Double(value) / Double(step)).rounded(.up)) * step)
    }

    /// Uploads one screenshot and builds its mip chain. Done once per blur,
    /// off the main thread; every frame after it is one cheap pass.
    ///
    /// The screen goes in at its own size in the top left of a larger texture
    /// whose sides divide evenly, and the last row and column are stretched
    /// into the rest. Scaling the screen to fit instead would resample it, and
    /// that shows: the overlay goes up holding a sharp copy, so level zero has
    /// to match the real screen pixel for pixel or its arrival blinks.
    func makePicture(from image: CGImage) -> Picture? {
        guard image.width > 0, image.height > 0 else { return nil }
        let screen = (width: image.width, height: image.height)
        let width = BlurRenderer.aligned(image.width)
        let height = BlurRenderer.aligned(image.height)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: BlurRenderer.pixelFormat, width: width, height: height, mipmapped: true)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        let bytesPerRow = width * 4
        guard let space = CGColorSpace(name: BlurRenderer.colourSpace),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue),
              let pixels = context.data else { return nil }
        let top = height - screen.height
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: top, width: screen.width, height: screen.height))
        // Stretch the edges outwards, which is what the sampler would do at
        // the border anyway, so a wide blur near the right or bottom edge
        // does not pull the empty margin in.
        let padX = width - screen.width
        let padY = top
        if padX > 0, let column = image.cropping(to: CGRect(x: screen.width - 1, y: 0, width: 1, height: screen.height)) {
            context.draw(column, in: CGRect(x: screen.width, y: top, width: padX, height: screen.height))
        }
        if padY > 0, let row = image.cropping(to: CGRect(x: 0, y: screen.height - 1, width: screen.width, height: 1)) {
            context.draw(row, in: CGRect(x: 0, y: 0, width: screen.width, height: padY))
        }
        if padX > 0, padY > 0,
           let corner = image.cropping(to: CGRect(x: screen.width - 1, y: screen.height - 1, width: 1, height: 1)) {
            context.draw(corner, in: CGRect(x: screen.width, y: 0, width: padX, height: padY))
        }

        guard let staging = device.makeBuffer(bytes: pixels, length: bytesPerRow * height, options: .storageModeShared),
              let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: bytesPerRow,
                  sourceBytesPerImage: bytesPerRow * height,
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()

        guard let mips = commands.makeBlitCommandEncoder() else { return nil }
        mips.generateMipmaps(for: texture)
        mips.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return Picture(texture: texture,
                       cover: SIMD2(Float(Double(screen.width) / Double(width)),
                                    Float(Double(screen.height) / Double(height))))
    }

    func makeTexture(_ descriptor: MTLTextureDescriptor) -> MTLTexture? {
        device.makeTexture(descriptor: descriptor)
    }

    /// The same pass, into a texture rather than a drawable, and waited on.
    @discardableResult
    func render(picture: Picture, into target: MTLTexture, look: FrameLook, maxRadius: Double,
                stamp: Stamp? = nil) -> Bool {
        guard let commands = queue.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encode(into: encoder, picture: picture, size: CGSize(width: target.width, height: target.height),
               look: look, maxRadius: maxRadius, time: 0, stamp: stamp)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return true
    }

    func render(picture: Picture, into layer: CAMetalLayer, look: FrameLook, maxRadius: Double,
                time: Double, stamp: Stamp? = nil, onScreen: (@Sendable () -> Void)? = nil) {
        guard let drawable = layer.nextDrawable(),
              let commands = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encode(into: encoder, picture: picture,
               size: CGSize(width: drawable.texture.width, height: drawable.texture.height),
               look: look, maxRadius: maxRadius, time: time, stamp: stamp)
        encoder.endEncoding()
        commands.present(drawable)
        if let onScreen {
            commands.addScheduledHandler { _ in onScreen() }
        }
        commands.commit()
    }

    private func encode(into encoder: MTLRenderCommandEncoder, picture: Picture, size: CGSize,
                        look: FrameLook, maxRadius: Double, time: Double, stamp: Stamp?) {
        var uniforms = Uniforms(
            frame: SIMD4(Float(size.width), Float(size.height),
                         Float(maxRadius), Float(picture.texture.mipmapLevelCount - 1)),
            look: SIMD4(Float(look.blur), Float(look.dim), Float(look.wash), Float(look.grain)),
            misc: SIMD4(Float(time), 0, 0, 0),
            cover: SIMD4(picture.cover.x, picture.cover.y, 0, 0),
            stamp: SIMD4(Float(stamp?.origin.x ?? 0), Float(stamp?.origin.y ?? 0),
                         Float(stamp?.cell ?? 1), Float(stamp?.alpha ?? 0)),
            grid: SIMD4(Float(stamp?.texture.width ?? 1), Float(stamp?.texture.height ?? 1), 0, 0))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(picture.texture, index: 0)
        encoder.setFragmentTexture(stamp?.texture ?? picture.texture, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
