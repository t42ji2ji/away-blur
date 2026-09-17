import AppKit
import SwiftUI

private struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    let controller: BlurController
    @State private var holders: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $preferences.look) {
                ForEach(Look.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Toggle("Hold the blur up while I tune", isOn: Binding(
                get: { controller.isPreviewing },
                set: { controller.isPreviewing = $0 }
            ))
            .toggleStyle(.switch)

            Divider()

            Group {
                slider("Blur", $preferences.current.blurRadius, 8...240, "%.0f px")
                slider("Dim", $preferences.current.dim, 0...0.85, "%.0f%%", scale: 100)
                slider("Wash", $preferences.current.wash, 0...0.8, "%.0f%%", scale: 100)
                slider("Grain", $preferences.current.grain, 0...1, "%.0f%%", scale: 100)
            }

            Divider()

            Group {
                slider("Fade in", $preferences.current.fadeIn, 0.1...3, "%.2f s")
                slider("Fade out", $preferences.current.fadeOut, 0.05...2, "%.2f s")
            }

            Divider()

            slider("Idle before blur", $preferences.idleDelay, 5...600, "%.0f s")

            Toggle("Look through the camera before blurring", isOn: $preferences.usesCamera)
                .toggleStyle(.switch)
            if preferences.usesCamera {
                slider("Face holds it for", $preferences.cameraRecheck, 15...300, "%.0f s")
            }

            Divider()

            HStack {
                Text(holders.isEmpty ? "Nothing is holding the display awake"
                                     : "Held awake by \(holders.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset \(preferences.look.title)") { preferences.resetCurrent() }
                    .controlSize(.small)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            holders = Presence.holders()
        }
        .onAppear { holders = Presence.holders() }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        _ format: String, scale: Double = 1) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 106, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue * scale))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }
}

/// A panel that floats above the overlay, so the sliders stay usable while
/// the screen behind them is blurred.
@MainActor
final class SettingsPanel {
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }
    private let preferences: Preferences
    private let controller: BlurController

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
        let view = SettingsView(preferences: preferences, controller: controller)
        let hosting = NSHostingView(rootView: view)
        let made = NSPanel(contentRect: .zero,
                           styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        made.title = "Away Blur"
        made.contentView = hosting
        made.isFloatingPanel = true
        made.hidesOnDeactivate = false
        made.isReleasedWhenClosed = false
        made.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        made.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        made.setContentSize(hosting.fittingSize)
        made.center()
        panel = made
        made.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
