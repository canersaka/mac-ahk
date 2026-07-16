import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @State private var capturingHotkeyFor: Macro?
    @State private var capturingRecordHotkey = false
    @State private var importingScript = false

    var body: some View {
        // The status bar lives outside the navigation layout so it can
        // never overlap the editor's controls.
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebar
            } detail: {
                detail
            }
            .toolbar { toolbarContent }
            Divider()
            statusBar
        }
        .frame(minWidth: 700, minHeight: 500)
        .sheet(item: $app.draft) { draft in
            SaveRecordingSheet(draft: draft)
        }
        .sheet(item: $capturingHotkeyFor) { macro in
            HotkeyCaptureSheet(
                title: "Hotkey for “\(macro.name)”",
                allowClear: macro.hotkey != nil,
                onCapture: { hk in app.setHotkey(hk, for: macro) })
        }
        .sheet(isPresented: $capturingRecordHotkey) {
            HotkeyCaptureSheet(
                title: "Recording hotkey (starts and stops recording)",
                allowClear: app.recordHotkey != nil,
                onCapture: { hk in app.recordHotkey = hk })
        }
        .sheet(isPresented: $importingScript) {
            ImportScriptSheet()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $app.selection) {
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
                                Button("Clear Hotkey") {
                                    app.setHotkey(nil, for: m)
                                }
                            }
                            Divider()
                            Button("Copy as Script") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    ScriptParser.export(m), forType: .string)
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                app.delete(m)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button {
                    app.createEmptyMacro()
                } label: {
                    Label("New Macro", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button {
                    importingScript = true
                } label: {
                    Label("Import Script", systemImage: "doc.text")
                }
                .buttonStyle(.borderless)
                .help("Create a macro from a MacAHK or AutoHotkey script")
            }
            .padding(8)
        }
        .navigationSplitViewColumnWidth(min: 230, ideal: 270)
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
                     subtitle: "Everything you do is being captured.\nPress Esc\(app.recordHotkey.map { " or \($0.display)" } ?? "") to finish.")
        } else if case .playing(let name, let loop, let total) = app.mode {
            bigState(symbol: "play.circle.fill", color: .green,
                     title: "Playing “\(name)”",
                     subtitle: "Loop \(loop) of \(total > 0 ? String(total) : "∞") — press Esc to stop.")
        } else if let m = app.store.macro(id: app.selection) {
            MacroEditor(macro: m, capturingHotkeyFor: $capturingHotkeyFor)
                .id(m.id)
        } else {
            homePage
        }
    }

    // The main page: shown when nothing is selected.
    private var homePage: some View {
        VStack(spacing: 18) {
            Image(systemName: "cursorarrow.click.2")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("MacAHK").font(.title.bold())
            Text("Record your mouse and keyboard, or build a macro step by step.")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    app.beginRecording()
                } label: {
                    Label("Record a Macro", systemImage: "record.circle")
                        .frame(width: 160)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)

                Button {
                    app.createEmptyMacro()
                } label: {
                    Label("New Empty Macro", systemImage: "plus")
                        .frame(width: 160)
                }
                .controlSize(.large)

                Button {
                    importingScript = true
                } label: {
                    Label("Import Script", systemImage: "doc.text")
                        .frame(width: 160)
                }
                .controlSize(.large)
            }
            if let hk = app.recordHotkey {
                Text("Recording hotkey: \(hk.display)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        ToolbarItemGroup(placement: .navigation) {
            Button {
                app.selection = nil
            } label: {
                Label("Home", systemImage: "house")
            }
            .disabled(app.selection == nil)
            .help("Back to the main page")

            Button {
                app.createEmptyMacro()
            } label: {
                Label("New Macro", systemImage: "plus")
            }
            .help("Create an empty macro and build it step by step")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                app.beginRecording()
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .disabled(app.isBusy)
            .help(app.selection == nil
                  ? "Record a new macro"
                  : "Record — you can append to the selected macro when done")

            Button {
                if let m = app.store.macro(id: app.selection) { app.play(m) }
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(app.isBusy || app.selection == nil)

            Button {
                app.stopAll()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(!app.isBusy)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text(app.status)
                .font(.callout)
                .lineLimit(1)
            Spacer()
            Button {
                capturingRecordHotkey = true
            } label: {
                Label(
                    app.recordHotkey.map { "Recording hotkey: \($0.display)" }
                        ?? "Set recording hotkey…",
                    systemImage: "record.circle")
                .font(.callout)
            }
            .buttonStyle(.borderless)
            .help("Global hotkey that starts and stops recording")
            Toggle("Record mouse path", isOn: $app.captureMoves)
                .toggleStyle(.checkbox)
                .font(.callout)
                .disabled(app.isBusy)
                .help("Also record cursor movement between clicks, so playback moves the mouse like you did instead of jumping between click points. Makes macros bigger; off is fine for most uses.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - macro editor

struct MacroEditor: View {
    @EnvironmentObject var app: AppState
    let macro: Macro
    @Binding var capturingHotkeyFor: Macro?
    @State private var name: String = ""
    @State private var stepSelection: UUID?
    @State private var addingAction = false
    @State private var editingStep: MacroItem?

    // Always read the live copy from the store so edits show immediately.
    private var current: Macro { app.store.macro(id: macro.id) ?? macro }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stepsList
            Divider()
            footer
        }
        .onAppear { name = macro.name }
        .sheet(isPresented: $addingAction) {
            AddActionSheet { item in
                app.insertStep(item, into: macro.id, after: stepSelection)
            }
        }
        .sheet(item: $editingStep) { item in
            EditStepSheet(macroID: macro.id, item: item)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .onSubmit { app.rename(current, to: name) }
            LabeledContent("Hotkey") {
                Button(current.hotkey?.display ?? "none") {
                    capturingHotkeyFor = current
                }
            }
            Spacer()
            Stepper(value: $app.loops, in: 0...99999) {
                Text("Loops: \(app.loops == 0 ? "∞" : String(app.loops))")
            }
            HStack(spacing: 6) {
                Text(String(format: "%.2f×", app.speed))
                    .font(.callout.monospacedDigit())
                Slider(value: $app.speed, in: 0.25...4.0)
                    .frame(width: 110)
            }
        }
        .padding(10)
    }

    private var stepsList: some View {
        List(selection: $stepSelection) {
            ForEach(Array(current.items.enumerated()), id: \.element.id) {
                index, item in
                stepRow(index: index, item: item)
            }
            .onMove { from, to in
                app.modify(macro.id) { $0.items.move(fromOffsets: from,
                                                     toOffset: to) }
            }
            .onDelete { offsets in
                app.modify(macro.id) { $0.items.remove(atOffsets: offsets) }
            }

            if current.items.isEmpty {
                Text("No steps yet. Use ＋ to add actions, record with this macro selected to append, or import a script.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func stepRow(index: Int, item: MacroItem) -> some View {
        HStack {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .trailing)
            stepIcon(item)
            Text(item.label)
            if let cond = item.condition {
                Text(cond.label)
                    .font(.caption)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.orange.opacity(0.18),
                                in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.orange)
            }
            if let rep = item.repeats {
                Text(rep.label)
                    .font(.caption)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.blue.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.blue)
            }
            Spacer()
            Text(String(format: "+%.2fs", item.delay))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .tag(item.id)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editingStep = item }
        .contextMenu {
            Button("Edit…") { editingStep = item }
            Button("Duplicate") {
                app.duplicateStep(item.id, in: macro.id)
            }
            if item.convertedAction != nil {
                Button("Convert to Editable Action") {
                    app.convertStepToAction(item.id, in: macro.id)
                }
            }
            Divider()
            Button("Delete", role: .destructive) {
                app.modify(macro.id) { m in
                    m.items.removeAll { $0.id == item.id }
                }
            }
        }
    }

    @ViewBuilder
    private func stepIcon(_ item: MacroItem) -> some View {
        switch item.payload {
        case .raw:
            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
                .help("Recorded event (replayed verbatim) — right-click to edit or convert")
        case .action:
            Image(systemName: "hammer")
                .foregroundStyle(.blue)
                .help("Manual action — right-click or double-click to edit")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                addingAction = true
            } label: {
                Image(systemName: "plus")
            }
            .help("Add an action after the selected step (or at the end)")

            Button {
                if let sel = stepSelection {
                    app.modify(macro.id) { m in
                        m.items.removeAll { $0.id == sel }
                    }
                    stepSelection = nil
                }
            } label: {
                Image(systemName: "minus")
            }
            .disabled(stepSelection == nil)
            .help("Remove the selected step")

            Button {
                if let sel = stepSelection,
                   let item = current.items.first(where: { $0.id == sel }) {
                    editingStep = item
                }
            } label: {
                Image(systemName: "pencil")
            }
            .disabled(stepSelection == nil)
            .help("Edit the selected step (delay, repeat, condition, parameters)")

            Spacer()

            Text("Double-click or right-click a step to edit it · drag to reorder")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button {
                app.play(current)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(app.isBusy || current.items.isEmpty)
        }
        .padding(10)
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
            Text("MacAHK is already in both lists — just flip its toggle on (macOS will ask for your password or Touch ID), then relaunch. If a toggle seems stuck after an update, run ./build_app.sh --reset-perms and grant fresh.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}
