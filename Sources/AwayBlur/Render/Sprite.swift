import Foundation
import Metal

/// Pixel art as text. `#` is ink, anything else is not.
///
/// Written by hand in the source rather than drawn in a tool and imported:
/// at this size a grid of characters is the most direct thing there is, it
/// diffs, and there is no pipeline between changing it and seeing it.
struct Grid {
    let rows: [String]
    var height: Int { rows.count }
    var width: Int { rows.map(\.count).max() ?? 0 }

    func isInk(_ column: Int, _ row: Int) -> Bool {
        guard row >= 0, row < rows.count else { return false }
        let line = Array(rows[row])
        guard column >= 0, column < line.count else { return false }
        return line[column] == "#"
    }
}

/// A face is two more grids, and their ink is cut *out* of the body — the way
/// the eyes and nose are holes in a paper cut-out, not marks drawn on it.
///
/// Eyes and mouth are kept apart because that is how a kaomoji is built, and
/// because it is what makes blinking free: swap the eyes, keep the mouth.
struct Face: Identifiable, Hashable {
    let id: String      // its own kaomoji, which is also what it is called
    let eyes: Grid
    let mouth: Grid

    static func == (a: Face, b: Face) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum Cat {

    /// 20 x 19. Ears that stay narrow long enough to read as ears, then one
    /// solid rounded block — the same build as the paper-cut rabbit this came
    /// from.
    static let body = Grid(rows: [
        "##................##",
        "###..............###",
        "###..............###",
        "####............####",
        "####............####",
        "#####..........#####",
        "####################",
        "####################",
        "####################",
        "####################",
        "####################",
        "####################",
        "####################",
        "####################",
        "####################",
        "####################",
        ".##################.",
        ".##################.",
        "..################..",
    ])

    /// Where the two halves of a face sit in the body, in body pixels.
    static let eyesOrigin = (column: 3, row: 8)
    static let mouthOrigin = (column: 3, row: 14)

    // Eyes, 14 x 5.
    static let bars = Grid(rows: [
        "..##......##..",
        "..##......##..",
        "..##......##..",
        "..##......##..",
        "..............",
    ])
    static let carets = Grid(rows: [
        "..............",
        "...#......#...",
        "..#.#....#.#..",
        "..............",
        "..............",
    ])
    /// Also what every face blinks with.
    static let closed = Grid(rows: [
        "..............",
        "..............",
        "..###....###..",
        "..............",
        "..............",
    ])
    static let chevrons = Grid(rows: [
        "..#........#..",
        "...#......#...",
        "...#......#...",
        "..#........#..",
        "..............",
    ])

    // Mouths, 14 x 2.
    static let omega = Grid(rows: [
        "....#.##.#....",
        ".....#..#.....",
    ])
    static let round = Grid(rows: [
        ".....####.....",
        ".....####.....",
    ])
    static let flat = Grid(rows: [
        ".....####.....",
        "..............",
    ])
    /// The = of (=^ω^=). Whiskers come off the cheeks; up by the ears they
    /// just read as two chips out of the silhouette.
    static let whiskered = Grid(rows: [
        "##..#.##.#..##",
        ".....#..#.....",
    ])

    static let faces: [Face] = [
        Face(id: "(･ω･)", eyes: bars, mouth: omega),
        Face(id: "(＾ω＾)", eyes: carets, mouth: omega),
        Face(id: "(－ω－)", eyes: closed, mouth: omega),
        Face(id: "(＞﹏＜)", eyes: chevrons, mouth: flat),
        Face(id: "(･o･)", eyes: bars, mouth: round),
        Face(id: "(=^ω^=)", eyes: carets, mouth: whiskered),
    ]

    static func face(named id: String) -> Face {
        faces.first { $0.id == id } ?? faces[0]
    }

    /// One byte per pixel: ink, minus whatever the face cuts out of it.
    static func stamp(face: Face, blinking: Bool = false) -> [UInt8] {
        let eyes = blinking ? closed : face.eyes
        var bytes = [UInt8](repeating: 0, count: body.width * body.height)
        for row in 0..<body.height {
            for column in 0..<body.width {
                guard body.isInk(column, row) else { continue }
                let cut = eyes.isInk(column - eyesOrigin.column, row - eyesOrigin.row)
                    || face.mouth.isInk(column - mouthOrigin.column, row - mouthOrigin.row)
                bytes[row * body.width + column] = cut ? 0 : 255
            }
        }
        return bytes
    }
}

extension BlurRenderer {

    /// The cat as a one-channel texture, sampled with nearest and drawn at a
    /// whole-number scale, which is the whole of what keeps pixel art sharp.
    func makeStamp(face: Face, blinking: Bool = false) -> MTLTexture? {
        let width = Cat.body.width
        let height = Cat.body.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let bytes = Cat.stamp(face: face, blinking: blinking)
        bytes.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: width)
        }
        return texture
    }
}
