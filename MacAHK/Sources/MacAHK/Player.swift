import Foundation
import AppKit
import CoreGraphics
import CEventCodec

// Replays a macro's steps: raw recorded events are reconstructed and
// posted verbatim; manual actions are synthesized. Esc aborts instantly;
// any keys still held when playback ends are released.
final class Player {
    private(set) var isPlaying = false
    private var abortFlag = false
    private let stateLock = NSLock()
    private var escMonitor: Any?

    // progress(loop, totalLoops) and done(aborted) are called on main.
    func play(items: [MacroItem], loops: Int, speed: Double,
              progress: @escaping (Int, Int) -> Void,
              done: @escaping (Bool) -> Void) -> Bool {
        stateLock.lock()
        guard !isPlaying, !items.isEmpty else {
            stateLock.unlock()
            return false
        }
        isPlaying = true
        abortFlag = false
        stateLock.unlock()

        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] e in
            if e.keyCode == 53 { self?.stop() }
        }

        let clampedSpeed = max(speed, 0.05)
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            let aborted = self.run(items: items, loops: loops,
                                   speed: clampedSpeed, progress: progress)
            DispatchQueue.main.async {
                if let m = self.escMonitor { NSEvent.removeMonitor(m) }
                self.escMonitor = nil
                done(aborted)
            }
        }
        return true
    }

    func stop() {
        stateLock.lock()
        abortFlag = true
        stateLock.unlock()
    }

    private var aborted: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return abortFlag
    }

    // The playback engine. Steps run in order, but each one can carry a
    // condition (skip when false), a repeat spec (run N times with fixed
    // or randomized spacing), or control flow (jump / wait-until / stop).
    private func run(items: [MacroItem], loops: Int, speed: Double,
                     progress: @escaping (Int, Int) -> Void) -> Bool {
        var heldKeys = Set<Int64>()
        var loop = 0
        var stopped = false

        outer: while !aborted && !stopped {
            loop += 1
            let currentLoop = loop
            DispatchQueue.main.async { progress(currentLoop, loops) }

            // Per-pass jump budget, so "at most ×N" resets every loop.
            var jumpsTaken: [UUID: Int] = [:]
            var i = 0
            while i < items.count {
                if aborted { break outer }
                let item = items[i]
                sleepInterruptibly(item.delay / speed)
                if aborted { break outer }

                // The condition is checked at the moment the step would
                // run, after its delay.
                if let cond = item.condition, !cond.holds() {
                    i += 1
                    continue
                }

                if case .action(let action) = item.payload {
                    switch action {
                    case .goTo(let step, let times):
                        let taken = jumpsTaken[item.id, default: 0]
                        if times == 0 || taken < times {
                            jumpsTaken[item.id] = taken + 1
                            i = max(0, min(items.count - 1, step - 1))
                        } else {
                            i += 1
                        }
                        continue
                    case .waitUntil(let condition, let timeout):
                        waitUntil(condition, timeout: timeout)
                        i += 1
                        continue
                    case .stopPlayback:
                        stopped = true
                        break
                    default:
                        break
                    }
                    if stopped { break }
                }

                runRepeated(item, speed: speed, held: &heldKeys)
                i += 1
            }
            if loops > 0 && loop >= loops { break }
        }

        releaseHeld(heldKeys)
        let wasAborted = aborted
        stateLock.lock()
        isPlaying = false
        stateLock.unlock()
        return wasAborted
    }

    private func runRepeated(_ item: MacroItem, speed: Double,
                             held: inout Set<Int64>) {
        let count = max(1, item.repeats?.count ?? 1)
        for n in 0..<count {
            if aborted { return }
            execute(item, held: &held)
            if n < count - 1, let spec = item.repeats {
                sleepInterruptibly(spec.nextInterval() / speed)
            }
        }
    }

    // Poll until the condition holds, the timeout passes (0 = no
    // timeout), or playback is aborted. Real-world waiting: unaffected
    // by the speed multiplier. Pixel conditions capture the screen each
    // check, so they poll gently.
    private func waitUntil(_ condition: Condition, timeout: Double) {
        let interval = condition.kind.isPixelBased ? 0.25 : 0.03
        let deadline = timeout > 0
            ? Date().addingTimeInterval(timeout) : Date.distantFuture
        while !aborted && !condition.holds() && Date() < deadline {
            Thread.sleep(forTimeInterval: interval)
        }
    }

    private func execute(_ item: MacroItem, held: inout Set<Int64>) {
        switch item.payload {
        case .raw(let type, let data):
            guard let event = MAHEventCreateFromData(data as CFData)
            else { return }
            trackHeldKeys(type: type, event: event, held: &held)
            event.post(tap: .cghidEventTap)
        case .action(let action):
            perform(action)
        }
    }

    // MARK: synthesized actions

    private func perform(_ action: ManualAction) {
        let src = CGEventSource(stateID: .combinedSessionState)
        switch action {
        case .wait:
            break

        case .movePointer(let x, let y):
            CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                    mouseCursorPosition: CGPoint(x: x, y: y),
                    mouseButton: .left)?
                .post(tap: .cghidEventTap)

        case .click(let x, let y, let button, let count):
            let pt = CGPoint(x: x, y: y)
            for i in 1...max(count, 1) {
                for (type, _) in [(button.downType, true),
                                  (button.upType, false)] {
                    guard let e = CGEvent(
                        mouseEventSource: src, mouseType: type,
                        mouseCursorPosition: pt,
                        mouseButton: button.cgButton) else { continue }
                    e.setIntegerValueField(.mouseEventClickState,
                                           value: Int64(i))
                    e.post(tap: .cghidEventTap)
                }
                if count > 1 { Thread.sleep(forTimeInterval: 0.08) }
            }

        case .keyPress(let code, let modifiers):
            Synth.tapKey(CGKeyCode(code),
                         flags: Hotkey(keyCode: code,
                                       modifiers: modifiers).cgFlags,
                         source: src)

        case .typeText(let text):
            Synth.typeText(text, source: src)

        case .scroll(let dx, let dy):
            CGEvent(scrollWheelEvent2Source: src, units: .pixel,
                    wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx),
                    wheel3: 0)?
                .post(tap: .cghidEventTap)

        case .openApp(let name):
            DispatchQueue.main.async { AppLauncher.openApp(named: name) }
            // Give the app a moment to come forward before the next step.
            Thread.sleep(forTimeInterval: 0.3)

        case .openURL(let urlString):
            let trimmed = urlString.trimmingCharacters(in: .whitespaces)
            if let url = URL(string: trimmed) {
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }

        case .setClipboard(let text):
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)

        case .pasteClipboard:
            Synth.tapKey(9, flags: .maskCommand, source: src)  // ⌘V

        case .clickImage(let reference, let tolerance, let button,
                         let moveOnly):
            guard let data = reference,
                  let template = ScreenSampler.image(fromPNG: data),
                  let point = ScreenSampler.findOnScreen(
                      template: template, tolerance: tolerance / 100.0)
            else { break }  // not found → the step is simply skipped
            if moveOnly {
                CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                        mouseCursorPosition: point, mouseButton: .left)?
                    .post(tap: .cghidEventTap)
            } else {
                for type in [button.downType, button.upType] {
                    CGEvent(mouseEventSource: src, mouseType: type,
                            mouseCursorPosition: point,
                            mouseButton: button.cgButton)?
                        .post(tap: .cghidEventTap)
                }
            }

        case .notify(let message):
            DispatchQueue.main.async { Notifier.show(message) }

        case .beep:
            NSSound.beep()

        case .waitUntil, .goTo, .stopPlayback:
            break  // control flow — handled by the engine in run()
        }
    }

    // MARK: cleanup

    // Sleep in short slices so Esc lands fast even inside long waits.
    private func sleepInterruptibly(_ seconds: Double) {
        var remaining = seconds
        while remaining > 0 && !aborted {
            let slice = min(remaining, 0.05)
            Thread.sleep(forTimeInterval: slice)
            remaining -= slice
        }
    }

    private func trackHeldKeys(type: UInt32, event: CGEvent,
                               held: inout Set<Int64>) {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == 10 {
            held.insert(code)
        } else if type == 11 {
            held.remove(code)
        } else if type == 12 {
            // Modifier transitions: track the key either way; a spare
            // cleanup key-up is harmless if it was already released.
            held.insert(code)
        }
    }

    private func releaseHeld(_ keys: Set<Int64>) {
        guard !keys.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for code in keys {
            if let up = CGEvent(keyboardEventSource: source,
                                virtualKey: CGKeyCode(code), keyDown: false) {
                up.post(tap: .cghidEventTap)
            }
        }
    }
}
