import Foundation
import Metal

/// One animation: a run of frames out of `Cat.packed`, how fast it plays, and
/// whether it repeats.
struct CatAnimation: Identifiable, Hashable {
    let name: String
    let fps: Double
    let loops: Bool
    let frames: Range<Int>
    /// The same frames again with the eyes shut, when there are any.
    ///
    /// The face is drawn into the art now rather than cut out of it on the
    /// way to the screen, so a blink is no longer free — it has to be drawn.
    /// Only the animation the cat spends nearly all its time in is worth
    /// drawing twice for it.
    let blink: Range<Int>?
    let note: String

    var id: String { name }
    var count: Int { frames.count }
    /// How long one pass takes, which is what decides how many passes a
    /// looping animation gets when it is used as a one-off beat.
    var duration: Double { Double(count) / fps }
}

/// The cat's art: a 48x32 grid of art pixels per frame, one bit per pixel.
///
/// It used to be a grid of characters written by hand in this file, and a face
/// cut out of it as holes. That could hold a rounded block with ears and
/// nothing else — no legs, no tail — so the only motion available was moving
/// the whole block. A cat that stretches or bristles needs limbs, and limbs
/// need more pixels than a grid of characters in the source can carry.
///
/// So the frames are drawn instead: `Art/` holds the sheets, each one a single
/// generation from one locked character reference, and
/// `Scripts/make-sprites.py` cuts them to this grid and writes
/// `CatFrames.swift`, which is where `width`, `height`, `baseline`,
/// `animations` and `packed` all come from. Editing the art means replacing a
/// sheet and running the script, not editing characters here.
enum Cat {

    static func animation(named name: String) -> CatAnimation {
        animations.first { $0.name == name } ?? animations[0]
    }

    /// One byte per pixel, unpacked from the hex: ink is 255.
    ///
    /// Nothing is cut out of it. The eyes are holes drawn into the sheet, so a
    /// hole here is a pixel that was simply never ink — the face does not have
    /// to be composited on, and it moves with the pose for free.
    static func stamp(frame: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height)
        var index = 0
        for character in packed[frame] {
            let nibble = character.hexDigitValue ?? 0
            for bit in 0..<4 where nibble & (8 >> bit) != 0 {
                bytes[index + bit] = 255
            }
            index += 4
        }
        return bytes
    }

    /// A frame trimmed to its ink, for the places that want the cat and not
    /// the slack around it: the app icon and the menu bar.
    static func cropped(frame: Int) -> (bytes: [UInt8], width: Int, height: Int) {
        let full = stamp(frame: frame)
        var minColumn = width, maxColumn = -1, minRow = height, maxRow = -1
        for row in 0..<height {
            for column in 0..<width where full[row * width + column] > 0 {
                minColumn = min(minColumn, column); maxColumn = max(maxColumn, column)
                minRow = min(minRow, row); maxRow = max(maxRow, row)
            }
        }
        guard maxColumn >= minColumn else { return (full, width, height) }
        let cropWidth = maxColumn - minColumn + 1, cropHeight = maxRow - minRow + 1
        var bytes = [UInt8](repeating: 0, count: cropWidth * cropHeight)
        for row in 0..<cropHeight {
            for column in 0..<cropWidth {
                bytes[row * cropWidth + column] = full[(minRow + row) * width + minColumn + column]
            }
        }
        return (bytes, cropWidth, cropHeight)
    }
}

extension BlurRenderer {

    /// One frame as a one-channel texture, sampled with nearest and drawn at a
    /// whole-number scale, which is the whole of what keeps pixel art sharp.
    func makeStamp(bytes: [UInt8], width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        bytes.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: width)
        }
        return texture
    }

    /// Every frame, built in one go and kept. At 1.5KB each the whole lot is
    /// less than 200KB, which is cheaper than the code it would take to decide
    /// when to build them.
    func makeFrames() -> [MTLTexture] {
        (0..<Cat.packed.count).compactMap {
            makeStamp(bytes: Cat.stamp(frame: $0), width: Cat.width, height: Cat.height)
        }
    }

    /// One animation laid out left to right in a single texture, so `--cat`
    /// can show a whole row of it in one pass.
    func makeStrip(_ animation: CatAnimation) -> MTLTexture? {
        let width = Cat.width * animation.count
        var bytes = [UInt8](repeating: 0, count: width * Cat.height)
        for (column, frame) in animation.frames.enumerated() {
            let source = Cat.stamp(frame: frame)
            for row in 0..<Cat.height {
                let from = row * Cat.width
                let to = row * width + column * Cat.width
                bytes.replaceSubrange(to..<(to + Cat.width),
                                      with: source[from..<(from + Cat.width)])
            }
        }
        return makeStamp(bytes: bytes, width: width, height: Cat.height)
    }
}
