import Foundation
import AppKit
import CoreGraphics
import CEventCodec

// A raw captured input event, as it comes off the event tap: serialized
// CGEvent bytes plus seconds since the start of the recording.
struct RecordedEvent: Codable {
    var t: Double
    var type: UInt32
    var data: Data
}

// A macro is an ordered list of steps. Each step waits `delay` seconds
// after the previous one, then performs its payload — either a raw
// recorded event replayed verbatim, or an action the user added by hand.
// The split is what makes recordings editable: steps can be reordered,
// deleted, and interleaved with manual actions freely.
struct MacroItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var delay: Double
    var payload: Payload
    var label: String
    // Run this step several times, with a fixed or randomized interval.
    var repeats: RepeatSpec?
    // Only run this step when the condition holds; otherwise skip it.
    var condition: Condition?

    enum Payload: Codable, Equatable {
        case raw(type: UInt32, data: Data)
        case action(ManualAction)
    }
}

struct RepeatSpec: Codable, Equatable {
    var count: Int = 2
    var minInterval: Double = 0.1
    var maxInterval: Double = 0.1  // equal to min → fixed interval

    var label: String {
        if maxInterval > minInterval {
            return String(format: "×%d (%.2f–%.2fs)", count,
                          minInterval, maxInterval)
        }
        return String(format: "×%d (%.2fs)", count, minInterval)
    }

    var randomized: Bool { maxInterval > minInterval }

    func nextInterval() -> Double {
        let lo = max(0, min(minInterval, maxInterval))
        let hi = max(minInterval, maxInterval)
        return hi > lo ? Double.random(in: lo...hi) : lo
    }
}

// A live check against the real world, evaluated at playback time.
// Powers per-step "only if", the Wait Until action, and conditional
// jumps ("go to step 3 while F6 is held").
struct Condition: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case keyHeld, mouseHeld, modifiersHeld, pointerIn
        var id: String { rawValue }

        var title: String {
            switch self {
            case .keyHeld: return "key is held"
            case .mouseHeld: return "mouse button is held"
            case .modifiersHeld: return "modifiers are held"
            case .pointerIn: return "pointer is in region"
            }
        }
    }

    var kind: Kind = .keyHeld
    var negated: Bool = false
    var keyCode: UInt16 = 0
    var button: MouseButtonKind = .left
    var modifiers: UInt = 0
    var x: Double = 0
    var y: Double = 0
    var w: Double = 0
    var h: Double = 0

    var label: String {
        let what: String
        switch kind {
        case .keyHeld:
            what = "\(KeyNames.name(for: keyCode)) held"
        case .mouseHeld:
            what = "\(button.rawValue) button held"
        case .modifiersHeld:
            what = "\(Hotkey.symbols(for: NSEvent.ModifierFlags(rawValue: modifiers))) held"
        case .pointerIn:
            what = "pointer in (\(Int(x)), \(Int(y)), \(Int(w))×\(Int(h)))"
        }
        return (negated ? "if not " : "if ") + what
    }

    // Polls actual hardware/session state via public CG APIs.
    func holds() -> Bool {
        let result: Bool
        switch kind {
        case .keyHeld:
            result = CGEventSource.keyState(.combinedSessionState,
                                            key: CGKeyCode(keyCode))
        case .mouseHeld:
            result = CGEventSource.buttonState(.combinedSessionState,
                                               button: button.cgButton)
        case .modifiersHeld:
            let state = CGEventSource.flagsState(.combinedSessionState)
            let need = Hotkey(keyCode: 0, modifiers: modifiers).cgFlags
            result = state.contains(need)
        case .pointerIn:
            if let loc = CGEvent(source: nil)?.location {
                result = loc.x >= x && loc.x <= x + w
                    && loc.y >= y && loc.y <= y + h
            } else {
                result = false
            }
        }
        return negated ? !result : result
    }
}

enum MouseButtonKind: String, Codable, CaseIterable, Identifiable {
    case left, right, middle
    var id: String { rawValue }

