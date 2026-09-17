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
}

/// Everything one look is made of. Radius is in pixels at full strength.
struct LookSettings: Codable, Equatable {
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
    /// Look through the camera before blurring. Off unless asked for: it costs
    /// a camera permission and the green light every time it checks.
    @Published var usesCamera: Bool { didSet { defaults.set(usesCamera, forKey: "usesCamera") } }
    /// How long a face holds the screen before the camera is asked again.
    @Published var cameraRecheck: Double { didSet { defaults.set(cameraRecheck, forKey: "cameraRecheck") } }
    @Published var privacy: LookSettings { didSet { store(privacy, "privacy") } }
    @Published var ambient: LookSettings { didSet { store(ambient, "ambient") } }

    private let defaults = UserDefaults.standard

    init() {
        isEnabled = defaults.object(forKey: "enabled") as? Bool ?? true
        idleDelay = defaults.object(forKey: "idleDelay") as? Double ?? 90
        usesCamera = defaults.object(forKey: "usesCamera") as? Bool ?? false
        cameraRecheck = defaults.object(forKey: "cameraRecheck") as? Double ?? 60
        look = Look(rawValue: defaults.string(forKey: "look") ?? "") ?? .ambient
        privacy = Preferences.read("privacy", defaults) ?? .privacyDefaults
        ambient = Preferences.read("ambient", defaults) ?? .ambientDefaults
    }

    /// The settings for the look in use, readable and writable.
    var current: LookSettings {
        get { self[look] }
        set { self[look] = newValue }
    }

    subscript(look: Look) -> LookSettings {
        get {
            switch look {
            case .privacy: return privacy
            case .ambient: return ambient
            }
        }
        set {
            switch look {
            case .privacy: privacy = newValue
            case .ambient: ambient = newValue
            }
        }
    }

    func resetCurrent() {
        current = .defaults(for: look)
    }

    private static func read(_ key: String, _ defaults: UserDefaults) -> LookSettings? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LookSettings.self, from: data)
    }

    private func store(_ value: Bool, _ key: String) { defaults.set(value, forKey: key) }
    private func store(_ value: String, _ key: String) { defaults.set(value, forKey: key) }
    private func store(_ value: LookSettings, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
