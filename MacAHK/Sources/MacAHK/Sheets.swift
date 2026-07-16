import SwiftUI

// MARK: - reusable capture controls

// Reads the cursor after a short countdown so you can move it where you
// want. CGEvent coordinates match playback exactly.
struct CaptureCursorButton: View {
    var label = "Use my cursor position (2s countdown)"
    let onCapture: (CGPoint) -> Void
    @State private var countdown: Int?

    var body: some View {
        Button(countdown.map { "capturing in \($0)…" } ?? label) {
            countdown = 2
            tick()
        }
        .disabled(countdown != nil)
    }

    private func tick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let n = countdown else { return }
            if n <= 1 {
                if let pos = CGEvent(source: nil)?.location {
                    onCapture(pos)
                }
                countdown = nil
            } else {
                countdown = n - 1
                tick()
            }
        }
    }
}

// Captures the next key combo pressed while the app is frontmost.
struct KeyCaptureButton: View {
    var placeholder = "click, then press keys"
    @Binding var key: Hotkey?
    @EnvironmentObject var app: AppState
    @State private var monitor: Any?
    @State private var capturing = false

    var body: some View {
        Button {
            start()
        } label: {
            Text(capturing ? "press keys now…" : (key?.display ?? placeholder))
                .font(.body.monospaced())
                .frame(minWidth: 130)
        }
        .onDisappear { stop() }
    }

    private func start() {
        guard monitor == nil else { return }
        capturing = true
        app.suspendHotkeys(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let mods = e.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .intersection([.command, .option, .control, .shift])
            key = Hotkey(keyCode: e.keyCode, modifiers: mods.rawValue)
            stop()
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        capturing = false
        app.suspendHotkeys(false)
    }
}

// MARK: - condition editing

struct ConditionModel {
    var kind: Condition.Kind = .keyHeld
    var negated = false
    var key: Hotkey?
    var button: MouseButtonKind = .left
    var cmd = false, opt = false, ctrl = false, shift = false
    var x = 0.0, y = 0.0, w = 100.0, h = 100.0
    var r = 0, g = 0, b = 0
    var colorPicked = false
    var tolerance = 12.0
    var reference: Data?
    var text = ""

    init() {}

    init(from c: Condition) {
        kind = c.kind
        negated = c.negated
        key = Hotkey(keyCode: c.keyCode, modifiers: 0)
        button = c.button
        let f = NSEvent.ModifierFlags(rawValue: c.modifiers)
        cmd = f.contains(.command)
        opt = f.contains(.option)
        ctrl = f.contains(.control)
        shift = f.contains(.shift)
        x = c.x; y = c.y; w = c.w; h = c.h
        r = c.r; g = c.g; b = c.b
        colorPicked = c.kind == .pixelColor
        tolerance = c.tolerance
        reference = c.reference
        text = c.text
    }

    var modifiersRaw: UInt {
        var f: NSEvent.ModifierFlags = []
        if cmd { f.insert(.command) }
        if opt { f.insert(.option) }
        if ctrl { f.insert(.control) }
        if shift { f.insert(.shift) }
        return f.rawValue
    }

    var valid: Bool {
        switch kind {
        case .keyHeld: return key != nil
        case .modifiersHeld: return modifiersRaw != 0
        case .pixelColor: return colorPicked
        case .regionLooksLike, .imageOnScreen: return reference != nil
        case .appFrontmost, .windowTitled, .clipboardContains:
            return !text.trimmingCharacters(in: .whitespaces).isEmpty
        default: return true
        }
    }

    func build() -> Condition? {
        guard valid else { return nil }
        let keepsSnapshot = kind == .regionLooksLike || kind == .imageOnScreen
        return Condition(kind: kind, negated: negated,
                         keyCode: key?.keyCode ?? 0, button: button,
                         modifiers: modifiersRaw, x: x, y: y, w: w, h: h,
                         r: r, g: g, b: b, tolerance: tolerance,
                         reference: keepsSnapshot ? reference : nil,
                         text: text)
    }
}

struct ConditionFields: View {
    @Binding var model: ConditionModel

