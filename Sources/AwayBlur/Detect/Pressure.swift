import Foundation

/// How close the machine is to running out of memory, as the system itself
/// reckons it.
///
/// Pressure is not usage. macOS answers normal for as long as it can still
/// find pages to reclaim, so a Mac at 82% used with fifteen gigabytes
/// compressed is still normal — which is the whole reason this is worth a
/// colour in the menu bar. Something that is always on is not read.
///
/// The dispatch source fires on the way across a level and never on arrival,
/// so the first answer has to come out of the kernel directly.
enum Pressure {

    enum Level {
        case normal, warning, critical
    }

    private(set) static var level = current()
    private static var source: DispatchSourceMemoryPressure?

    /// Calls back on the main queue when the level changes, and at no other
    /// time — the menu bar icon is rebuilt on each one.
    static func watch(_ changed: @escaping @MainActor (Level) -> Void) {
        let made = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .main)
        made.setEventHandler {
            let now = reading(made.data)
            guard now != level else { return }
            level = now
            MainActor.assumeIsolated { changed(now) }
        }
        made.activate()
        source = made
    }

    static func level(named name: String) -> Level? {
        switch name {
        case "normal": return .normal
        case "warning", "warn": return .warning
        case "critical", "crit": return .critical
        default: return nil
        }
    }

    /// `awayblur://pressure/warning`. The real thing happens a few times a
    /// month and the colour has to be looked at before then. It holds until
    /// the machine crosses a level for real.
    static func pretend(_ level: Level) {
        Pressure.level = level
    }

    /// 1 normal, 2 warning, 4 critical.
    private static func current() -> Level {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else {
            return .normal
        }
        switch value {
        case 4: return .critical
        case 2: return .warning
        default: return .normal
        }
    }

    private static func reading(_ event: DispatchSource.MemoryPressureEvent) -> Level {
        if event.contains(.critical) { return .critical }
        if event.contains(.warning) { return .warning }
        return .normal
    }
}
