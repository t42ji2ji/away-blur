import CoreGraphics
import Foundation

/// `AwayBlur --measure` renders a known pattern at a range of radii and
/// reports where the marks ended up. A blur must not move the picture.
enum Diagnostics {

    static func measureDrift(width: Int = 3024, height: Int = 1964, maxRadius: Double = 240) {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let renderer = BlurRenderer() else {
            print("no Metal device")
            return
        }
        let size = CGSize(width: width, height: height)
        let whole = CGRect(origin: .zero, size: size)
        let places = [("near", CGPoint(x: 0.25, y: 0.25)), ("far", CGPoint(x: 0.75, y: 0.75))]
        let radii: [Double] = [0, 8, 16, 32, 64, 128, 240]

        var drift: [String: [String]] = [:]
        var levels = 0
        var textureSize = ""
        for (name, fraction) in places {
            guard let pattern = Offscreen.oneDot(width: width, height: height, at: fraction),
                  let picture = renderer.makePicture(from: pattern) else { continue }
            levels = picture.texture.mipmapLevelCount
            textureSize = "\(picture.texture.width)x\(picture.texture.height)"
            var base: CGPoint?
            var column: [String] = []
            for radius in radii {
                let look = FrameLook(blur: radius / maxRadius)
                guard let image = renderer.renderToImage(picture: picture, size: size,
                                                         look: look, maxRadius: maxRadius),
                      let found = Offscreen.centroid(of: image, in: whole) else {
                    column.append("—")
                    continue
                }
                if base == nil { base = found }
                let origin = base ?? found
                column.append(String(format: "%+7.2f,%+7.2f", found.x - origin.x, found.y - origin.y))
            }
            drift[name] = column
        }

        print("picture \(textureSize), \(levels) mip levels, screen \(width)x\(height)")
        print("radius   near dx,dy        far dx,dy")
        for (index, radius) in radii.enumerated() {
            let near = drift["near"]?[index] ?? "—"
            let far = drift["far"]?[index] ?? "—"
            print("\(String(format: "%6.0f", radius))   \(near.padding(toLength: 18, withPad: " ", startingAt: 0))\(far)")
        }
    }
}
