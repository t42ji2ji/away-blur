import AppKit
import SwiftUI

/// Click, then press. A local monitor is enough because the panel has focus
/// while you are setting this, and it costs no permission.
private struct ShortcutRecorder: View {
    @ObservedObject var preferences: Preferences
    @State private var listening = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(listening ? "Press a key…"
                             : Hotkey.describe(keyCode: preferences.hotkeyCode,
                                               modifiers: preferences.hotkeyModifiers)) {
                listening ? stop() : start()
            }
            .buttonStyle(.bordered)
            .frame(minWidth: 96)

            if listening {
                Text("⎋ to cancel").font(.callout).foregroundStyle(.secondary)
            } else if let fired = preferences.hotkeyLastFired {
                Label(fired.timeIntervalSinceNow > -3 ? "Just arrived" : "Arrives",
                      systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
            Spacer()
        }
    }

    private func start() {
        listening = true
        preferences.hotkeyLastFired = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(53) { stop(); return nil }   // escape
            let carbon = Hotkey.carbonModifiers(from: event.modifierFlags)
            guard carbon != 0 else { return nil }  // a bare key would fire everywhere
            preferences.hotkeyCode = Int(event.keyCode)
            preferences.hotkeyModifiers = carbon
            stop()
            return nil
        }
    }

    private func stop() {
        listening = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    let controller: BlurController
    @State private var holders: [String] = []

    var body: some View {
        Form {
            // Everything that decides you are gone. None of it belongs to a look.
            Section {
                row("Idle for", $preferences.idleDelay, 5...600, "%.0f s")
                Toggle("Check the camera first", isOn: $preferences.usesCamera)
                if preferences.usesCamera {
                    row("A face buys", $preferences.cameraRecheck, 15...300, "%.0f s")
                        .disabled(FaceCheck.isDenied)
                }
                LabeledContent("Blur now") { ShortcutRecorder(preferences: preferences) }
            } header: {
                Text("When to blur")
            } footer: {
                VStack(alignment: .leading, spacing: 3) {
                    if preferences.usesCamera, FaceCheck.isDenied {
                        Label("Camera access is off in System Settings.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Text(holders.isEmpty
                         ? "Nothing is holding the display awake."
                         : "\(holders.joined(separator: ", ")) is holding the display awake — it will not blur.")
                    if preferences.hotkeyLastFired == nil {
                        Text("Press the shortcut once to check it arrives — another app can hold a combination without saying so.")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }

            // Everything that decides what it turns into.
            Section {
                Picker("", selection: $preferences.look) {
                    ForEach(Look.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(preferences.look.blurb)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                row("Blur", $preferences.current.blurRadius, 8...240, "%.0f px")
                row("Dim", $preferences.current.dim, 0...0.85, "%.0f%%", scale: 100)
                row("Wash", $preferences.current.wash, 0...0.8, "%.0f%%", scale: 100)
                row("Grain", $preferences.current.grain, 0...1, "%.0f%%", scale: 100)
                row("Fade in", $preferences.current.fadeIn, 0.1...3, "%.2f s")
                row("Fade out", $preferences.current.fadeOut, 0.05...2, "%.2f s")

                Toggle("Float a cat in the middle", isOn: $preferences.showsCat)
                if preferences.showsCat {
                    row("Its size", $preferences.catSize, 0.05...0.35, "%.0f%%", scale: 100)
                    row("Its jitter", $preferences.catJitter, 0...3, "%.1f px")
                    Picker("Its face", selection: $preferences.catFace) {
                        ForEach(Cat.faces) { Text($0.id).tag($0.id) }
                        Divider()
                        Text("A different one each time").tag("random")
                    }
                }

                Toggle("Say what the machine is doing", isOn: $preferences.showsCaption)

                Toggle("Hold it up while I tune", isOn: Binding(
                    get: { controller.isPreviewing },
                    set: { controller.isPreviewing = $0 }
                ))
            } header: {
                HStack {
                    Text("How it looks")
                    Spacer()
                    Button("Reset \(preferences.look.title)") { preferences.resetCurrent() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 430)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            holders = Presence.holders()
        }
        .onAppear { holders = Presence.holders() }
    }

    private func row(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                     _ format: String, scale: Double = 1) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range)
                Text(String(format: format, value.wrappedValue * scale))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}

/// A panel that floats above the overlay, so the controls stay usable while
/// the screen behind them is frosted.
@MainActor
final class SettingsPanel {
    private var panel: NSPanel?
    private let preferences: Preferences
    private let controller: BlurController

    var isVisible: Bool { panel?.isVisible ?? false }

    init(preferences: Preferences, controller: BlurController) {
        self.preferences = preferences
        self.controller = controller
    }

    func show() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingView(rootView: SettingsView(preferences: preferences, controller: controller))
        // Not `.utilityWindow`: that is the old inspector-panel title bar, with
        // shrunken traffic lights to match. A panel is still a panel without it
        // — it floats and it does not take focus — it just looks like the rest
        // of the system.
        let made = NSPanel(contentRect: .zero,
                           styleMask: [.titled, .closable, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        made.title = "Away Blur"
        made.titlebarAppearsTransparent = true
        made.contentView = hosting
        made.isFloatingPanel = true
        made.hidesOnDeactivate = false
        made.isReleasedWhenClosed = false
        made.isMovableByWindowBackground = true
        made.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        made.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        made.setContentSize(hosting.fittingSize)
        made.center()
        panel = made
        made.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
