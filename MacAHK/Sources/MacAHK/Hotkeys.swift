import Foundation
import AppKit

// Global hotkey dispatch. Two monitors are needed because macOS splits
// the world: the global monitor sees keystrokes typed into OTHER apps,
// the local monitor sees keystrokes typed into MacAHK itself. Without
// the local one, hotkeys silently die whenever our own window is
// focused.
//
// Macro hotkeys are suppressed while recording or playing (a macro must
// not retrigger itself); the record hotkey stays live always, since its
// whole point is toggling recording from anywhere. Everything is
// suppressed while a capture sheet is teaching a new combo.
@MainActor
final class HotkeyCenter {
    var enabled = true
    var captureSuspended = false
    var onTrigger: ((UUID) -> Void)?
    var onRecordToggle: (() -> Void)?
    var recordHotkey: Hotkey?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var bindings: [(hotkey: Hotkey, id: UUID)] = []

    func rebuild(from macros: [Macro]) {
        bindings = macros.compactMap { m in
            guard let hk = m.hotkey else { return nil }
            return (hk, m.id)
        }
        let needed = !bindings.isEmpty || recordHotkey != nil
        if needed {
            if globalMonitor == nil {
                globalMonitor = NSEvent.addGlobalMonitorForEvents(
                    matching: .keyDown) { [weak self] event in
                    _ = self?.handle(event)
                }
            }
            if localMonitor == nil {
                localMonitor = NSEvent.addLocalMonitorForEvents(
                    matching: .keyDown) { [weak self] event in
                    (self?.handle(event) ?? false) ? nil : event
                }
            }
        } else {
            shutdown()
        }
    }

    func shutdown() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
    }

    // Returns true when the event matched a hotkey and was acted on.
    private func handle(_ event: NSEvent) -> Bool {
        guard !captureSuspended else { return false }
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])

        // Key auto-repeat must not re-fire a hotkey while it's held, but
        // matching combos still get swallowed so they don't type.
        if let rec = recordHotkey,
           rec.keyCode == event.keyCode && rec.flags == mods {
            if !event.isARepeat { onRecordToggle?() }
            return true
        }

        guard enabled else { return false }
        for b in bindings
        where b.hotkey.keyCode == event.keyCode && b.hotkey.flags == mods {
            if !event.isARepeat { onTrigger?(b.id) }
            return true
        }
        return false
    }
}
