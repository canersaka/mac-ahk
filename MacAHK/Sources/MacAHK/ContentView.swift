import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @State private var selection: UUID?
    @State private var capturingHotkeyFor: Macro?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 620, minHeight: 420)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) { statusBar }
        .sheet(item: $app.draft) { draft in
            SaveRecordingSheet(draft: draft)
        }
        .sheet(item: $capturingHotkeyFor) { macro in
            HotkeyCaptureSheet(macro: macro)
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            if !Permissions.allGranted {
                PermissionsBanner()
            }
            Section("Macros") {
                ForEach(app.store.macros) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(m.name)
                            Spacer()
                            if let hk = m.hotkey {
                                Text(hk.display)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(m.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .tag(m.id)
                    .contextMenu {
                        Button("Play") { app.play(m) }
                        Button("Set Hotkey…") { capturingHotkeyFor = m }
                        if m.hotkey != nil {
                            Button("Clear Hotkey") { app.setHotkey(nil, for: m) }
                        }
                        Divider()
                        Button("Delete", role: .destructive) { app.delete(m) }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
    }

    @ViewBuilder
    private var detail: some View {
        if case .countdown(let n) = app.mode {
            bigState(symbol: "record.circle", color: .red,
                     title: "Starting in \(n)…",
                     subtitle: "Switch to the app you want to automate.")
        } else if app.mode == .recording {
            bigState(symbol: "record.circle.fill", color: .red,
                     title: "Recording",
                     subtitle: "Everything you do is being captured.\nPress Esc to finish.")
        } else if case .playing(let name, let loop, let total) = app.mode {
            bigState(symbol: "play.circle.fill", color: .green,
                     title: "Playing “\(name)”",
                     subtitle: "Loop \(loop) of \(total > 0 ? String(total) : "∞") — press Esc to stop.")
        } else if let m = app.store.macro(id: selection) {
            MacroDetail(macro: m, capturingHotkeyFor: $capturingHotkeyFor)
        } else {
            bigState(symbol: "cursorarrow.click.2", color: .secondary,
                     title: "No macro selected",
                     subtitle: "Record something new or pick a macro from the list.")
        }
    }

    private func bigState(symbol: String, color: Color, title: String,
                          subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 56))
                .foregroundStyle(color)
            Text(title).font(.title2.bold())
            Text(subtitle)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                app.beginRecording()
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .disabled(app.isBusy)

            Button {
                if let m = app.store.macro(id: selection) { app.play(m) }
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(app.isBusy || selection == nil)

            Button {
                app.stopAll()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(!app.isBusy)
        }
    }

    private var statusBar: some View {
        HStack {
            Text(app.status)
                .font(.callout)
                .lineLimit(1)
            Spacer()
            Toggle("Capture mouse movement", isOn: $app.captureMoves)
                .toggleStyle(.checkbox)
                .font(.callout)
                .disabled(app.isBusy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

struct MacroDetail: View {
    @EnvironmentObject var app: AppState
    let macro: Macro
    @Binding var capturingHotkeyFor: Macro?
    @State private var name: String = ""

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .onSubmit { app.rename(macro, to: name) }
                LabeledContent("Recorded", value: macro.created.formatted(
                    date: .abbreviated, time: .shortened))
                LabeledContent("Contents", value: macro.summary)
                LabeledContent("Hotkey") {
                    HStack {
                        Text(macro.hotkey?.display ?? "none")
                            .font(.body.monospaced())
                        Button("Change…") { capturingHotkeyFor = macro }
                        if macro.hotkey != nil {
                            Button("Clear") { app.setHotkey(nil, for: macro) }
                        }
                    }
                }
            }
            Section("Playback") {
                Stepper(value: $app.loops, in: 0...99999) {
                    LabeledContent("Loops",
                                   value: app.loops == 0 ? "∞ (until Esc)"
                                                         : "\(app.loops)")
                }
                VStack(alignment: .leading) {
                    LabeledContent("Speed",
                                   value: String(format: "%.2f×", app.speed))
                    Slider(value: $app.speed, in: 0.25...4.0)
                }
                Button {
                    app.play(macro)
                } label: {
                    Label("Play “\(macro.name)”", systemImage: "play.fill")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(app.isBusy)
            }
        }
        .formStyle(.grouped)
        .onAppear { name = macro.name }
        .onChange(of: macro.id) { _ in name = macro.name }
    }
}

struct SaveRecordingSheet: View {
    @EnvironmentObject var app: AppState
    let draft: DraftRecording
    @State private var name = ""

    var body: some View {
        VStack(spacing: 14) {
            Text("Recorded \(draft.events.count) events")
                .font(.headline)
            TextField("Macro name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(save)
            HStack {
                Button("Discard", role: .cancel) { app.discardDraft() }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        app.saveDraft(named: trimmed)
    }
}

// Captures the next key combo pressed while the sheet is frontmost, via a
// local event monitor — no global listening involved.
struct HotkeyCaptureSheet: View {
    @EnvironmentObject var app: AppState
    let macro: Macro
    @Environment(\.dismiss) private var dismiss
    @State private var monitor: Any?
    @State private var preview = "Press a key combo…"

    var body: some View {
        VStack(spacing: 14) {
            Text("Hotkey for “\(macro.name)”").font(.headline)
            Text(preview)
                .font(.title3.monospaced())
                .frame(width: 260, height: 40)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Text("Esc cancels · Delete clears the hotkey")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Cancel", role: .cancel) { dismiss() }
        }
        .padding(24)
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                handle(e)
                return nil  // swallow the keystroke
            }
        }
        .onDisappear {
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
        }
    }

    private func handle(_ e: NSEvent) {
        if e.keyCode == 53 {  // Esc
            dismiss()
            return
        }
        if e.keyCode == 51 {  // Delete
            app.setHotkey(nil, for: macro)
            dismiss()
            return
        }
        let mods = e.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
        let hk = Hotkey(keyCode: e.keyCode, modifiers: mods.rawValue)
        preview = hk.display
        app.setHotkey(hk, for: macro)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { dismiss() }
    }
}

struct PermissionsBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Permissions needed", systemImage: "lock.shield")
                .font(.headline)
            if !Permissions.inputMonitoring {
                Button("Grant Input Monitoring…") {
                    Permissions.requestInputMonitoring()
                    Permissions.openInputMonitoringSettings()
                }
            }
            if !Permissions.accessibility {
                Button("Grant Accessibility…") {
                    Permissions.requestAccessibility()
                    Permissions.openAccessibilitySettings()
                }
            }
            Text("Recording needs Input Monitoring; playback needs Accessibility. Relaunch after granting.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}
