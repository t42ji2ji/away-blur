import AppKit
import ImageIO
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
        var every: [(CGDirectDisplayID, CGImage)] = []
        Task { @MainActor in
            for screen in NSScreen.screens {
                guard let id = screen.displayID, let image = await ScreenSnapshot.capture(display: id) else { continue }
                every.append((id, image))
            }
            captured = every.first?.1
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
        for (id, image) in every {
            _ = Offscreen.write(image, to: directory.appendingPathComponent("capture-\(id).png"))
            print("wrote capture-\(id).png (\(image.width)x\(image.height))")
        }
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

extension Diagnostics {

    /// `AwayBlur --compare a.png b.png` — how far apart two frames are.
    static func compare(_ first: String, _ second: String) {
        setvbuf(stdout, nil, _IONBF, 0)
        func load(_ path: String) -> CGImage? {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let a = load(first), let b = load(second) else {
            print("could not read both images")
            return
        }
        print("\(a.width)x\(a.height) vs \(b.width)x\(b.height): \(Offscreen.difference(a, b))")
    }
}

extension Diagnostics {

    /// `AwayBlur --camera` — open the camera once and say what it saw.
    static func lookThroughCamera() {
        setvbuf(stdout, nil, _IONBF, 0)
        if !FaceCheck.isAuthorized {
            guard !FaceCheck.isDenied else {
                print("camera access denied — System Settings › Privacy & Security › Camera")
                return
            }
            print("asking for camera access…")
            let asking = DispatchSemaphore(value: 0)
            var granted = false
            Task { granted = await FaceCheck.requestAccess(); asking.signal() }
            while asking.wait(timeout: .now()) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            guard granted else { print("camera access refused"); return }
        }
        let check = FaceCheck()
        let done = DispatchSemaphore(value: 0)
        var seen = false
        let started = Date()
        Task {
            seen = await check.look()
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        let elapsed = Date().timeIntervalSince(started)
        print(String(format: "%@ — %d frames at %.0fx%.0f in %.2fs",
                     seen ? "face found" : "nobody in front of the camera",
                     check.framesSeen, check.frameSize.width, check.frameSize.height, elapsed))
    }
}

extension Diagnostics {

    /// `AwayBlur --cat out.png` — every animation, one row each, every frame
    /// at the size it is actually drawn. This is the sheet to look at after
    /// replacing any art in `Art/`.
    static func drawCat(to path: String, cell: Double = 4) {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let renderer = BlurRenderer() else { print("no Metal device"); return }

        let widest = Cat.animations.map(\.count).max() ?? 1
        let rowWidth = Int(Double(Cat.width * widest) * cell) + 2
        let rowHeight = Int(Double(Cat.height) * cell) + 2
        guard let flat = Offscreen.flat(width: rowWidth, height: rowHeight, level: 0.55),
              let picture = renderer.makePicture(from: flat),
              let space = CGColorSpace(name: BlurRenderer.colourSpace),
              let sheet = CGContext(data: nil, width: rowWidth,
                                    height: rowHeight * Cat.animations.count,
                                    bitsPerComponent: 8, bytesPerRow: rowWidth * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else {
            print("could not set up the sheet")
            return
        }

        for (index, animation) in Cat.animations.enumerated() {
            guard let strip = renderer.makeStrip(animation) else { continue }
            let placed = BlurRenderer.Stamp(texture: strip, origin: CGPoint(x: 1, y: 1),
                                            cell: cell, alpha: 1)
            guard let row = renderer.renderToImage(
                picture: picture, size: CGSize(width: rowWidth, height: rowHeight),
                look: FrameLook(blur: 0), maxRadius: 240, stamp: placed) else { continue }
            sheet.draw(row, in: CGRect(x: 0, y: (Cat.animations.count - 1 - index) * rowHeight,
                                       width: rowWidth, height: rowHeight))
            let name = animation.name.padding(toLength: 8, withPad: " ", startingAt: 0)
            print("\(name) \(animation.count) frames  \(animation.fps)fps  "
                  + (animation.loops ? "loop" : "once")
                  + "  \(String(format: "%.2f", animation.duration))s  \(animation.note)")
        }
        guard let image = sheet.makeImage(),
              Offscreen.write(image, to: URL(fileURLWithPath: path)) else {
            print("could not write \(path)")
            return
        }
        print("\n\(Cat.packed.count) frames of \(Cat.width)x\(Cat.height), baseline row \(Cat.baseline)")
        print("wrote \(path)")
    }
}

extension Diagnostics {

    /// `AwayBlur --lines` — what the line under the cat would say right now.
    static func showLines() {
        setvbuf(stdout, nil, _IONBF, 0)
        // The CPU line is measured between calls, so the first one only starts
        // the clock and each block wants a second of its own to measure over.
        _ = Caption.lines(awayFor: 8 * 60, includingWork: true)
        Thread.sleep(forTimeInterval: 1)
        print("ambient:")
        for line in Caption.lines(awayFor: 8 * 60, includingWork: true) { print("  \(line)") }
        Thread.sleep(forTimeInterval: 1)
        print("privacy:")
        for line in Caption.lines(awayFor: 8 * 60, includingWork: false) { print("  \(line)") }
        print("cmux: \(Sessions.open()) panels, waiting: \(Sessions.waiting() ?? "—")")
    }

    /// `AwayBlur --scene out.png` — the cat and a line, at the size they are
    /// actually drawn on a screen this size.
    static func drawScene(to path: String, width: Int = 1512, height: Int = 982,
                          size: Double = 0.20, text: String = "AWAY 8 MINUTES") {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let renderer = BlurRenderer() else { print("no Metal device"); return }
        guard let flat = Offscreen.flat(width: width, height: height, level: 0.5),
              let picture = renderer.makePicture(from: flat),
              let stamp = renderer.makeStamp(bytes: Cat.stamp(frame: 0),
                                             width: Cat.width, height: Cat.height),
              let caption = renderer.makeCaption(text) else { print("could not set up"); return }

        let catCell = (Double(height) * size / Double(Cat.height)).rounded(.down)
        let catSpan = CGSize(width: Double(Cat.width) * catCell,
                             height: Double(Cat.height) * catCell)
        let lineCell = max(2, (catCell * 0.45).rounded())
        let lineSpan = CGSize(width: Double(caption.width) * lineCell,
                              height: Double(caption.height) * lineCell)
        let placed = BlurRenderer.Stamp(
            texture: stamp,
            origin: CGPoint(x: ((Double(width) - catSpan.width) / 2).rounded(),
                            y: ((Double(height) - catSpan.height) / 2).rounded()),
            cell: catCell, alpha: 1)
        let line = BlurRenderer.Stamp(
            texture: caption,
            origin: CGPoint(x: ((Double(width) - lineSpan.width) / 2).rounded(),
                            y: ((Double(height) + catSpan.height) / 2
                                - Double(Cat.height - 1 - Cat.baseline) * catCell
                                + catCell * 8.0).rounded()),
            cell: lineCell, alpha: 1)

        guard let image = renderer.renderToImage(picture: picture,
                                                 size: CGSize(width: width, height: height),
                                                 look: FrameLook(blur: 0), maxRadius: 240,
                                                 stamp: placed, caption: line),
              Offscreen.write(image, to: URL(fileURLWithPath: path)) else {
            print("could not write \(path)")
            return
        }
        print("cat cell \(Int(catCell))px, line cell \(Int(lineCell))px, line \(caption.width)x\(caption.height) cells")
        print("wrote \(path)")
    }
}

extension Diagnostics {

    /// `AwayBlur --font out.png` — the whole alphabet at drawing size, to see
    /// whether the counters survived being emboldened.
    static func drawFont(to path: String, cell: Double = 6) {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let renderer = BlurRenderer() else { print("no Metal device"); return }
        let rows = ["ABCDEFGHIJKLM", "NOPQRSTUVWXYZ", "0123456789", "AWAY 8 MINUTES", "BATTERY 100%"]
        let width = Int(Double(rows.map(\.count).max() ?? 1) * Double(PixelFont.advance) * cell) + 40
        let height = Int(Double(rows.count) * Double(PixelFont.height + 4) * cell) + 40
        guard let flat = Offscreen.flat(width: width, height: height, level: 0.55),
              let picture = renderer.makePicture(from: flat) else { print("no picture"); return }

        var image: CGImage?
        for (index, line) in rows.enumerated() {
            guard let caption = renderer.makeCaption(line) else { continue }
            let placed = BlurRenderer.Stamp(
                texture: caption, origin: CGPoint(x: 20, y: 20 + Double(index) * Double(PixelFont.height + 4) * cell),
                cell: cell, alpha: 1)
            let base = image.flatMap { renderer.makePicture(from: $0) } ?? picture
            image = renderer.renderToImage(picture: base, size: CGSize(width: width, height: height),
                                           look: FrameLook(blur: 0), maxRadius: 240, caption: placed)
        }
        guard let image, Offscreen.write(image, to: URL(fileURLWithPath: path)) else {
            print("could not write \(path)")
            return
        }
        print("wrote \(path)")
    }
}

extension Diagnostics {

    /// `AwayBlur --iconset AppIcon.iconset` — every size macOS asks for.
    static func writeIconset(to path: String) {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let renderer = BlurRenderer() else { print("no Metal device"); return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let wanted: [(Int, String)] = [
            (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
            (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"),
            (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x"),
        ]
        for (size, name) in wanted {
            guard let image = Icon.render(renderer, size: size),
                  Offscreen.write(image, to: directory.appendingPathComponent("\(name).png")) else {
                print("failed at \(name)")
                continue
            }
        }
        print("wrote \(path)")
    }
}

extension Diagnostics {

    /// `AwayBlur --beats [minutes]` — runs the cat headless and prints what it
    /// did and when. Behaviour on this timescale never looks like anything in
    /// a still: the beats are twelve to thirty seconds apart and the cat does
    /// not lie down for ten minutes, so this is the only way to see whether
    /// the rest of it happens at all.
    static func showBeats(minutes: Double = 20) {
        setvbuf(stdout, nil, _IONBF, 0)
        var player = CatPlayer()
        player.begin(at: 0)

        // Tick at the display link's slow rate, which is what it really gets
        // while the cat is the only thing moving.
        let step = 1.0 / 15
        var playing = player.animation.name
        var since = 0.0
        var counts: [String: Int] = [:]
        var blinks = 0
        var blinking = false
        var now = 0.0
        print("time   animation  for")
        while now < minutes * 60 {
            now += step
            player.step(now: now, awayFor: now)
            if player.blinking, !blinking { blinks += 1 }
            blinking = player.blinking
            guard player.animation.name != playing else { continue }
            print(String(format: "%5.1fs  ", since)
                  + playing.padding(toLength: 9, withPad: " ", startingAt: 0)
                  + String(format: "%.1fs", now - since))
            counts[playing, default: 0] += 1
            playing = player.animation.name
            since = now
        }
        counts[playing, default: 0] += 1
        print("\nover \(Int(minutes)) minutes, \(blinks) blinks:")
        for (name, count) in counts.sorted(by: { $0.value > $1.value }) {
            print("  \(name.padding(toLength: 8, withPad: " ", startingAt: 0)) \(count)")
        }
    }
}
