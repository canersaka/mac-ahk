import Foundation
import SwiftUI

// A finished recording waiting to be named — or appended to the macro
// that was selected when recording started.
struct DraftRecording: Identifiable {
    let id = UUID()
    var items: [MacroItem]
    var appendTarget: Macro?
}

@MainActor
final class AppState: ObservableObject {
    enum Mode: Equatable {
        case idle
        case countdown(Int)
        case recording
        case playing(name: String, loop: Int, totalLoops: Int)
    }

    @Published var mode: Mode = .idle {
        didSet {
            // Text expansion pauses whenever the app is recording or
            // playing: expansions would pollute a recording, and typed
            // text during playback comes from the macro, not the user.
            hotstrings.suspended = mode != .idle
        }
    }
    @Published var status = "Ready."
    @Published var draft: DraftRecording?
    @Published var selection: UUID?
    // Live playback position, for highlighting the current step in the
    // editor while its macro plays.
    @Published var playingMacroID: UUID?
    @Published var playingStep: Int?
    @Published var loops = 1
    @Published var speed = 1.0
    @Published var captureMoves = false
    @Published var recordHotkey: Hotkey? {
        didSet {
            persistRecordHotkey()
            recorder.stopHotkey = recordHotkey
            hotkeys.recordHotkey = recordHotkey
            hotkeys.rebuild(from: store.macros)
        }
    }

    @Published var hotstringsEnabled = true {
        didSet {
            UserDefaults.standard.set(hotstringsEnabled,
                                      forKey: Self.hotstringsEnabledKey)
            rebuildHotstrings()
        }
    }

    let store = MacroStore()
    let hotstringStore = HotstringStore()
    private let recorder = Recorder()
    private let player = Player()
    private let hotkeys = HotkeyCenter()
    private let hotstrings = HotstringCenter()
    private var countdownTask: Task<Void, Never>?
    private var appendCandidateID: UUID?
    private static let recordHotkeyDefaultsKey = "recordHotkey"
    private static let hotstringsEnabledKey = "hotstringsEnabled"

    init() {
        recorder.onEscape = { [weak self] in self?.stopAll() }
        hotkeys.onTrigger = { [weak self] id in
            guard let self, let m = self.store.macro(id: id) else { return }
            self.play(m)
        }
        hotkeys.onRecordToggle = { [weak self] in self?.toggleRecording() }
        if let data = UserDefaults.standard.data(
            forKey: Self.recordHotkeyDefaultsKey),
           let hk = try? JSONDecoder().decode(Hotkey.self, from: data) {
            recordHotkey = hk
            recorder.stopHotkey = hk
            hotkeys.recordHotkey = hk
        }
        hotkeys.rebuild(from: store.macros)

        if UserDefaults.standard.object(
            forKey: Self.hotstringsEnabledKey) != nil {
            hotstringsEnabled = UserDefaults.standard.bool(
                forKey: Self.hotstringsEnabledKey)
        }
        hotstringStore.onChange = { [weak self] in
            self?.rebuildHotstrings()
        }
        rebuildHotstrings()
    }

    var isBusy: Bool { mode != .idle }

    var isRecordingOrCounting: Bool {
        if case .recording = mode { return true }
        if case .countdown = mode { return true }
        return false
    }

    // MARK: recording

    func toggleRecording() {
        if mode == .idle {
            beginRecording()
        } else if isRecordingOrCounting {
            stopAll()
        }
        // Ignored while playing: stopping playback belongs to Esc/Stop.
    }

