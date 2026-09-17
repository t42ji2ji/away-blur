import CoreGraphics
import Foundation
import Metal
import MetalPerformanceShaders
import QuartzCore

/// Device, pipeline and pyramid, shared by every screen's overlay.
final class BlurRenderer {

    static let colourSpace = CGColorSpace.displayP3

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let pyramid: MPSImageGaussianPyramid

    private struct Uniforms {
        var frame: SIMD4<Float>
        var look: SIMD4<Float>
        var misc: SIMD4<Float>
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
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.pyramid = MPSImageGaussianPyramid(device: device, centerWeight: 0.375)
    }

    func makeLayer(scale: CGFloat) -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.contentsScale = scale
        layer.colorspace = CGColorSpace(name: BlurRenderer.colourSpace)
        return layer
    }

    /// Uploads one screenshot and builds its Gaussian pyramid. Done once per
    /// blur, off the main thread; every frame after it is one cheap pass.
    func makePicture(from image: CGImage) -> MTLTexture? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: true)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        let bytesPerRow = width * 4
        guard let space = CGColorSpace(name: BlurRenderer.colourSpace),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue),
              let pixels = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let staging = device.makeBuffer(bytes: pixels, length: bytesPerRow * height, options: .storageModeShared),
              let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: bytesPerRow,
                  sourceBytesPerImage: bytesPerRow * height,
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()

        var target = texture
        pyramid.encode(commandBuffer: commands, inPlaceTexture: &target, fallbackCopyAllocator: nil)
        commands.commit()
        commands.waitUntilCompleted()
        return target
    }

    func render(picture: MTLTexture, into layer: CAMetalLayer, look: FrameLook, maxRadius: Double, time: Double) {
        guard let drawable = layer.nextDrawable(),
              let commands = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        var uniforms = Uniforms(
            frame: SIMD4(Float(drawable.texture.width), Float(drawable.texture.height),
                         Float(maxRadius), Float(picture.mipmapLevelCount - 1)),
            look: SIMD4(Float(look.blur), Float(look.dim), Float(look.wash), Float(look.grain)),
            misc: SIMD4(Float(time), 0, 0, 0))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(picture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}
