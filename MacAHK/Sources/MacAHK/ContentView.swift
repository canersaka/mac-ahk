import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @State private var capturingHotkeyFor: Macro?
    @State private var capturingRecordHotkey = false

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
                title: "Start/stop recording hotkey",
                allowClear: app.recordHotkey != nil,
                onCapture: { hk in app.recordHotkey = hk })
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
                        .frame(width: 170)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)

                Button {
                    app.createEmptyMacro()
                } label: {
                    Label("New Empty Macro", systemImage: "plus")
                        .frame(width: 170)
                }
                .controlSize(.large)
            }
            if let hk = app.recordHotkey {
                Text("Record hotkey: \(hk.display)")
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
                    app.recordHotkey.map { "Record: \($0.display)" }
                        ?? "Set record hotkey…",
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
            AddActionSheet { action, delay in
                app.insertAction(action, delay: delay, into: macro.id,
                                 after: stepSelection)
            }
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
                HStack {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 32, alignment: .trailing)
                    stepIcon(item)
                    Text(item.label)
                    Spacer()
                    Text(String(format: "+%.2fs", item.delay))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .tag(item.id)
            }
            .onMove { from, to in
                app.modify(macro.id) { $0.items.move(fromOffsets: from,
                                                     toOffset: to) }
            }
            .onDelete { offsets in
                app.modify(macro.id) { $0.items.remove(atOffsets: offsets) }
            }

            if current.items.isEmpty {
                Text("No steps yet. Use ＋ to add actions, or record on top of this macro's name.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func stepIcon(_ item: MacroItem) -> some View {
        switch item.payload {
        case .raw:
            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
                .help("Recorded event (replayed verbatim)")
        case .action:
            Image(systemName: "hammer")
                .foregroundStyle(.blue)
                .help("Manual action")
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

            if let sel = stepSelection,
               current.items.contains(where: { $0.id == sel }) {
                Divider().frame(height: 16)
                Text("Delay before step (s):")
                    .font(.callout)
                TextField("Delay", value: delayBinding(for: sel),
                          format: .number.precision(.fractionLength(0...3)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
            }

            Spacer()

            Text("Drag steps to reorder")
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

    private func delayBinding(for stepID: UUID) -> Binding<Double> {
        Binding(
            get: {
                app.store.macro(id: macro.id)?.items
                    .first { $0.id == stepID }?.delay ?? 0
            },
            set: { newValue in
                app.modify(macro.id) { m in
                    if let i = m.items.firstIndex(where: { $0.id == stepID }) {
                        m.items[i].delay = max(0, newValue)
                    }
                }
            })
    }
}

// MARK: - add action sheet

struct AddActionSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case click = "Click"
        case keyPress = "Key Press"
        case typeText = "Type Text"
        case scroll = "Scroll"
        case movePointer = "Move Pointer"
        case wait = "Wait"
        var id: String { rawValue }
    }

    let onAdd: (ManualAction, Double) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var kind: Kind = .click
    @State private var delay: Double = 0.1
    @State private var x: Double = 0
    @State private var y: Double = 0
    @State private var button: MouseButtonKind = .left
    @State private var clickCount = 1
    @State private var text = ""
    @State private var scrollDX = 0
    @State private var scrollDY = -120
    @State private var capturedKey: Hotkey?
    @State private var capturingKey = false
    @State private var keyMonitor: Any?
    @State private var captureCountdown: Int?

    var body: some View {
        VStack(spacing: 14) {
            Text("Add Action").font(.headline)
            Picker("Action", selection: $kind) {
                ForEach(Kind.allCases) { k in Text(k.rawValue).tag(k) }
            }
            .pickerStyle(.segmented)

            Form {
                fields
                LabeledContent("Delay before (s)") {
                    TextField("Delay", value: $delay,
                              format: .number.precision(.fractionLength(0...3)))
                        .frame(width: 80)
                }
            }
            .formStyle(.columns)

            HStack {
                Button("Cancel", role: .cancel) { cleanup(); dismiss() }
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onDisappear { cleanup() }
    }

    @ViewBuilder
    private var fields: some View {
        switch kind {
        case .click, .movePointer:
            LabeledContent("Position") {
                HStack {
                    TextField("x", value: $x, format: .number)
                        .frame(width: 70)
                    TextField("y", value: $y, format: .number)
                        .frame(width: 70)
                    Button(captureCountdown.map { "…\($0)" }
                           ?? "Capture cursor in 2s") {
                        captureCursorSoon()
                    }
                    .disabled(captureCountdown != nil)
                }
            }
            if kind == .click {
                LabeledContent("Button") {
                    Picker("", selection: $button) {
                        ForEach(MouseButtonKind.allCases) { b in
                            Text(b.rawValue).tag(b)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
                LabeledContent("Clicks") {
                    Picker("", selection: $clickCount) {
                        Text("single").tag(1)
                        Text("double").tag(2)
                        Text("triple").tag(3)
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
            }
        case .keyPress:
            LabeledContent("Key") {
                Button(capturedKey?.display
                       ?? (capturingKey ? "press keys…" : "click, then press keys")) {
                    startKeyCapture()
                }
                .font(.body.monospaced())
            }
        case .typeText:
            LabeledContent("Text") {
                TextField("text to type", text: $text)
                    .frame(width: 240)
            }
        case .scroll:
            LabeledContent("Amount (px)") {
                HStack {
                    TextField("dx", value: $scrollDX, format: .number)
                        .frame(width: 70)
                    TextField("dy", value: $scrollDY, format: .number)
                        .frame(width: 70)
                }
            }
            Text("Negative dy scrolls down, positive scrolls up.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .wait:
            Text("Waits for the delay below, then moves on.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var valid: Bool {
        switch kind {
        case .keyPress: return capturedKey != nil
        case .typeText: return !text.isEmpty
        default: return true
        }
    }

    private func add() {
        let action: ManualAction
        switch kind {
        case .click:
            action = .click(x: x, y: y, button: button, count: clickCount)
        case .movePointer:
            action = .movePointer(x: x, y: y)
        case .keyPress:
            guard let hk = capturedKey else { return }
            action = .keyPress(keyCode: hk.keyCode, modifiers: hk.modifiers)
        case .typeText:
            action = .typeText(text: text)
        case .scroll:
            action = .scroll(dx: scrollDX, dy: scrollDY)
        case .wait:
            action = .wait
        }
        cleanup()
        onAdd(action, delay)
        dismiss()
    }

    // Reads the cursor after a short countdown so you can move it where
    // you want the click to land. CGEvent coordinates match playback.
    private func captureCursorSoon() {
        captureCountdown = 2
        func tick() {
            guard let n = captureCountdown else { return }
            if n <= 0 {
                if let pos = CGEvent(source: nil)?.location {
                    x = pos.x
                    y = pos.y
                }
                captureCountdown = nil
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                captureCountdown = (captureCountdown ?? 1) - 1
                tick()
            }
        }
        tick()
    }

    private func startKeyCapture() {
        guard keyMonitor == nil else { return }
        capturingKey = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let mods = e.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .intersection([.command, .option, .control, .shift])
            capturedKey = Hotkey(keyCode: e.keyCode, modifiers: mods.rawValue)
            cleanup()
            return nil
        }
    }

    private func cleanup() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        capturingKey = false
    }
}

// MARK: - shared sheets

struct SaveRecordingSheet: View {
    @EnvironmentObject var app: AppState
    let draft: DraftRecording
    @State private var name = ""

    var body: some View {
        VStack(spacing: 14) {
            Text("Recorded \(draft.items.count) steps")
                .font(.headline)
            if let target = draft.appendTarget {
                Button {
                    app.appendDraftToTarget()
                } label: {
                    Label("Add to “\(target.name)”",
                          systemImage: "text.append")
                        .frame(width: 240)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                Text("or save as a new macro:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("Macro name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(save)
            HStack {
                Button("Discard", role: .cancel) { app.discardDraft() }
                Button(draft.appendTarget == nil ? "Save" : "Save as New",
                       action: save)
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
    let title: String
    let allowClear: Bool
    let onCapture: (Hotkey?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var monitor: Any?
    @State private var preview = "Press a key combo…"

    var body: some View {
        VStack(spacing: 14) {
            Text(title).font(.headline)
            Text(preview)
                .font(.title3.monospaced())
                .frame(width: 280, height: 40)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Text(allowClear ? "Esc cancels · Delete clears the hotkey"
                            : "Esc cancels")
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
        if e.keyCode == 51 && allowClear {  // Delete
            onCapture(nil)
            dismiss()
            return
        }
        let mods = e.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
        let hk = Hotkey(keyCode: e.keyCode, modifiers: mods.rawValue)
        preview = hk.display
        onCapture(hk)
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
