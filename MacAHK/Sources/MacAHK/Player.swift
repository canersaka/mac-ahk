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

    // Playback-thread-only state (no lock needed): the throttle for step
    // progress posts, and the grace window during which a *synthetic*
    // Esc pressed by the macro itself must not read as the user's abort.
    private var lastStepPost = Date.distantPast
    private var suppressEscUntil = Date.distantPast

    // progress(loop, totalLoops), onStep(stepIndex) and done(aborted)
    // are all called on main.
    func play(items: [MacroItem], loops: Int, speed: Double,
              progress: @escaping (Int, Int) -> Void,
              onStep: @escaping (Int) -> Void,
              done: @escaping (Bool) -> Void) -> Bool {
        stateLock.lock()
        guard !isPlaying, !items.isEmpty else {
            stateLock.unlock()
            return false
        }
        isPlaying = true
        abortFlag = false
        stateLock.unlock()

        let clampedSpeed = max(speed, 0.05)
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            self.lastStepPost = .distantPast
            self.suppressEscUntil = .distantPast
            let aborted = self.run(items: items, loops: loops,
                                   speed: clampedSpeed, progress: progress,
                                   onStep: onStep)
            DispatchQueue.main.async { done(aborted) }
        }
        return true
    }

    func stop() {
        stateLock.lock()
        abortFlag = true
        stateLock.unlock()
    }

    // Checked from the playback thread between events and inside sleeps.
    // Esc is read straight from the session key state: an NSEvent global
    // monitor (the old approach) never fires while MacAHK itself is
    // frontmost — which is exactly when Play is usually pressed.
    private var aborted: Bool {
        stateLock.lock()
        let flagged = abortFlag
        stateLock.unlock()
        if flagged { return true }
        if Date() >= suppressEscUntil,
           CGEventSource.keyState(.combinedSessionState, key: 53) {
            stop()
            return true
        }
        return false
    }

    // The playback engine. Steps run in order, but each one can carry a
    // condition (skip when false), a repeat spec (run N times with fixed
    // or randomized spacing), or control flow (jump / wait-until / stop).
    private func run(items: [MacroItem], loops: Int, speed: Double,
                     progress: @escaping (Int, Int) -> Void,
                     onStep: @escaping (Int) -> Void) -> Bool {
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
                postStep(i, onStep: onStep)
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

    // Step highlight updates are best-effort: cap the rate so a dense
    // raw recording doesn't flood the main thread with UI updates.
    private func postStep(_ index: Int, onStep: @escaping (Int) -> Void) {
        let now = Date()
        guard now.timeIntervalSince(lastStepPost) >= 0.05 else { return }
        lastStepPost = now
        DispatchQueue.main.async { onStep(index) }
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
            suppressEscIfNeeded(type: type, event: event)
            // The serialized bytes keep their record-time timestamp;
            // stale stamps trip up double-click detection and event
            // coalescing in some apps, so restamp before posting.
            event.timestamp = DispatchTime.now().uptimeNanoseconds
            // A bare recorded click teleports the cursor and presses in
            // the same event, which hover-sensitive targets can miss
            // (especially with "Record mouse path" off). Walk the
            // cursor there first.
            if type == 1 || type == 3 || type == 25 {
                settleCursor(at: event.location)
            }
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
            settleCursor(at: pt)
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
            if code == 53 { suppressEsc(for: 0.5) }
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
                settleCursor(at: point)
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

    // MARK: esc / cursor helpers

    // A macro can itself press Esc (recorded, or via `press esc`).
    // Without a grace window, replaying that keystroke would read as the
    // user's abort. Physical Esc works again once the window passes, and
    // the Stop button always works.
    private func suppressEsc(for seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        if until > suppressEscUntil { suppressEscUntil = until }
    }

    private func suppressEscIfNeeded(type: UInt32, event: CGEvent) {
        guard type == 10 || type == 11 || type == 12,
              event.getIntegerValueField(.keyboardEventKeycode) == 53
        else { return }
        // Down: cover until the paired up should long since have played.
        suppressEsc(for: type == 10 ? 2.0 : 0.3)
    }

    // Move the pointer onto the click point and give the target a moment
    // to notice hover before the press lands. Skipped when it's already
    // there (e.g. the recording contains the mouse path).
    private func settleCursor(at point: CGPoint) {
        if let current = CGEvent(source: nil)?.location,
           abs(current.x - point.x) < 2, abs(current.y - point.y) < 2 {
            return
        }
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.015)
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
