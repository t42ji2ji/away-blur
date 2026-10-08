import Carbon.HIToolbox
import Foundation

/// The two looks. Same shader, different numbers and different timing.
enum Look: String, Codable, CaseIterable {
    case privacy
    case ambient

    var title: String {
        switch self {
        case .privacy: return "Privacy"
        case .ambient: return "Ambient"
        }
    }

    var blurb: String {
        switch self {
        case .privacy: return "Nothing readable, and gone the instant you touch anything."
        case .ambient: return "Frosted rather than hidden. Slow to arrive, slow to leave."
        }
    }
}

/// Everything one look is made of. Radius is in pixels at full strength.
struct LookSettings: Equatable {
    var blurRadius: Double
    /// How far the picture sinks towards black, 0…1.
    var dim: Double
    /// How far the picture washes towards its own average colour, 0…1.
    var wash: Double
    /// Hash noise, so a wide gradient does not band. 0…1.
    var grain: Double
    var fadeIn: Double
    var fadeOut: Double

    /// Unreadable, quickly, and gone the moment a hand comes back.
    static let privacyDefaults = LookSettings(
        blurRadius: 110, dim: 0.45, wash: 0, grain: 0.6,
        fadeIn: 0.45, fadeOut: 0.14
    )

    /// Frosted rather than hidden: you can still tell what is under there.
    static let ambientDefaults = LookSettings(
        blurRadius: 55, dim: 0.12, wash: 0.35, grain: 0.8,
        fadeIn: 1.6, fadeOut: 0.8
    )

    static func defaults(for look: Look) -> LookSettings {
        switch look {
        case .privacy: return .privacyDefaults
        case .ambient: return .ambientDefaults
        }
    }

    /// One strength, 1…5, in place of every number above. Three is the look
    /// as it is; the others scale its blur, and its dim and wash with it.
    /// Grain and timing belong to the look, not to how strong it is.
    static func look(_ look: Look, strength: Int) -> LookSettings {
        let index = min(max(strength, 1), 5) - 1
        var settings = defaults(for: look)
        settings.blurRadius *= [0.4, 0.65, 1, 1.5, 2.1][index]
        let tint = [0.4, 0.7, 1, 1.25, 1.5][index]
        settings.dim = min(settings.dim * tint, 0.85)
        settings.wash = min(settings.wash * tint, 0.8)
        return settings
    }
}

/// What the shader is handed for one frame.
struct FrameLook {
    var blur: Double
    var dim: Double
    var wash: Double
    var grain: Double

    init(blur: Double, dim: Double = 0, wash: Double = 0, grain: Double = 0) {
        self.blur = blur; self.dim = dim; self.wash = wash; self.grain = grain
    }

    /// Blur leads, dimming follows a little behind, wash rides along.
    init(settings: LookSettings, progress: Double) {
        let p = min(max(progress, 0), 1)
        blur = pow(p, 1.45)
        dim = settings.dim * pow(p, 0.9)
        wash = settings.wash * p
        grain = settings.grain
    }
}

@MainActor
final class Preferences: ObservableObject {
    @Published var isEnabled: Bool { didSet { store(isEnabled, "enabled") } }
    /// Seconds of no keyboard or mouse before the screen goes. One number for
    /// both looks: it answers whether anyone is there, which has nothing to do
    /// with what the screen turns into afterwards.
    @Published var idleDelay: Double { didSet { defaults.set(idleDelay, forKey: "idleDelay") } }
    @Published var look: Look { didSet { store(look.rawValue, "look") } }
    @Published var hotkeyCode: Int { didSet { defaults.set(hotkeyCode, forKey: "hotkeyCode"); onHotkeyChange?() } }
    @Published var hotkeyModifiers: Int { didSet { defaults.set(hotkeyModifiers, forKey: "hotkeyModifiers"); onHotkeyChange?() } }
    /// When the key last actually arrived. Registering one proves nothing:
    /// another app may already own it, silently.
    @Published var hotkeyLastFired: Date?
    @Published var showsCat: Bool { didSet { defaults.set(showsCat, forKey: "showsCat") } }
    /// One animation held up to be looked at, or "" to let the cat choose.
    /// A tuning switch more than a preference, but remembering it costs
    /// nothing and a held animation is how you look at one at all — otherwise
    /// you wait up to half a minute for it to come round on its own.
    @Published var catAnimation: String { didSet { defaults.set(catAnimation, forKey: "catAnimation") } }
    /// How tall the cat's frame is, as a fraction of the screen. The frame,
    /// not the cat: it carries slack above and below so a leap has somewhere
    /// to go, and the cat fills about four fifths of it.
    @Published var catSize: Double { didSet { defaults.set(catSize, forKey: "catSize") } }
    @Published var showsCaption: Bool { didSet { defaults.set(showsCaption, forKey: "showsCaption") } }
    /// How far the cat boils, in cat pixels. 0 holds it perfectly still.
    @Published var catJitter: Double { didSet { defaults.set(catJitter, forKey: "catJitter") } }

    var onHotkeyChange: (() -> Void)?
    /// How strong the look is, 1…5. One number for both looks.
    @Published var strength: Int { didSet { defaults.set(strength, forKey: "strength") } }

    /// Named rather than `.standard`, because the development build is a
    /// separate bundle identifier — it has to be, or the two signatures fight
    /// over one Screen Recording grant — and a separate identifier would
    /// otherwise mean a separate set of sliders.
    private let defaults = UserDefaults(suiteName: "com.dora.away-blur") ?? .standard

    init() {
        isEnabled = defaults.object(forKey: "enabled") as? Bool ?? true
        idleDelay = defaults.object(forKey: "idleDelay") as? Double ?? 90
        showsCat = defaults.object(forKey: "showsCat") as? Bool ?? true
        catAnimation = defaults.string(forKey: "catAnimation") ?? ""
        catSize = defaults.object(forKey: "catSize") as? Double ?? 0.20
        showsCaption = defaults.object(forKey: "showsCaption") as? Bool ?? true
        catJitter = defaults.object(forKey: "catJitter") as? Double ?? 0.5
        hotkeyCode = defaults.object(forKey: "hotkeyCode") as? Int ?? 11 // B
        hotkeyModifiers = defaults.object(forKey: "hotkeyModifiers") as? Int ?? (optionKey | shiftKey | cmdKey) // ⌥⇧⌘
        look = Look(rawValue: defaults.string(forKey: "look") ?? "") ?? .ambient
        strength = defaults.object(forKey: "strength") as? Int ?? 3
    }

    /// The settings for the look in use.
    var current: LookSettings { .look(look, strength: strength) }

    private func store(_ value: Bool, _ key: String) { defaults.set(value, forKey: key) }
    private func store(_ value: String, _ key: String) { defaults.set(value, forKey: key) }
}
