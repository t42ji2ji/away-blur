import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// Whether anyone is using the Mac, as far as the system can tell.
enum Presence {

    /// Seconds since the last keyboard or mouse event. Needs no permission.
    static func idleSeconds() -> Double {
        guard let any = CGEventType(rawValue: ~UInt32(0)) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
    }

    /// True while some app is holding the display awake.
    ///
    /// Anything playing video or running a call takes one of these out, which
    /// is exactly the case idle seconds gets wrong: you are sitting there
    /// watching, and the keyboard has not moved in ten minutes.
    static func displayHeldAwake() -> Bool {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let levels = status?.takeRetainedValue() as? [String: Int] else { return false }
        // The two type names as IOKit spells them.
        return (levels["PreventUserIdleDisplaySleep"] ?? 0) > 0
            || (levels["NoDisplaySleepAssertion"] ?? 0) > 0
    }

    /// The apps holding it, for the settings panel to show.
    static func holders() -> [String] {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let table = byProcess?.takeRetainedValue() as? [AnyHashable: [[String: Any]]] else { return [] }
        var names: Set<String> = []
        for assertions in table.values {
            for assertion in assertions {
                guard let type = assertion["AssertType"] as? String,
                      type == "PreventUserIdleDisplaySleep" || type == "NoDisplaySleepAssertion" else { continue }
                if let name = assertion["Process Name"] as? String { names.insert(name) }
            }
        }
        return names.sorted()
    }
}
