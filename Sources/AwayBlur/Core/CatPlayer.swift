import Foundation

/// Which animation is playing and which frame of it.
///
/// There is no screen in here on purpose: the whole thing is arithmetic on a
/// clock, so `--beats` can run an hour of it headless and print what the cat
/// did, which is the only way to see behaviour that takes half an hour to
/// happen and never looks like anything in a still.
struct CatPlayer {

    private(set) var animation = Cat.animation(named: "idle")
    private(set) var frame = 0
    private(set) var blinking = false

    /// The frame to draw, as an index into `Cat.packed`.
    var stamp: Int {
        (blinking ? animation.blink?.lowerBound : nil).map { $0 + frame }
            ?? animation.frames.lowerBound + frame
    }

    /// Cats blink often and briefly, and never on a metronome.
    static let blinkFor: CFTimeInterval = 0.13
    static let blinkGap = 2.4 ... 6.5

    private var blinkAt: CFTimeInterval = 0
    private var blinkUntil: CFTimeInterval = 0
    private var frameAt: CFTimeInterval = 0
    /// Frames left before it goes back to resting; negative means forever.
    private var left = -1
    private var beatAt: CFTimeInterval = 0

    /// Everything that is neither resting nor the alarm: the cat doing
    /// something because nobody is watching.
    static let beats = ["stretch", "shake", "yawn", "flop", "roll",
                        "situp", "paw", "walk", "run", "pounce"]

    /// What it will still do once it has gone to sleep, and how much less
    /// often. Nothing here gets up: a cat that galloped across the screen
    /// every twenty seconds and then lay straight back down would not read as
    /// a sleeping cat at all, and there are no transitions between poses to
    /// soften the cut.
    static let sleepyBeats = ["yawn", "roll", "stretch"]
    static let awakeGap = 12.0 ... 30.0
    static let asleepGap = 90.0 ... 240.0

    /// Ten minutes is long enough that the line under the cat is already
    /// saying how long you have been gone, so the cat may as well be asleep
    /// by the time it does.
    static let sleepAfter: CFTimeInterval = 600

    static func resting(awayFor away: CFTimeInterval) -> CatAnimation {
        Cat.animation(named: away > sleepAfter ? "sleep" : "idle")
    }

    /// The screen has just gone. The cat arrives resting and stays that way
    /// for a while — an overlay that opens on a somersault reads as a glitch.
    mutating func begin(at now: CFTimeInterval) {
        animation = Cat.animation(named: "idle")
        frame = 0
        frameAt = now
        left = -1
        beatAt = now + Double.random(in: CatPlayer.awakeGap)
    }

    mutating func play(_ name: String, at now: CFTimeInterval) {
        animation = Cat.animation(named: name)
        frame = 0
        frameAt = now
        // A one-shot plays once. A cycle used as a beat plays whole passes,
        // enough of them to read as walking rather than as a twitch, and then
        // hands back: a walk that looped for ever would not be a beat.
        left = animation.loops
            ? animation.count * max(1, Int((2.5 / animation.duration).rounded()))
            : animation.count
    }

    private mutating func rest(at now: CFTimeInterval, awayFor away: CFTimeInterval) {
        animation = CatPlayer.resting(awayFor: away)
        frame = 0
        frameAt = now
        left = -1
    }

    /// One tick. `held` is the panel holding a single animation up to be
    /// looked at, or empty. Returns true when the frame changed.
    @discardableResult
    mutating func step(now: CFTimeInterval, awayFor away: CFTimeInterval,
                       held: String = "") -> Bool {
        let wasBlinking = blinking
        if animation.blink != nil {
            if now >= blinkAt {
                blinkUntil = now + CatPlayer.blinkFor
                blinkAt = now + Double.random(in: CatPlayer.blinkGap)
            }
            blinking = now < blinkUntil
        } else {
            blinking = false
        }
        if !held.isEmpty {
            // Held animations loop, including the one-shots, which is the
            // only way to watch a stretch that lasts under a second twice.
            if animation.name != held {
                animation = Cat.animation(named: held)
                frame = 0
                frameAt = now
                left = -1
            }
        } else {
            let asleep = CatPlayer.resting(awayFor: away).name == "sleep"
            if now >= beatAt {
                if left < 0 {
                    let from = asleep ? CatPlayer.sleepyBeats : CatPlayer.beats
                    play(from.randomElement() ?? "stretch", at: now)
                }
                beatAt = now + Double.random(in: asleep ? CatPlayer.asleepGap
                                                        : CatPlayer.awakeGap)
            }
            // Resting is open-ended, so the crossing into sleep has to be
            // noticed here rather than waited for at the end of something.
            if left < 0, animation.name != CatPlayer.resting(awayFor: away).name {
                rest(at: now, awayFor: away)
            }
        }
        guard now - frameAt >= 1 / animation.fps else { return blinking != wasBlinking }
        frameAt = now
        if left >= 0 {
            left -= 1
            if left <= 0 {
                rest(at: now, awayFor: away)
                return true
            }
        }
        frame = (frame + 1) % animation.count
        return true
    }
}