    func beginRecording() {
        guard mode == .idle else { return }
        guard Permissions.inputMonitoring else {
            status = "Grant Input Monitoring first."
            Permissions.requestInputMonitoring()
            return
        }
        // Remember which macro was selected: when recording ends, the
        // save sheet offers to append the new steps to it.
        appendCandidateID = selection
        hotkeys.enabled = false
        countdownTask = Task { [weak self] in
            for i in stride(from: 3, through: 1, by: -1) {
                guard let self, !Task.isCancelled else { return }
                self.mode = .countdown(i)
                self.status = "Recording starts in \(i)… switch to your target app."
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            self.recorder.captureMoves = self.captureMoves
            if self.recorder.start() {
                self.mode = .recording
                let hint = self.recordHotkey.map { " or \($0.display)" } ?? ""
                self.status = "Recording — press Esc\(hint) to finish."
            } else {
                self.mode = .idle
                self.hotkeys.enabled = true
                self.status = "Could not start the event tap. Check Input Monitoring permission and relaunch."
            }
        }
    }

    func stopAll() {
        switch mode {
        case .countdown:
            countdownTask?.cancel()
            mode = .idle
            hotkeys.enabled = true
            status = "Cancelled."
        case .recording:
            recorder.stop()
            mode = .idle
            hotkeys.enabled = true
            let items = Macro.items(from: recorder.events)
            if items.isEmpty {
                status = "Nothing recorded."
            } else {
                draft = DraftRecording(
                    items: items,
                    appendTarget: store.macro(id: appendCandidateID))
                status = "Recorded \(items.count) steps."
            }
        case .playing:
            player.stop()
        case .idle:
            break
        }
    }

    func saveDraft(named name: String) {
        guard let draft, !name.isEmpty else { self.draft = nil; return }
        let macro = Macro(name: name, items: draft.items)
        store.upsert(macro)
        hotkeys.rebuild(from: store.macros)
        self.draft = nil
        selection = macro.id
        status = "Saved “\(name)”."
    }

    func appendDraftToTarget() {
        guard let draft, let target = draft.appendTarget else { return }
        modify(target.id) { $0.items.append(contentsOf: draft.items) }
        self.draft = nil
        selection = target.id
        status = "Added \(draft.items.count) steps to “\(target.name)”."
    }

    func discardDraft() {
        draft = nil
        status = "Recording discarded."
    }

    // MARK: playback

    func play(_ macro: Macro) {
        guard mode == .idle else { return }
        guard Permissions.accessibility else {
            status = "Grant Accessibility first."
            Permissions.requestAccessibility()
            return
        }
        hotkeys.enabled = false
        let name = macro.name
        playingMacroID = macro.id
        playingStep = nil
        let ok = player.play(
            items: macro.items, loops: loops, speed: speed,
            progress: { [weak self] loop, totalLoops in
                self?.mode = .playing(name: name, loop: loop,
                                      totalLoops: totalLoops)
                let t = totalLoops > 0 ? "\(totalLoops)" : "∞"
                self?.status = "Playing “\(name)” — loop \(loop)/\(t) — Esc stops."
            },
            onStep: { [weak self] index in
                self?.playingStep = index
            },
            done: { [weak self] aborted in
                self?.mode = .idle
                self?.playingMacroID = nil
                self?.playingStep = nil
                self?.hotkeys.enabled = true
                self?.status = aborted ? "Stopped." : "Done."
            })
        if !ok {
            mode = .idle
            playingMacroID = nil
            playingStep = nil
            hotkeys.enabled = true
        }
    }

    // MARK: library and editing

    func createEmptyMacro() {
        let macro = Macro(name: "New Macro", items: [])
        store.upsert(macro)
        selection = macro.id
        status = "Created an empty macro — add steps with the ＋ button."
    }

    func createMacro(named name: String, items: [MacroItem],
                     hotkey: Hotkey?) {
        let macro = Macro(name: name, hotkey: hotkey, items: items)
        store.upsert(macro)
        hotkeys.rebuild(from: store.macros)
        selection = macro.id
        status = "Imported “\(name)” with \(items.count) steps."
    }

    func delete(_ macro: Macro) {
        store.delete(macro)
        hotkeys.rebuild(from: store.macros)
        status = "Deleted “\(macro.name)”."
    }

    // Apply an edit to a stored macro and persist it.
    func modify(_ id: UUID, _ transform: (inout Macro) -> Void) {
        guard var m = store.macro(id: id) else { return }
        transform(&m)
        store.upsert(m)
    }

    func insertStep(_ item: MacroItem, into id: UUID, after selected: UUID?) {
        modify(id) { m in
            if let selected,
               let i = m.items.firstIndex(where: { $0.id == selected }) {
                m.items.insert(item, at: i + 1)
            } else {
                m.items.append(item)
            }
        }
        status = "Added: \(item.label)"
    }

    func replaceStep(_ item: MacroItem, in id: UUID) {
        modify(id) { m in
            if let i = m.items.firstIndex(where: { $0.id == item.id }) {
                m.items[i] = item
            }
        }
        status = "Updated: \(item.label)"
    }

    func duplicateStep(_ stepID: UUID, in id: UUID) {
        modify(id) { m in
            guard let i = m.items.firstIndex(where: { $0.id == stepID })
            else { return }
            var copy = m.items[i]
            copy.id = UUID()
            m.items.insert(copy, at: i + 1)
        }
    }

    // Turn a raw recorded press into its fully editable action, removing
    // the matching release event so the pair doesn't double-fire.
    func convertStepToAction(_ stepID: UUID, in id: UUID) {
        modify(id) { m in
            guard let i = m.items.firstIndex(where: { $0.id == stepID }),
                  let action = m.items[i].convertedAction else { return }
            let original = m.items[i]
            m.items[i].payload = .action(action)
            m.items[i].label = action.label
            Self.removePairedRelease(for: original, in: &m, after: i + 1)
        }
        status = "Converted to an editable action."
    }

    // Replace a recorded step wholesale with a manual action (the edit
    // sheet's "Replace with" flow). If the original was a press-type raw
    // event, its matching release is cleaned up like conversion does.
    func replaceRawStepWithAction(_ item: MacroItem, in id: UUID,
                                  original: MacroItem) {
        modify(id) { m in
            guard let i = m.items.firstIndex(where: { $0.id == item.id })
            else { return }
            m.items[i] = item
            Self.removePairedRelease(for: original, in: &m, after: i + 1)
        }
        status = "Updated: \(item.label)"
    }

    // Remove the release event paired with a press-type raw step,
    // folding the removed step's delay into its successor so overall
    // timing stays intact.
    private static func removePairedRelease(for original: MacroItem,
                                            in m: inout Macro,
                                            after start: Int) {
        guard let releaseType = original.pairedReleaseType else { return }
        let keyCode = original.rawKeyCode
        for j in start..<m.items.count {
            guard case .raw(let t, _) = m.items[j].payload,
                  t == releaseType else { continue }
            if releaseType == 11,
               let kc = keyCode, m.items[j].rawKeyCode != kc {
                continue
            }
            let removedDelay = m.items[j].delay
            if j + 1 < m.items.count {
                m.items[j + 1].delay += removedDelay
            }
            m.items.remove(at: j)
            break
        }
    }

    func setHotkey(_ hotkey: Hotkey?, for macro: Macro) {
        modify(macro.id) { $0.hotkey = hotkey }
        hotkeys.rebuild(from: store.macros)
        status = hotkey.map { "Hotkey for “\(macro.name)”: \($0.display)" }
            ?? "Hotkey cleared for “\(macro.name)”."
    }

    func rename(_ macro: Macro, to name: String) {
        guard !name.isEmpty else { return }
        modify(macro.id) { $0.name = name }
    }

    // While a sheet is teaching a new combo, hotkeys must not fire (and
    // hotstrings must not expand what's being typed into the sheet).
    func suspendHotkeys(_ suspended: Bool) {
        hotkeys.captureSuspended = suspended
        hotstrings.captureSuspended = suspended
    }

    // MARK: hotstrings

    func rebuildHotstrings() {
        hotstrings.rebuild(from: hotstringStore.hotstrings,
                           masterEnabled: hotstringsEnabled)
    }

    func addHotstrings(_ list: [Hotstring]) {
        guard !list.isEmpty else { return }
        hotstringStore.hotstrings.append(contentsOf: list)
        status = "Added \(list.count) hotstring\(list.count == 1 ? "" : "s")."
    }

    private func persistRecordHotkey() {
        if let hk = recordHotkey, let data = try? JSONEncoder().encode(hk) {
            UserDefaults.standard.set(data,
                                      forKey: Self.recordHotkeyDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(
                forKey: Self.recordHotkeyDefaultsKey)
        }
    }
}
