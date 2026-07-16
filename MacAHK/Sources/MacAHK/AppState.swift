import Foundation
import SwiftUI

// A finished recording waiting to be named.
struct DraftRecording: Identifiable {
    let id = UUID()
    var items: [MacroItem]
}

@MainActor
final class AppState: ObservableObject {
    enum Mode: Equatable {
        case idle
        case countdown(Int)
        case recording
        case playing(name: String, loop: Int, totalLoops: Int)
    }

    @Published var mode: Mode = .idle
    @Published var status = "Ready."
    @Published var draft: DraftRecording?
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

    let store = MacroStore()
    private let recorder = Recorder()
    private let player = Player()
    private let hotkeys = HotkeyCenter()
    private var countdownTask: Task<Void, Never>?
    private static let recordHotkeyDefaultsKey = "recordHotkey"

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
                draft = DraftRecording(items: items)
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
        status = "Saved “\(name)”."
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
        let ok = player.play(
            items: macro.items, loops: loops, speed: speed,
            progress: { [weak self] loop, totalLoops in
                self?.mode = .playing(name: name, loop: loop,
                                      totalLoops: totalLoops)
                let t = totalLoops > 0 ? "\(totalLoops)" : "∞"
                self?.status = "Playing “\(name)” — loop \(loop)/\(t) — Esc stops."
            },
            done: { [weak self] aborted in
                self?.mode = .idle
                self?.hotkeys.enabled = true
                self?.status = aborted ? "Stopped." : "Done."
            })
        if !ok {
            mode = .idle
            hotkeys.enabled = true
        }
    }

    // MARK: library and editing

    func createEmptyMacro() -> Macro {
        let macro = Macro(name: "New Macro", items: [])
        store.upsert(macro)
        status = "Created an empty macro — add steps with the ＋ button."
        return macro
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

    func insertAction(_ action: ManualAction, delay: Double, into id: UUID,
                      after selected: UUID?) {
        modify(id) { m in
            let item = MacroItem(delay: max(0, delay),
                                 payload: .action(action),
                                 label: action.label)
            if let selected,
               let i = m.items.firstIndex(where: { $0.id == selected }) {
                m.items.insert(item, at: i + 1)
            } else {
                m.items.append(item)
            }
        }
        status = "Added: \(action.label)"
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
