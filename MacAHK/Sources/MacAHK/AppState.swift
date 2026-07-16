import Foundation
import SwiftUI

// A finished recording waiting to be named.
struct DraftRecording: Identifiable {
    let id = UUID()
    var events: [RecordedEvent]
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

    let store = MacroStore()
    private let recorder = Recorder()
    private let player = Player()
    private let hotkeys = HotkeyCenter()
    private var countdownTask: Task<Void, Never>?

    init() {
        recorder.onEscape = { [weak self] in self?.stopAll() }
        hotkeys.onTrigger = { [weak self] id in
            guard let self, let m = self.store.macro(id: id) else { return }
            self.play(m)
        }
        hotkeys.rebuild(from: store.macros)
    }

    var isBusy: Bool { mode != .idle }

    // MARK: recording

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
                self.status = "Recording — press Esc to finish."
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
            if recorder.events.isEmpty {
                status = "Nothing recorded."
            } else {
                draft = DraftRecording(events: recorder.events)
                status = "Recorded \(recorder.events.count) events."
            }
        case .playing:
            player.stop()
        case .idle:
            break
        }
    }

    func saveDraft(named name: String) {
        guard let draft, !name.isEmpty else { self.draft = nil; return }
        let macro = Macro(name: name, events: draft.events)
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
        let total = loops
        let ok = player.play(
            events: macro.events, loops: total, speed: speed,
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

    // MARK: library

    func delete(_ macro: Macro) {
        store.delete(macro)
        hotkeys.rebuild(from: store.macros)
        status = "Deleted “\(macro.name)”."
    }

    func setHotkey(_ hotkey: Hotkey?, for macro: Macro) {
        var m = macro
        m.hotkey = hotkey
        store.upsert(m)
        hotkeys.rebuild(from: store.macros)
        status = hotkey.map { "Hotkey for “\(m.name)”: \($0.display)" }
            ?? "Hotkey cleared for “\(m.name)”."
    }

    func rename(_ macro: Macro, to name: String) {
        guard !name.isEmpty else { return }
        var m = macro
        m.name = name
        store.upsert(m)
    }
}
