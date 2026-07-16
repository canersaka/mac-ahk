import Foundation
import AppKit

// Global hotkey dispatch via an NSEvent global monitor. This piggybacks
// on the Input Monitoring permission the recorder already needs, so no
// extra frameworks or permissions are involved. Bindings are disabled
// while recording or playing so a macro can't retrigger itself.
@MainActor
final class HotkeyCenter {
    var enabled = true
    var onTrigger: ((UUID) -> Void)?

    private var monitor: Any?
    private var bindings: [(hotkey: Hotkey, id: UUID)] = []

    func rebuild(from macros: [Macro]) {
        bindings = macros.compactMap { m in
            guard let hk = m.hotkey else { return nil }
            return (hk, m.id)
        }
        if monitor == nil && !bindings.isEmpty {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
                [weak self] event in
                self?.handle(event)
            }
        } else if bindings.isEmpty, let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    func shutdown() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        guard enabled else { return }
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
        for b in bindings
        where b.hotkey.keyCode == event.keyCode && b.hotkey.flags == mods {
            onTrigger?(b.id)
            return
        }
    }
}
