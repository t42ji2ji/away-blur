import AppKit
import Carbon.HIToolbox

/// One system-wide key. Carbon rather than an `NSEvent` global monitor,
/// because a monitor would cost an Accessibility permission to watch every
/// keystroke on the machine, to catch one.
///
/// Registering succeeds even when something else already owns the
/// combination — it simply never fires — and a remapper like Karabiner can
/// swallow a whole family of them before they ever reach here. So the
/// combination is the person's to choose, and the settings panel says whether
/// it has actually arrived.
@MainActor
final class Hotkey {

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
                MainActor.assumeIsolated {
                    FileLog.write("hotkey: fired")
                    Hotkey.installed?.action()
                }
            }
            return noErr
        }, 1, &type, nil, &handler)
        guard status == noErr else {
            FileLog.write("hotkey: InstallEventHandler failed with \(status)")
            return nil
        }
        Hotkey.installed = self
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// Points the key at a new combination. False if the system refused it,
    /// which is not the same as it working.
    @discardableResult
    func bind(keyCode: Int, modifiers: Int) -> Bool {
        if let reference {
            UnregisterEventHotKey(reference)
            self.reference = nil
        }
        let id = EventHotKeyID(signature: OSType(0x41574252), id: 1) // 'AWBR'
        var fresh: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id,
                                         GetApplicationEventTarget(), 0, &fresh)
        guard status == noErr else {
            FileLog.write("hotkey: \(Hotkey.describe(keyCode: keyCode, modifiers: modifiers)) refused with \(status)")
            return false
        }
        reference = fresh
        FileLog.write("hotkey: bound to \(Hotkey.describe(keyCode: keyCode, modifiers: modifiers))")
        return true
    }

    // MARK: - Names

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var carbon = 0
        if flags.contains(.command) { carbon |= cmdKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        return carbon
    }

    static func describe(keyCode: Int, modifiers: Int) -> String {
        var text = ""
        if modifiers & controlKey != 0 { text += "⌃" }
        if modifiers & optionKey != 0 { text += "⌥" }
        if modifiers & shiftKey != 0 { text += "⇧" }
        if modifiers & cmdKey != 0 { text += "⌘" }
        return text + name(of: keyCode)
    }

    private static let named: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
        kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// What is printed on the key, asked of the current keyboard layout.
    static func name(of keyCode: Int) -> String {
        if let known = named[keyCode] { return known }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "key \(keyCode)"
        }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &dead, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return "key \(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}