    var cgButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }

    var downType: CGEventType {
        switch self {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }

    var upType: CGEventType {
        switch self {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }
}

// Every action a user can add without recording. The last three are
// control flow: they steer playback instead of producing input.
enum ManualAction: Codable, Equatable {
    case click(x: Double, y: Double, button: MouseButtonKind, count: Int)
    case movePointer(x: Double, y: Double)
    case keyPress(keyCode: UInt16, modifiers: UInt)
    case typeText(text: String)
    case scroll(dx: Int, dy: Int)
    case wait
    case waitUntil(condition: Condition, timeout: Double)
    case goTo(step: Int, times: Int)
    case stopPlayback

    var label: String {
        switch self {
        case .click(let x, let y, let button, let count):
            let prefix = count == 2 ? "double " : count == 3 ? "triple " : ""
            return "\(prefix)\(button.rawValue) click at (\(Int(x)), \(Int(y)))"
        case .movePointer(let x, let y):
            return "move pointer to (\(Int(x)), \(Int(y)))"
        case .keyPress(let code, let mods):
            return "press \(Hotkey(keyCode: code, modifiers: mods).display)"
        case .typeText(let text):
            let short = text.count > 24 ? String(text.prefix(24)) + "…" : text
            return "type “\(short)”"
        case .scroll(let dx, let dy):
            return "scroll (\(dx), \(dy))"
        case .wait:
            return "wait"
        case .waitUntil(let condition, let timeout):
            var s = "wait until \(condition.label.dropFirst(3))"
            if timeout > 0 { s += String(format: " (max %.1fs)", timeout) }
            return s
        case .goTo(let step, let times):
            var s = "go to step \(step)"
            if times > 0 { s += " (at most ×\(times))" }
            return s
        case .stopPlayback:
            return "stop playback"
        }
    }
}

struct Hotkey: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt  // NSEvent.ModifierFlags rawValue, device-independent

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var cgFlags: CGEventFlags {
        var f = CGEventFlags()
        if flags.contains(.command) { f.insert(.maskCommand) }
        if flags.contains(.option) { f.insert(.maskAlternate) }
        if flags.contains(.control) { f.insert(.maskControl) }
        if flags.contains(.shift) { f.insert(.maskShift) }
        return f
    }

    var display: String {
        Hotkey.symbols(for: flags) + KeyNames.name(for: keyCode)
    }

    static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }
}

struct Macro: Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var created: Date = Date()
    var hotkey: Hotkey?
    var items: [MacroItem]

    static func == (a: Macro, b: Macro) -> Bool { a.id == b.id }

    var duration: Double { items.reduce(0) { $0 + $1.delay } }

    var summary: String {
        let manual = items.filter {
            if case .action = $0.payload { return true } else { return false }
        }.count
        var s = "\(items.count) steps"
        if manual > 0 { s += " (\(manual) manual)" }
        return s + String(format: "  ·  %.1fs", duration)
    }
}

// Codable by hand so macros saved by the previous version (a flat list
// of timestamped events) still load; they're converted to steps.
extension Macro: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, created, hotkey, items, events
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        created = try c.decode(Date.self, forKey: .created)
        hotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey)
        if let items = try c.decodeIfPresent([MacroItem].self, forKey: .items) {
            self.items = items
        } else if let events = try c.decodeIfPresent(
            [RecordedEvent].self, forKey: .events) {
            self.items = Macro.items(from: events)
        } else {
            self.items = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(created, forKey: .created)
        try c.encodeIfPresent(hotkey, forKey: .hotkey)
        try c.encode(items, forKey: .items)
    }

    // Convert a recording (absolute timestamps) into steps (relative
    // delays), dropping trailing modifier noise from the stop shortcut.
    static func items(from events: [RecordedEvent]) -> [MacroItem] {
        var evs = events
        while let last = evs.last, last.type == 12 { evs.removeLast() }
        var prev = 0.0
        return evs.map { e in
            let item = MacroItem(
                delay: max(0, e.t - prev),
                payload: .raw(type: e.type, data: e.data),
                label: RawEventInfo.label(type: e.type, data: e.data))
            prev = e.t
            return item
        }
    }
}

extension MacroItem {
    // The editable equivalent of a raw recorded event, when one exists.
    // Press-type events convert (their matching release is removed by
    // the caller); releases, modifier transitions and gestures have no
    // standalone editable form.
    var convertedAction: ManualAction? {
        guard case .raw(let type, let data) = payload,
              let ev = MAHEventCreateFromData(data as CFData)
        else { return nil }
        switch type {
        case 1, 3, 25:
            let btn: MouseButtonKind =
                type == 1 ? .left : type == 3 ? .right : .middle
            return .click(x: ev.location.x, y: ev.location.y,
                          button: btn, count: 1)
        case 10:
            let code = UInt16(ev.getIntegerValueField(.keyboardEventKeycode))
            var mods: NSEvent.ModifierFlags = []
            if ev.flags.contains(.maskCommand) { mods.insert(.command) }
            if ev.flags.contains(.maskAlternate) { mods.insert(.option) }
            if ev.flags.contains(.maskControl) { mods.insert(.control) }
            if ev.flags.contains(.maskShift) { mods.insert(.shift) }
            return .keyPress(keyCode: code, modifiers: mods.rawValue)
        case 22:
            return .scroll(
                dx: Int(ev.getIntegerValueField(.scrollWheelEventDeltaAxis2)),
                dy: Int(ev.getIntegerValueField(.scrollWheelEventDeltaAxis1)))
        case 5, 6, 7, 27:
            return .movePointer(x: ev.location.x, y: ev.location.y)
        default:
            return nil
        }
    }

