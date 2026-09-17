import AppKit
import Carbon.HIToolbox

/// One system-wide key. Carbon rather than an `NSEvent` global monitor,
/// because a monitor would cost an Accessibility permission to watch every
/// keystroke on the machine, to catch one.
@MainActor
final class Hotkey {

    /// Control-Option-Command-B: three modifiers, so nothing else wants it.
    static let keyCode = UInt32(kVK_ANSI_B)
    static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    static let title = "⌃⌥⌘B"

    private static var installed: Hotkey?

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init?(action: @escaping () -> Void) {
        self.action = action

        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Hotkey.installed?.action() }
            }
            return noErr
        }, 1, &type, nil, &handler)
        guard status == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x41574252), id: 1) // 'AWBR'
        guard RegisterEventHotKey(Hotkey.keyCode, Hotkey.modifiers, id,
                                  GetApplicationEventTarget(), 0, &reference) == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
        Hotkey.installed = self
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
