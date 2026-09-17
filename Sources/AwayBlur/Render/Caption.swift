import AppKit
import CoreText
import Foundation
import IOKit.ps
import Metal

/// The line under the cat: what the machine is doing while nobody is there.
enum Caption {

    /// The lines worth reading from across a room, in the order they come
    /// round. Work is left out of the privacy look on purpose: a line naming
    /// what you are building rather defeats a screen you made unreadable.
    static func lines(awayFor seconds: TimeInterval, includingWork: Bool) -> [String] {
        var lines = [away(seconds), clock()]
        if let power = battery() { lines.append(power) }
        if includingWork {
            if let waiting = Sessions.waiting() { lines.append(waiting) }
            if let busy = busy() { lines.append(busy) }
        }
        lines.append(chatter.randomElement() ?? "NOBODY HERE")
        return lines
    }

    /// One of these comes round every rotation. The cat is watching an empty
    /// chair; it may as well have an opinion about it.
    private static let chatter = [
        "NOBODY HERE",
        "STILL WATCHING",
        "I TOUCHED NOTHING",
        "YOUR SEAT IS COLD",
        "TAKE YOUR TIME",
        "I AM NOT ASLEEP",
        "NOTHING HAS CHANGED",
        "THE SCREEN IS SAFE",
    ]

    private static func away(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        switch minutes {
        case 0: return "AWAY A MOMENT"
        case 1: return "AWAY 1 MINUTE"
        case 2..<60: return "AWAY \(minutes) MINUTES"
        default:
            let hours = minutes / 60
            let rest = minutes % 60
            return rest == 0 ? "AWAY \(hours)H" : "AWAY \(hours)H \(rest)M"
        }
    }

    private static func clock() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
    }

    private static func battery() -> String? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any],
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let percent = Int((Double(capacity) / Double(maximum) * 100).rounded())
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            return charging ? "CHARGING \(percent)%" : "BATTERY \(percent)%"
        }
        return nil
    }

    /// Something is keeping the machine itself awake — a build, an export, a
    /// download. Worth knowing before deciding to stay away.
    ///
    /// Only things you started, though. `bluetoothd` and its kind hold this
    /// assertion around the clock, and "BLUETOOTHD IS STILL BUSY" is not news.
    private static func busy() -> String? {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let table = byProcess?.takeRetainedValue() as? [AnyHashable: [[String: Any]]] else { return nil }
        let apps = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName?.lowercased() })
        for assertions in table.values {
            for assertion in assertions {
                guard assertion["AssertType"] as? String == "PreventUserIdleSystemSleep",
                      let name = assertion["Process Name"] as? String,
                      name != "AwayBlur", apps.contains(name.lowercased()) else { continue }
                return "\(name.uppercased()) IS STILL BUSY"
            }
        }
        return nil
    }

    // MARK: - Drawing

    private static let scrambleAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#%*+=-/\\<>")

    /// The line as it looks partway through arriving.
    ///
    /// Each place settles in turn from the left; until it does it shows
    /// something else entirely, rerolled a few times a second. Spaces never
    /// scramble, so the shape of the line is there before the words are.
    static func scrambled(_ text: String, progress: Double, seed: Int) -> String {
        guard progress < 1 else { return text }
        let characters = Array(text)
        let settled = Int((Double(characters.count) * max(progress, 0) * 1.35).rounded(.down))
        var generator = SplitMix(seed: UInt64(seed))
        return String(characters.enumerated().map { index, character in
            if index < settled || character == " " { return character }
            return scrambleAlphabet[Int(generator.next() % UInt64(scrambleAlphabet.count))]
        })
    }

    /// The line as it looks partway through leaving: eaten from the right.
    static func erased(_ text: String, progress: Double) -> String {
        let characters = Array(text)
        let left = Int((Double(characters.count) * (1 - max(min(progress, 1), 0))).rounded())
        return String(characters.prefix(left))
    }

    /// One byte per pixel, no antialiasing: the glyphs come out of the font
    /// already one bit deep, so blowing them up by a whole number puts them in
    /// the same world as the cat rather than next to it.
    static func bitmap(_ text: String, pointSize: CGFloat = 9) -> (bytes: [UInt8], width: Int, height: Int)? {
        guard !text.isEmpty else { return nil }
        let font = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .bold)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white,
            .kern: 1.0,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetImageBounds(line, nil)
        let width = Int(bounds.width.rounded(.up)) + 2
        let height = Int(pointSize.rounded(.up)) + 4
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setShouldAntialias(false)
        context.setShouldSmoothFonts(false)
        context.setAllowsAntialiasing(false)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.textPosition = CGPoint(x: 1 - bounds.origin.x, y: 2)
        CTLineDraw(line, context)
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)
        var bytes = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            bytes[index] = pixels[index] > 127 ? 255 : 0
        }
        return (bytes, width, height)
    }
}

/// A tiny deterministic generator, so a frame of scramble is the same however
/// many screens draw it.
private struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 &+ 1 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

extension BlurRenderer {

    func makeCaption(_ text: String) -> MTLTexture? {
        guard let made = Caption.bitmap(text) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: made.width, height: made.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        made.bytes.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, made.width, made.height),
                            mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: made.width)
        }
        return texture
    }
}