    // The raw event type of the matching release for a press-type raw
    // event — used to clean up the pair when converting.
    var pairedReleaseType: UInt32? {
        guard case .raw(let type, _) = payload else { return nil }
        switch type {
        case 1: return 2
        case 3: return 4
        case 25: return 26
        case 10: return 11
        default: return nil
        }
    }

    var rawKeyCode: UInt16? {
        guard case .raw(_, let data) = payload,
              let ev = MAHEventCreateFromData(data as CFData)
        else { return nil }
        return UInt16(ev.getIntegerValueField(.keyboardEventKeycode))
    }
}

// Human-readable one-liners for raw recorded events, shown in the editor.
enum RawEventInfo {
    static func label(type: UInt32, data: Data) -> String {
        let ev = MAHEventCreateFromData(data as CFData)
        let loc = ev.map { "(\(Int($0.location.x)), \(Int($0.location.y)))" } ?? ""
        switch type {
        case 1: return "left click ↓ \(loc)"
        case 2: return "left click ↑ \(loc)"
        case 3: return "right click ↓ \(loc)"
        case 4: return "right click ↑ \(loc)"
        case 25: return "middle click ↓ \(loc)"
        case 26: return "middle click ↑ \(loc)"
        case 5: return "move \(loc)"
        case 6, 7, 27: return "drag \(loc)"
        case 10, 11:
            let code = ev.map {
                UInt16($0.getIntegerValueField(.keyboardEventKeycode))
            } ?? 0
            return "key \(type == 10 ? "↓" : "↑") \(KeyNames.name(for: code))"
        case 12:
            let code = ev.map {
                UInt16($0.getIntegerValueField(.keyboardEventKeycode))
            } ?? 0
            return "modifier \(KeyNames.name(for: code))"
        case 22:
            let dy = ev?.getIntegerValueField(.scrollWheelEventDeltaAxis1) ?? 0
            let dx = ev?.getIntegerValueField(.scrollWheelEventDeltaAxis2) ?? 0
            return "scroll (\(dx), \(dy))"
        case 18: return "rotate gesture"
        case 19: return "gesture begin"
        case 20: return "gesture end"
        case 29: return "trackpad gesture"
        case 30: return "pinch gesture"
        case 31: return "swipe gesture"
        case 32: return "smart zoom"
        case 34: return "pressure"
        default: return "event \(type)"
        }
    }
}

// Persists macros as individual JSON files in Application Support.
@MainActor
final class MacroStore: ObservableObject {
    @Published private(set) var macros: [Macro] = []

    private let dir: URL

    init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("MacAHK/Macros", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        load()
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        var found: [Macro] = []
        for f in files where f.pathExtension == "json" {
            if let data = try? Data(contentsOf: f),
               let m = try? JSONDecoder().decode(Macro.self, from: data) {
                found.append(m)
            }
        }
        macros = found.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func upsert(_ macro: Macro) {
        if let i = macros.firstIndex(where: { $0.id == macro.id }) {
            macros[i] = macro
        } else {
            macros.append(macro)
        }
        persist(macro)
    }

    func delete(_ macro: Macro) {
        macros.removeAll { $0.id == macro.id }
        try? FileManager.default.removeItem(at: url(for: macro))
    }

    func macro(id: UUID?) -> Macro? {
        guard let id else { return nil }
        return macros.first { $0.id == id }
    }

    private func url(for macro: Macro) -> URL {
        dir.appendingPathComponent(macro.id.uuidString + ".json")
    }

    private func persist(_ macro: Macro) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(macro) {
            try? data.write(to: url(for: macro), options: .atomic)
        }
    }
}

// Readable names for common virtual key codes (ANSI layout); anything
// unmapped falls back to "key <n>". Only used for display.
enum KeyNames {
    static let map: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
        50: "`", 51: "⌫", 53: "⎋", 54: "⌘", 55: "⌘", 56: "⇧", 57: "⇪",
        58: "⌥", 59: "⌃", 60: "⇧", 61: "⌥", 62: "⌃", 96: "F5", 97: "F6",
        98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10",
        111: "F12", 118: "F4", 120: "F2", 122: "F1", 123: "←",
        124: "→", 125: "↓", 126: "↑",
    ]

    static func name(for code: UInt16) -> String {
        map[code] ?? "key \(code)"
    }
}
