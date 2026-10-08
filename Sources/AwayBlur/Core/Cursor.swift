import CoreGraphics

/// Takes the pointer off the frost while it is up.
///
/// The window server only lets the frontmost app hide the cursor, and Away
/// Blur never is. The connection property below is private, and it is the
/// one every cursor-hiding utility uses to be allowed from the background.
@MainActor
enum Cursor {

    @_silgen_name("_CGSDefaultConnection")
    private static func defaultConnection() -> Int32

    @_silgen_name("CGSSetConnectionProperty")
    private static func setConnectionProperty(_ connection: Int32, _ target: Int32,
                                              _ key: CFString, _ value: CFTypeRef) -> CGError

    /// Hide and show are counted by the window server, so they have to pair.
    private static var isHidden = false

    static func hide() {
        guard !isHidden else { return }
        let connection = defaultConnection()
        _ = setConnectionProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        CGDisplayHideCursor(CGMainDisplayID())
        isHidden = true
    }

    static func show() {
        guard isHidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        isHidden = false
    }
}
