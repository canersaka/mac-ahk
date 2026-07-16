import SwiftUI

@main
struct MacAHKApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
        }

        // Quick access while the main window is closed; the app keeps
        // running so hotkeys stay live.
        MenuBarExtra("MacAHK", systemImage: menuBarSymbol) {
            Button("Record New Macro") { app.beginRecording() }
                .disabled(app.isBusy)
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
