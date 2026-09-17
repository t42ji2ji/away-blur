import AppKit
import CoreGraphics
import Foundation

/// `AwayBlur --measure` renders a known pattern at a range of radii and
/// reports where the marks ended up. A blur must not move the picture.
enum Diagnostics {

    static func measureEdges(width: Int = 3024, height: Int = 1964, maxRadius: Double = 240) {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let renderer = BlurRenderer() else { print("no Metal device"); return }
        guard let pattern = Offscreen.quadrant(width: width, height: height, at: CGPoint(x: 0.4, y: 0.6)),
              let picture = renderer.makePicture(from: pattern) else { print("no picture"); return }
        let size = CGSize(width: width, height: height)
        let edgeX = Int(Double(width) * 0.4), edgeY = Int(Double(height) * 0.6)
        print("picture \(picture.texture.width)x\(picture.texture.height), edges at x=\(edgeX) y=\(edgeY)")
        print("radius   vertical edge      horizontal edge")
        var baseX: Double?, baseY: Double?
        for radius in [0.0, 8, 16, 32, 64, 128, 240] {
            let look = FrameLook(blur: radius / maxRadius)
            guard let image = renderer.renderToImage(picture: picture, size: size, look: look, maxRadius: maxRadius),
                  let x = Offscreen.edgePosition(image, vertical: true, around: edgeX, span: 700, across: 100...(edgeY - 400)),
                  let y = Offscreen.edgePosition(image, vertical: false, around: edgeY, span: 700, across: 100...(edgeX - 400))
            else { print("  \(radius)  —"); continue }
            if baseX == nil { baseX = x; baseY = y }
            print("\(String(format: "%6.0f", radius))   \(String(format: "%+8.2f", x - (baseX ?? x)))           \(String(format: "%+8.2f", y - (baseY ?? y)))")
        }
    }

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

extension Diagnostics {

    /// `AwayBlur --shot` puts the real screen through the pipeline and writes
    /// what comes out, so it can be looked at rather than argued about.
    static func shoot(into directory: URL, radii: [Double] = [0, 20, 40, 80, 110]) {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let renderer = BlurRenderer() else {
            print("no Metal device")
            return
        }
        let done = DispatchSemaphore(value: 0)
        var captured: CGImage?
        Task { @MainActor in
            guard let id = NSScreen.main?.displayID else { done.signal(); return }
            captured = await ScreenSnapshot.capture(display: id)
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        guard let screen = captured else {
            print("nothing captured — is Screen Recording on for this bundle?")
            return
        }
        guard let picture = renderer.makePicture(from: screen) else {
            print("could not build the picture")
            return
        }
        let size = CGSize(width: screen.width, height: screen.height)
        print("screen \(screen.width)x\(screen.height), texture \(picture.texture.width)x\(picture.texture.height)")
        _ = Offscreen.write(screen, to: directory.appendingPathComponent("capture.png"))

        for radius in radii {
            let look = FrameLook(blur: radius / 240)
            guard let image = renderer.renderToImage(picture: picture, size: size, look: look, maxRadius: 240) else { continue }
            let name = String(format: "blur-%03.0f.png", radius)
            _ = Offscreen.write(image, to: directory.appendingPathComponent(name))
            if radius == 0 {
                print("radius 0 vs the capture: \(Offscreen.difference(image, screen))")
            }
            print("wrote \(name)")
        }
    }
}