    var body: some View {
        Picker("When", selection: $model.kind) {
            ForEach(Condition.Kind.allCases) { k in
                Text(k.title).tag(k)
            }
        }
        .pickerStyle(.menu)

        Picker("Check that it", selection: $model.negated) {
            Text("is the case").tag(false)
            Text("is NOT the case").tag(true)
        }
        .pickerStyle(.menu)

        switch model.kind {
        case .keyHeld:
            LabeledContent("Key") {
                KeyCaptureButton(placeholder: "click, then press a key",
                                 key: $model.key)
            }
        case .mouseHeld:
            Picker("Button", selection: $model.button) {
                ForEach(MouseButtonKind.allCases) { b in
                    Text(b.rawValue).tag(b)
                }
            }
            .pickerStyle(.menu)
        case .modifiersHeld:
            LabeledContent("Modifiers") {
                HStack(spacing: 4) {
                    Toggle("⌘", isOn: $model.cmd)
                    Toggle("⌥", isOn: $model.opt)
                    Toggle("⌃", isOn: $model.ctrl)
                    Toggle("⇧", isOn: $model.shift)
                }
                .toggleStyle(.button)
            }
        case .pointerIn:
            regionFields
        case .pixelColor:
            screenRecordingRow
            LabeledContent("Pixel") {
                HStack(spacing: 6) {
                    NumberField(value: $model.x)
                    Text("×").foregroundStyle(.tertiary)
                    NumberField(value: $model.y)
                }
            }
            LabeledContent("") {
                CaptureCursorButton(label: "Pick pixel under cursor (2s)") {
                    point in
                    model.x = point.x
                    model.y = point.y
                    if let px = ScreenSampler.pixelRGB(at: point) {
                        model.r = px.r
                        model.g = px.g
                        model.b = px.b
                        model.colorPicked = true
                    }
                }
            }
            LabeledContent("Color") {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(red: Double(model.r) / 255,
                                    green: Double(model.g) / 255,
                                    blue: Double(model.b) / 255))
                        .frame(width: 28, height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(.quaternary))
                    Text(model.colorPicked
                         ? String(format: "#%02X%02X%02X",
                                  model.r, model.g, model.b)
                         : "not picked yet")
                        .font(.body.monospaced())
                        .foregroundStyle(model.colorPicked
                                         ? .primary : .secondary)
                }
            }
            toleranceRow(max: 40)
        case .regionLooksLike:
            screenRecordingRow
            regionFields
            snapshotRow
            LabeledContent("") {
                Text("Set the area first, arrange the screen how it should look, then capture. Playback compares the live area against this snapshot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            toleranceRow(max: 30)
        case .imageOnScreen:
            screenRecordingRow
            regionFields
            snapshotRow
            LabeledContent("") {
                Text("Frame the image with the area above and capture it. Playback then scans the entire screen for it, wherever it has moved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            toleranceRow(max: 30)
        case .appFrontmost:
            LabeledContent("App") {
                TextField("app name, e.g. Safari", text: $model.text)
                    .frame(width: 220)
            }
            LabeledContent("") {
                Text("Matches the frontmost app's name or bundle id, case-insensitively.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .windowTitled:
            LabeledContent("Title contains") {
                TextField("window title fragment", text: $model.text)
                    .frame(width: 220)
            }
            LabeledContent("") {
                Text("True while any open window's title (or its app's name) contains this text. Titles are only visible with the Screen Recording permission; app names always match.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .clipboardContains:
            LabeledContent("Clipboard contains") {
                TextField("text fragment", text: $model.text)
                    .frame(width: 220)
            }
        }
    }

    // Snapshot capture, shared by the fixed-region and find-anywhere
    // image conditions.
    private var snapshotRow: some View {
        LabeledContent("Snapshot") {
            HStack(spacing: 8) {
                if let data = model.reference,
                   let img = NSImage(data: data) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 72, maxHeight: 44)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(.quaternary))
                }
                CaptureCursorButton(
                    label: model.reference == nil
                        ? "Capture snapshot of area (2s)"
                        : "Recapture (2s)") { _ in
                    let rect = CGRect(x: model.x, y: model.y,
                                      width: max(model.w, 1),
                                      height: max(model.h, 1))
                    if let img = ScreenSampler.capture(rect: rect),
                       let png = ScreenSampler.png(img) {
                        model.reference = png
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var regionFields: some View {
        LabeledContent("Top-left") {
            HStack(spacing: 6) {
                NumberField(value: $model.x)
                Text("×").foregroundStyle(.tertiary)
                NumberField(value: $model.y)
            }
        }
        LabeledContent("") {
            CaptureCursorButton(label: "Set top-left from cursor (2s)") {
                model.x = $0.x
                model.y = $0.y
            }
        }
        LabeledContent("Size") {
            HStack(spacing: 6) {
                NumberField(value: $model.w)
                Text("×").foregroundStyle(.tertiary)
                NumberField(value: $model.h)
            }
        }
        LabeledContent("") {
            CaptureCursorButton(label: "Set bottom-right from cursor (2s)") {
                model.w = max(1, $0.x - model.x)
                model.h = max(1, $0.y - model.y)
            }
        }
    }

    private var screenRecordingRow: some View {
        ScreenRecordingGrantRows()
    }

    private func toleranceRow(max maxValue: Double) -> some View {
        LabeledContent("Tolerance") {
            HStack(spacing: 8) {
                Slider(value: $model.tolerance, in: 0...maxValue)
                    .frame(width: 140)
                Text(String(format: "%.0f%%", model.tolerance))
                    .font(.callout.monospacedDigit())
            }
        }
    }
}

// Shown wherever a screen-reading feature is configured before the
// Screen Recording permission has been granted.
struct ScreenRecordingGrantRows: View {
    var body: some View {
        if !Permissions.screenRecording {
            LabeledContent("Permission") {
                Button("Grant Screen Recording…") {
                    Permissions.requestScreenRecording()
                    Permissions.openScreenRecordingSettings()
                }
            }
            LabeledContent("") {
                Text("Pixel and image checks read the screen, which needs the Screen Recording permission (only used for these checks). Relaunch MacAHK after granting.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

// A right-aligned numeric field, the shape every sheet here uses.
struct NumberField: View {
    @Binding var value: Double
    var width: CGFloat = 64

    var body: some View {
        TextField("", value: $value,
                  format: .number.precision(.fractionLength(0...3)))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: width)
    }
}

struct IntField: View {
    @Binding var value: Int
    var width: CGFloat = 64

    var body: some View {
        TextField("", value: $value, format: .number)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: width)
    }
}

// MARK: - action editing

struct ActionFormModel {
    enum ActionKind: String, CaseIterable, Identifiable {
        case click = "Click"
        case keyPress = "Key Press"
        case typeText = "Type Text"
        case scroll = "Scroll"
        case movePointer = "Move Pointer"
        case clickImage = "Click Image on Screen"
        case openApp = "Open App"
        case openURL = "Open URL"
        case setClipboard = "Set Clipboard"
        case pasteClipboard = "Paste Clipboard"
        case notify = "Show Notification"
        case beep = "Beep"
        case wait = "Wait"
        case waitUntil = "Wait Until…"
        case goTo = "Go To Step"
        case stop = "Stop Playback"
        var id: String { rawValue }
    }

    var kind: ActionKind = .click
    var x = 0.0, y = 0.0
    var button: MouseButtonKind = .left
    var clickCount = 1
    var key: Hotkey?
    var text = ""
    var scrollDX = 0, scrollDY = -120
    var waitCondition = ConditionModel()
    var timeout = 0.0
    var goToStep = 1
    var goToTimes = 0
    // Click Image: the template snapshot plus the capture area used to
    // frame it (the area itself isn't stored in the action).
    var refData: Data?
    var refW = 100.0, refH = 60.0
    var tolerance = 12.0
    var moveOnly = false

    init() {}

    init(from action: ManualAction) {
        self.init()
        switch action {
        case .click(let ax, let ay, let abutton, let acount):
            kind = .click; x = ax; y = ay; button = abutton
            clickCount = acount
        case .movePointer(let ax, let ay):
            kind = .movePointer; x = ax; y = ay
        case .keyPress(let code, let mods):
            kind = .keyPress
            key = Hotkey(keyCode: code, modifiers: mods)
        case .typeText(let t):
            kind = .typeText; text = t
        case .scroll(let dx, let dy):
            kind = .scroll; scrollDX = dx; scrollDY = dy
        case .openApp(let name):
            kind = .openApp; text = name
        case .openURL(let url):
            kind = .openURL; text = url
        case .setClipboard(let t):
            kind = .setClipboard; text = t
        case .pasteClipboard:
            kind = .pasteClipboard
        case .clickImage(let reference, let atolerance, let abutton,
                         let amoveOnly):
            kind = .clickImage
            refData = reference
            tolerance = atolerance
            button = abutton
            moveOnly = amoveOnly
        case .notify(let message):
            kind = .notify; text = message
        case .beep:
            kind = .beep
        case .wait:
            kind = .wait
        case .waitUntil(let condition, let atimeout):
            kind = .waitUntil
            waitCondition = ConditionModel(from: condition)
            timeout = atimeout
        case .goTo(let step, let times):
            kind = .goTo; goToStep = step; goToTimes = times
        case .stopPlayback:
            kind = .stop
        }
    }

    var valid: Bool {
        switch kind {
        case .keyPress: return key != nil
        case .typeText, .setClipboard, .notify: return !text.isEmpty
        case .openApp, .openURL:
            return !text.trimmingCharacters(in: .whitespaces).isEmpty
        case .clickImage: return refData != nil
        case .waitUntil: return waitCondition.valid
        default: return true
        }
    }

    func build() -> ManualAction? {
        switch kind {
        case .click:
            return .click(x: x, y: y, button: button,
                          count: max(1, clickCount))
        case .movePointer:
            return .movePointer(x: x, y: y)
        case .keyPress:
            guard let k = key else { return nil }
            return .keyPress(keyCode: k.keyCode, modifiers: k.modifiers)
        case .typeText:
            guard !text.isEmpty else { return nil }
            return .typeText(text: text)
        case .scroll:
            return .scroll(dx: scrollDX, dy: scrollDY)
        case .openApp:
            return .openApp(name: text.trimmingCharacters(in: .whitespaces))
        case .openURL:
            return .openURL(url: text.trimmingCharacters(in: .whitespaces))
        case .setClipboard:
            return .setClipboard(text: text)
        case .pasteClipboard:
            return .pasteClipboard
        case .clickImage:
            guard let data = refData else { return nil }
            return .clickImage(reference: data, tolerance: tolerance,
                               button: button, moveOnly: moveOnly)
        case .notify:
            return .notify(message: text)
        case .beep:
            return .beep
        case .wait:
            return .wait
        case .waitUntil:
            guard let c = waitCondition.build() else { return nil }
            return .waitUntil(condition: c, timeout: max(0, timeout))
        case .goTo:
            return .goTo(step: max(1, goToStep), times: max(0, goToTimes))
        case .stop:
            return .stopPlayback
        }
    }
}

struct ActionFields: View {
    @Binding var model: ActionFormModel

    var body: some View {
        switch model.kind {
        case .click, .movePointer:
            LabeledContent("Position") {
                HStack(spacing: 6) {
                    NumberField(value: $model.x)
                    Text("×").foregroundStyle(.tertiary)
                    NumberField(value: $model.y)
                }
            }
            LabeledContent("") {
                CaptureCursorButton {
                    model.x = $0.x
                    model.y = $0.y
                }
            }
            if model.kind == .click {
                Picker("Button", selection: $model.button) {
                    ForEach(MouseButtonKind.allCases) { b in
                        Text(b.rawValue).tag(b)
                    }
                }
                .pickerStyle(.menu)
                Picker("Clicks", selection: $model.clickCount) {
                    Text("single").tag(1)
                    Text("double").tag(2)
                    Text("triple").tag(3)
                }
                .pickerStyle(.menu)
            }
        case .keyPress:
            LabeledContent("Key combo") {
                KeyCaptureButton(key: $model.key)
            }
        case .typeText:
            LabeledContent("Text") {
                TextField("text to type", text: $model.text)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            }
        case .openApp:
            LabeledContent("App") {
                TextField("name, bundle id, or path", text: $model.text)
                    .frame(width: 220)
            }
            LabeledContent("") {
                Text("Launches the app, or brings it to the front if it's already running. “Safari”, “com.apple.Safari”, and full .app paths all work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .openURL:
            LabeledContent("URL") {
                TextField("https://…", text: $model.text)
                    .frame(maxWidth: .infinity)
            }
            LabeledContent("") {
                Text("Opens in the default handler — web addresses in your browser, mailto: in your mail app, and so on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .setClipboard:
            LabeledContent("Text") {
                TextField("clipboard contents", text: $model.text)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            }
        case .pasteClipboard:
            LabeledContent("") {
                Text("Presses ⌘V — pastes whatever is on the clipboard into the focused app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .clickImage:
            ScreenRecordingGrantRows()
            LabeledContent("Capture from") {
                HStack(spacing: 6) {
                    NumberField(value: $model.x)
                    Text("×").foregroundStyle(.tertiary)
                    NumberField(value: $model.y)
                }
            }
            LabeledContent("") {
                CaptureCursorButton(label: "Set top-left from cursor (2s)") {
                    model.x = $0.x
                    model.y = $0.y
                }
            }
            LabeledContent("Size") {
                HStack(spacing: 6) {
                    NumberField(value: $model.refW)
                    Text("×").foregroundStyle(.tertiary)
                    NumberField(value: $model.refH)
                }
            }
            LabeledContent("") {
                CaptureCursorButton(label: "Set bottom-right from cursor (2s)") {
                    model.refW = max(1, $0.x - model.x)
                    model.refH = max(1, $0.y - model.y)
                }
            }
            LabeledContent("Image") {
                HStack(spacing: 8) {
                    if let data = model.refData,
                       let img = NSImage(data: data) {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 72, maxHeight: 44)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(.quaternary))
                    }
                    CaptureCursorButton(
                        label: model.refData == nil
                            ? "Capture image in area (2s)"
                            : "Recapture (2s)") { _ in
                        let rect = CGRect(x: model.x, y: model.y,
                                          width: max(model.refW, 1),
                                          height: max(model.refH, 1))
                        if let img = ScreenSampler.capture(rect: rect),
                           let png = ScreenSampler.png(img) {
                            model.refData = png
                        }
                    }
                }
            }
            Picker("Button", selection: $model.button) {
                ForEach(MouseButtonKind.allCases) { b in
                    Text(b.rawValue).tag(b)
                }
            }
            .pickerStyle(.menu)
            Toggle("Move the pointer only, don't click",
                   isOn: $model.moveOnly)
            LabeledContent("Tolerance") {
                HStack(spacing: 8) {
                    Slider(value: $model.tolerance, in: 0...30)
                        .frame(width: 140)
                    Text(String(format: "%.0f%%", model.tolerance))
                        .font(.callout.monospacedDigit())
                }
            }
            LabeledContent("") {
                Text("Playback scans the whole screen for this image and clicks the center of the best match. If it isn't found, the step is skipped — combine with Wait Until “image is on screen” to wait for it first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .notify:
            LabeledContent("Message") {
                TextField("notification text", text: $model.text)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            }
            LabeledContent("") {
                Text("Posts a notification banner — handy as a checkpoint in long macros.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .beep:
            LabeledContent("") {
                Text("Plays the system alert sound.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .scroll:
            LabeledContent("Horizontal (px)") {
                IntField(value: $model.scrollDX, width: 80)
            }
            LabeledContent("Vertical (px)") {
                IntField(value: $model.scrollDY, width: 80)
            }
            LabeledContent("") {
                Text("Negative vertical scrolls down, positive scrolls up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .wait:
            LabeledContent("") {
                Text("Waits for the delay in Timing below, then moves on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .waitUntil:
            ConditionFields(model: $model.waitCondition)
            LabeledContent("Give up after (s)") {
                NumberField(value: $model.timeout, width: 80)
            }
            LabeledContent("") {
                Text("0 waits forever (Esc still aborts).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .goTo:
            LabeledContent("Step number") {
                IntField(value: $model.goToStep)
            }
            LabeledContent("At most (times)") {
                IntField(value: $model.goToTimes)
            }
            LabeledContent("") {
                Text("0 jumps without limit — combine with a condition to make a loop that runs while a key is held.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .stop:
            LabeledContent("") {
                Text("Ends playback of this macro (all remaining loops). Combine with a condition for an emergency exit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - step options (timing, repeat, condition)

struct StepOptionsModel {
    var delay = 0.1
    var repeatEnabled = false
    var count = 10
    var randomized = false
    var minInterval = 0.1
    var maxInterval = 0.3
    var conditionEnabled = false
    var condition = ConditionModel()

    init() {}

    init(from item: MacroItem) {
        delay = item.delay
        if let r = item.repeats {
            repeatEnabled = true
            count = r.count
            randomized = r.randomized
            minInterval = r.minInterval
            maxInterval = r.randomized ? r.maxInterval : r.minInterval + 0.2
        }
        if let c = item.condition {
            conditionEnabled = true
            condition = ConditionModel(from: c)
        }
    }

    var valid: Bool { !conditionEnabled || condition.valid }

    func buildRepeats() -> RepeatSpec? {
        guard repeatEnabled, count > 1 else { return nil }
        let lo = max(0, minInterval)
        let hi = randomized ? max(maxInterval, lo) : lo
        return RepeatSpec(count: count, minInterval: lo, maxInterval: hi)
    }

    func buildCondition() -> Condition? {
        guard conditionEnabled else { return nil }
        return condition.build()
    }
}

struct StepOptionsFields: View {
    @Binding var model: StepOptionsModel

    var body: some View {
        Section("Timing") {
            LabeledContent("Delay before this step (s)") {
                NumberField(value: $model.delay, width: 80)
            }
        }
        Section("Repeat") {
            Toggle("Repeat this step", isOn: $model.repeatEnabled)
            if model.repeatEnabled {
                LabeledContent("Times") {
                    IntField(value: $model.count, width: 80)
                }
                Picker("Interval", selection: $model.randomized) {
                    Text("fixed").tag(false)
                    Text("random in range").tag(true)
                }
                .pickerStyle(.menu)
                LabeledContent(model.randomized ? "Min (s)" : "Every (s)") {
                    NumberField(value: $model.minInterval, width: 80)
                }
                if model.randomized {
                    LabeledContent("Max (s)") {
                        NumberField(value: $model.maxInterval, width: 80)
                    }
                }
            }
        }
        Section("Condition") {
            Toggle("Only run this step if…", isOn: $model.conditionEnabled)
            if model.conditionEnabled {
                ConditionFields(model: $model.condition)
            }
        }
    }
}

// MARK: - add / edit sheets

struct AddActionSheet: View {
    let onAdd: (MacroItem) -> Void
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var action = ActionFormModel()
    @State private var options = StepOptionsModel()

    var body: some View {
        VStack(spacing: 0) {
            Text("Add Action")
                .font(.headline)
                .padding(.top, 18)
                .padding(.bottom, 10)

            Form {
                Section("Action") {
                    Picker("Action", selection: $action.kind) {
                        ForEach(ActionFormModel.ActionKind.allCases) { k in
                            Text(k.rawValue).tag(k)
                        }
                    }
                    .pickerStyle(.menu)
                    ActionFields(model: $action)
                }
                StepOptionsFields(model: $options)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!action.valid || !options.valid)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(width: 480, height: 560)
    }

    private func add() {
        guard let built = action.build() else { return }
        let item = MacroItem(delay: max(0, options.delay),
                             payload: .action(built),
                             label: built.label,
                             repeats: options.buildRepeats(),
                             condition: options.buildCondition())
        onAdd(item)
        dismiss()
    }
}

struct EditStepSheet: View {
    let macroID: UUID
    let original: MacroItem
    private let isAction: Bool
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var action: ActionFormModel
    @State private var options: StepOptionsModel
    // For recorded (raw) steps: nil keeps the event as-is; picking a
    // kind rebuilds the step as that action on save.
    @State private var replaceKind: ActionFormModel.ActionKind?

    init(macroID: UUID, item: MacroItem) {
        self.macroID = macroID
        self.original = item
        var form = ActionFormModel()
        var actionable = false
        if case .action(let a) = item.payload {
            form = ActionFormModel(from: a)
            actionable = true
        } else if let converted = item.convertedAction {
            // Prefill from the recorded values so "Replace with" starts
            // from the right position/key instead of a blank form.
            form = ActionFormModel(from: converted)
        }
        self.isAction = actionable
        _action = State(initialValue: form)
        _options = State(initialValue: StepOptionsModel(from: item))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Edit Step")
                .font(.headline)
                .padding(.top, 18)
                .padding(.bottom, 10)

            Form {
                if isAction {
                    Section("Action") {
                        Picker("Action", selection: $action.kind) {
                            ForEach(ActionFormModel.ActionKind.allCases) { k in
                                Text(k.rawValue).tag(k)
                            }
                        }
                        .pickerStyle(.menu)
                        ActionFields(model: $action)
                    }
                } else {
                    Section("Recorded event") {
                        LabeledContent("Step", value: original.label)
                        Picker("Replace with", selection: $replaceKind) {
                            Text("Keep recorded event")
                                .tag(ActionFormModel.ActionKind?.none)
                            ForEach(ActionFormModel.ActionKind.allCases) { k in
                                Text(k.rawValue).tag(Optional(k))
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: replaceKind) { kind in
                            if let kind { action.kind = kind }
                        }
                        if replaceKind == nil {
                            Text("This event replays verbatim. Pick an action type above to rebuild the step as anything else (a matching release event is cleaned up automatically), or just edit timing, repeat, and condition below.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ActionFields(model: $action)
                        }
                    }
                }
                StepOptionsFields(model: $options)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(((isAction || replaceKind != nil)
                               && !action.valid) || !options.valid)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(width: 480, height: 560)
    }

    private func save() {
        var item = original
        let replacingRaw = !isAction && replaceKind != nil
        if isAction || replacingRaw, let built = action.build() {
            item.payload = .action(built)
            item.label = built.label
        }
        item.delay = max(0, options.delay)
        item.repeats = options.buildRepeats()
        item.condition = options.buildCondition()
        if replacingRaw {
            app.replaceRawStepWithAction(item, in: macroID,
                                         original: original)
        } else {
            app.replaceStep(item, in: macroID)
        }
        dismiss()
    }
}

// MARK: - save recording / hotkey capture

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
    @EnvironmentObject var app: AppState
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
            app.suspendHotkeys(true)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                handle(e)
                return nil  // swallow the keystroke
            }
        }
        .onDisappear {
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
            app.suspendHotkeys(false)
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
