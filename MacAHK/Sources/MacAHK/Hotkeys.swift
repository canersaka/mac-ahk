import Foundation
import AppKit

// Global hotkey dispatch via an NSEvent global monitor. This piggybacks
// on the Input Monitoring permission the recorder already needs, so no
// extra frameworks or permissions are involved.
//
// Macro hotkeys are suppressed while recording or playing (a macro must
// not retrigger itself); the record hotkey stays live always, since its
// whole point is toggling recording from anywhere.
@MainActor
final class HotkeyCenter {
    var enabled = true
    var onTrigger: ((UUID) -> Void)?
    var onRecordToggle: (() -> Void)?
    var recordHotkey: Hotkey?

    private var monitor: Any?
    private var bindings: [(hotkey: Hotkey, id: UUID)] = []

    func rebuild(from macros: [Macro]) {
        bindings = macros.compactMap { m in
            guard let hk = m.hotkey else { return nil }
            return (hk, m.id)
        }
        let needed = !bindings.isEmpty || recordHotkey != nil
        if monitor == nil && needed {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
                [weak self] event in
                self?.handle(event)
            }
        } else if !needed, let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    func shutdown() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])

        if let rec = recordHotkey,
           rec.keyCode == event.keyCode && rec.flags == mods {
            onRecordToggle?()
            return
        }

        guard enabled else { return }
        for b in bindings
        where b.hotkey.keyCode == event.keyCode && b.hotkey.flags == mods {
            onTrigger?(b.id)
            return
        }
    }
}
