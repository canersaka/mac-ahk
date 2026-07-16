import SwiftUI

@main
struct MacAHKApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
                .onAppear {
                    // Fire the TCC request calls up front: this makes
                    // macOS add MacAHK to the Input Monitoring and
                    // Accessibility lists automatically, so granting is
                    // just flipping a toggle — no hunting with the +
                    // button in System Settings.
                    if !Permissions.inputMonitoring {
                        Permissions.requestInputMonitoring()
                    }
                    if !Permissions.accessibility {
                        Permissions.requestAccessibility()
                    }
                }
        }

        // Quick access while the main window is closed; the app keeps
        // running so hotkeys stay live.
        MenuBarExtra("MacAHK", systemImage: menuBarSymbol) {
            Button(recordMenuTitle) { app.toggleRecording() }
                .disabled(app.isBusy && !app.isRecordingOrCounting)
            if app.isBusy {
                Button("Stop (Esc)") { app.stopAll() }
            }
            Divider()
            ForEach(app.store.macros) { m in
                Button(menuTitle(for: m)) { app.play(m) }
                    .disabled(app.isBusy)
            }
            if app.store.macros.isEmpty {
                Text("No macros yet")
            }
            Divider()
            Button("Quit MacAHK") { NSApplication.shared.terminate(nil) }
        }
    }

    private var recordMenuTitle: String {
        let hint = app.recordHotkey.map { "  (\($0.display))" } ?? ""
        return app.isRecordingOrCounting ? "Stop Recording\(hint)"
                                         : "Record New Macro\(hint)"
    }

    private var menuBarSymbol: String {
        switch app.mode {
        case .recording, .countdown: return "record.circle.fill"
        case .playing: return "play.circle.fill"
        case .idle: return "cursorarrow.click.badge.clock"
        }
    }

    private func menuTitle(for m: Macro) -> String {
        if let hk = m.hotkey { return "\(m.name)  (\(hk.display))" }
        return m.name
    }
}
