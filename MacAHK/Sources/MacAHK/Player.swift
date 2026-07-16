import Foundation
import AppKit
import CoreGraphics
import CEventCodec

// Replays recorded events by reconstructing each raw CGEvent and posting
// it back to the window server, preserving original timing (optionally
// scaled). Esc aborts immediately; any keys still held when playback
// ends are released so nothing sticks.
final class Player {
    private(set) var isPlaying = false
    private var abortFlag = false
    private let stateLock = NSLock()
    private var escMonitor: Any?

    // progress(loop, totalLoops) and done(aborted) are called on main.
    func play(events: [RecordedEvent], loops: Int, speed: Double,
              progress: @escaping (Int, Int) -> Void,
              done: @escaping (Bool) -> Void) -> Bool {
        stateLock.lock()
        guard !isPlaying, !events.isEmpty else {
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
            let aborted = self.run(events: events, loops: loops,
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

    private func run(events: [RecordedEvent], loops: Int, speed: Double,
                     progress: @escaping (Int, Int) -> Void) -> Bool {
        var heldKeys = Set<Int64>()
        var loop = 0
        while !aborted {
            loop += 1
            let currentLoop = loop
            DispatchQueue.main.async { progress(currentLoop, loops) }

            var prevT = 0.0
            for e in events {
                if aborted { break }
                sleepInterruptibly((e.t - prevT) / speed)
                prevT = e.t
                if aborted { break }
                guard let event = MAHEventCreateFromData(e.data as CFData)
                else { continue }
                trackHeldKeys(e, event: event, held: &heldKeys)
                event.post(tap: .cghidEventTap)
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

    // Sleep in short slices so Esc lands fast even inside long waits.
    private func sleepInterruptibly(_ seconds: Double) {
        var remaining = seconds
        while remaining > 0 && !aborted {
            let slice = min(remaining, 0.05)
            Thread.sleep(forTimeInterval: slice)
            remaining -= slice
        }
    }

    private func trackHeldKeys(_ e: RecordedEvent, event: CGEvent,
                               held: inout Set<Int64>) {
        if e.type == 10 {
            held.insert(event.getIntegerValueField(.keyboardEventKeycode))
        } else if e.type == 11 {
            held.remove(event.getIntegerValueField(.keyboardEventKeycode))
        } else if e.type == 12 {
            // Modifier transitions: track the key code either way; the
            // final cleanup key-up is harmless if it was already released.
            held.insert(event.getIntegerValueField(.keyboardEventKeycode))
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
