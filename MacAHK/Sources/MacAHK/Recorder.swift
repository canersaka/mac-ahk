import Foundation
import CoreGraphics
import CEventCodec

// Captures global input through a listen-only CGEventTap and stores each
// event as raw serialized bytes. Because the tap sits at the session
// level, it sees everything the window server sees: keys, clicks, drags,
// scroll wheels with momentum phases, and trackpad gestures (magnify,
// rotate, swipe, smart-magnify, pressure).
final class Recorder {
    // Raw NSEvent/CGEvent type values worth keeping. 5 (mouseMoved) is
    // included only when captureMoves is on; 14 (systemDefined, media
    // keys) is deliberately excluded.
    private static let wanted: Set<UInt32> = [
        1, 2, 3, 4, 25, 26,          // mouse down/up (left/right/other)
        6, 7, 27,                    // drags
        10, 11, 12,                  // keyDown, keyUp, flagsChanged
        22,                          // scrollWheel
        18, 19, 20, 29, 30, 31, 32, 34, // gestures: rotate, begin/end,
                                     // gesture, magnify, swipe,
                                     // smartMagnify, pressure
    ]
    private static let escKeyCode: Int64 = 53

    private(set) var events: [RecordedEvent] = []
    var captureMoves = false
    // Called on the main queue when the user presses Esc.
    var onEscape: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var startTime: CFAbsoluteTime = 0
    private let lock = NSLock()
    private(set) var isRecording = false

    func start() -> Bool {
        guard !isRecording else { return false }
        events = []
        startTime = CFAbsoluteTimeGetCurrent()

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                let recorder = Unmanaged<Recorder>.fromOpaque(refcon)
                    .takeUnretainedValue()
                recorder.handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(~0),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRecording = true
        return true
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        tap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // The window server disables taps that stall; re-arm if it happens.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard isRecording else { return }

        let raw = type.rawValue

        // Esc ends the recording and is never stored.
        if raw == 10 || raw == 11 {
            if event.getIntegerValueField(.keyboardEventKeycode) == Self.escKeyCode {
                if raw == 10 {
                    DispatchQueue.main.async { [weak self] in self?.onEscape?() }
                }
                return
            }
        }

        // Ignore anything aimed at our own UI (clicking Stop, etc.).
        if event.getIntegerValueField(.eventTargetUnixProcessID) == Int64(getpid()) {
            return
        }

        guard Self.wanted.contains(raw) || (captureMoves && raw == 5) else { return }

        guard let cfData = MAHEventCreateData(event) else { return }
        let recorded = RecordedEvent(
            t: CFAbsoluteTimeGetCurrent() - startTime,
            type: raw,
            data: cfData as Data)
        lock.lock()
        events.append(recorded)
        lock.unlock()
    }
}
