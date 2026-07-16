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
// jumps ("go to step 3 while F6 is held"). The pixel kinds look at the
// actual screen and need the Screen Recording permission.
struct Condition: Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case keyHeld, mouseHeld, modifiersHeld, pointerIn
        case pixelColor, regionLooksLike, imageOnScreen
        case appFrontmost, windowTitled, clipboardContains
        var id: String { rawValue }

        var title: String {
            switch self {
            case .keyHeld: return "key is held"
            case .mouseHeld: return "mouse button is held"
            case .modifiersHeld: return "modifiers are held"
            case .pointerIn: return "pointer is in region"
            case .pixelColor: return "pixel color matches"
            case .regionLooksLike: return "area looks like snapshot"
            case .imageOnScreen: return "image is on screen"
            case .appFrontmost: return "app is frontmost"
            case .windowTitled: return "a window title contains"
            case .clipboardContains: return "clipboard contains"
            }
        }

        // Screen captures are ~ms-expensive (and the full-screen image
        // search much more so); pollers back off for these.
        var isPixelBased: Bool {
            self == .pixelColor || self == .regionLooksLike
                || self == .imageOnScreen
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
    // Pixel conditions: target color, match tolerance in percent, and
    // the reference snapshot (PNG) for regionLooksLike.
    var r: Int = 0
    var g: Int = 0
    var b: Int = 0
    var tolerance: Double = 12
    var reference: Data?
    // App name / window title fragment / clipboard fragment for the
    // app-aware and clipboard conditions. Matched case-insensitively.
    var text: String = ""

    var hexColor: String { String(format: "#%02X%02X%02X", r, g, b) }

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
        case .pixelColor:
            what = "pixel (\(Int(x)), \(Int(y))) ≈ \(hexColor)"
        case .regionLooksLike:
            what = "area (\(Int(x)), \(Int(y)), \(Int(w))×\(Int(h))) matches snapshot"
        case .imageOnScreen:
            what = "image is somewhere on screen"
        case .appFrontmost:
            what = "“\(text)” is frontmost"
        case .windowTitled:
            what = "a window titled “\(text)” is open"
        case .clipboardContains:
            let short = text.count > 18 ? String(text.prefix(18)) + "…" : text
            what = "clipboard contains “\(short)”"
        }
        return (negated ? "if not " : "if ") + what
    }

    // Polls actual hardware/session/screen state via public CG APIs.
    func holds() -> Bool {
        var result = false
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
            }
        case .pixelColor:
            if let px = ScreenSampler.pixelRGB(at: CGPoint(x: x, y: y)) {
                let tol = Int(tolerance / 100.0 * 255.0)
                result = abs(px.r - r) <= tol && abs(px.g - g) <= tol
                    && abs(px.b - b) <= tol
            }
        case .regionLooksLike:
            if let ref = reference,
               let refImage = ScreenSampler.image(fromPNG: ref),
               let current = ScreenSampler.capture(
                   rect: CGRect(x: x, y: y, width: w, height: h)),
               let diff = ScreenSampler.difference(refImage, current) {
                result = diff <= tolerance / 100.0
            }
        case .imageOnScreen:
            if let ref = reference,
               let template = ScreenSampler.image(fromPNG: ref) {
                result = ScreenSampler.findOnScreen(
                    template: template,
                    tolerance: tolerance / 100.0) != nil
            }
        case .appFrontmost:
            let t = text.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty,
               let front = NSWorkspace.shared.frontmostApplication {
                result = (front.localizedName?
                    .localizedCaseInsensitiveContains(t) ?? false)
                    || (front.bundleIdentifier?
                        .localizedCaseInsensitiveContains(t) ?? false)
            }
        case .windowTitled:
            result = Condition.windowExists(titled: text)
        case .clipboardContains:
            let t = text
            if !t.isEmpty,
               let s = NSPasteboard.general.string(forType: .string) {
                result = s.localizedCaseInsensitiveContains(t)
            }
        }
        return negated ? !result : result
    }

    // True when any on-screen window's title (or its owning app's name)
    // contains the fragment. Window titles are only visible to us when
    // Screen Recording is granted; app names always are, so "wait until
    // window Safari" degrades gracefully without the permission.
    static func windowExists(titled fragment: String) -> Bool {
        let t = fragment.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]] else { return false }
        for info in list {
            if let name = info[kCGWindowName as String] as? String,
               name.localizedCaseInsensitiveContains(t) { return true }
            if let owner = info[kCGWindowOwnerName as String] as? String,
               owner.localizedCaseInsensitiveContains(t) { return true }
        }
        return false
    }
}

// Codable by hand: every field decodes with a default, so macros saved
// before a field existed keep loading.
extension Condition: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, negated, keyCode, button, modifiers, x, y, w, h
        case r, g, b, tolerance, reference, text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .keyHeld
        negated = try c.decodeIfPresent(Bool.self, forKey: .negated) ?? false
        keyCode = try c.decodeIfPresent(UInt16.self, forKey: .keyCode) ?? 0
        button = try c.decodeIfPresent(MouseButtonKind.self,
                                       forKey: .button) ?? .left
        modifiers = try c.decodeIfPresent(UInt.self, forKey: .modifiers) ?? 0
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        w = try c.decodeIfPresent(Double.self, forKey: .w) ?? 0
        h = try c.decodeIfPresent(Double.self, forKey: .h) ?? 0
        r = try c.decodeIfPresent(Int.self, forKey: .r) ?? 0
        g = try c.decodeIfPresent(Int.self, forKey: .g) ?? 0
        b = try c.decodeIfPresent(Int.self, forKey: .b) ?? 0
        tolerance = try c.decodeIfPresent(Double.self,
                                          forKey: .tolerance) ?? 12
        reference = try c.decodeIfPresent(Data.self, forKey: .reference)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(negated, forKey: .negated)
        try c.encode(keyCode, forKey: .keyCode)
        try c.encode(button, forKey: .button)
        try c.encode(modifiers, forKey: .modifiers)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(w, forKey: .w)
        try c.encode(h, forKey: .h)
        try c.encode(r, forKey: .r)
        try c.encode(g, forKey: .g)
        try c.encode(b, forKey: .b)
        try c.encode(tolerance, forKey: .tolerance)
        try c.encodeIfPresent(reference, forKey: .reference)
        try c.encode(text, forKey: .text)
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
    case mouseDown(x: Double, y: Double, button: MouseButtonKind)
    case mouseUp(x: Double, y: Double, button: MouseButtonKind)
    case movePointer(x: Double, y: Double)
    case keyPress(keyCode: UInt16, modifiers: UInt)
    case typeText(text: String)
    case scroll(dx: Int, dy: Int)
    case openApp(name: String)
    case openURL(url: String)
    case setClipboard(text: String)
    case pasteClipboard
    case clickImage(reference: Data?, tolerance: Double,
                    button: MouseButtonKind, moveOnly: Bool)
    case notify(message: String)
    case beep
    case wait
    case waitUntil(condition: Condition, timeout: Double)
    case goTo(step: Int, times: Int)
    case stopPlayback

    var label: String {
        switch self {
        case .click(let x, let y, let button, let count):
            let prefix = count == 2 ? "double " : count == 3 ? "triple "
                : count > 3 ? "\(count)× " : ""
            return "\(prefix)\(button.rawValue) click at (\(Int(x)), \(Int(y)))"
        case .mouseDown(let x, let y, let button):
            return "press and hold \(button.rawValue) at (\(Int(x)), \(Int(y)))"
        case .mouseUp(let x, let y, let button):
            return "release \(button.rawValue) at (\(Int(x)), \(Int(y)))"
        case .movePointer(let x, let y):
            return "move pointer to (\(Int(x)), \(Int(y)))"
        case .keyPress(let code, let mods):
            return "press \(Hotkey(keyCode: code, modifiers: mods).display)"
        case .typeText(let text):
            let short = text.count > 24 ? String(text.prefix(24)) + "…" : text
            return "type “\(short)”"
        case .scroll(let dx, let dy):
            return "scroll (\(dx), \(dy))"
        case .openApp(let name):
            return "open app “\(name)”"
        case .openURL(let url):
            let short = url.count > 36 ? String(url.prefix(36)) + "…" : url
            return "open \(short)"
        case .setClipboard(let text):
            let short = text.count > 24 ? String(text.prefix(24)) + "…" : text
            return "set clipboard to “\(short)”"
        case .pasteClipboard:
            return "paste clipboard (⌘V)"
        case .clickImage(_, _, let button, let moveOnly):
            return moveOnly ? "move pointer to image on screen"
                            : "\(button.rawValue) click image on screen"
        case .notify(let message):
            let short = message.count > 24
                ? String(message.prefix(24)) + "…" : message
            return "notify “\(short)”"
        case .beep:
            return "beep"
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
    // Plain clicks coalesce into a single editable Click step per click
    // (double/triple bursts included) instead of confusing press/release
    // pairs. Drags, deliberate holds, force clicks and modifier-clicks
    // keep the full raw event detail.
    static func items(from events: [RecordedEvent]) -> [MacroItem] {
        var evs = events
        while let last = evs.last, last.type == 12 { evs.removeLast() }

        var items: [MacroItem] = []
        var prev = 0.0
        var i = 0
        while i < evs.count {
            let e = evs[i]
            if let (action, consumed, endT) = coalescedClick(in: evs, at: i) {
                items.append(MacroItem(delay: max(0, e.t - prev),
                                       payload: .action(action),
                                       label: action.label))
                prev = endT
                i += consumed
                continue
            }
            items.append(MacroItem(
                delay: max(0, e.t - prev),
                payload: .raw(type: e.type, data: e.data),
                label: RawEventInfo.label(type: e.type, data: e.data)))
            prev = e.t
            i += 1
        }
        return items
    }

    private static let clickMods: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl, .maskShift]

    // Try to read a plain click — or a double/triple burst — starting at
    // `start`. Returns the Click action, how many events it consumed and
    // the timestamp of the last one. Returns nil for anything that isn't
    // a plain click: real movement (a drag), a hold over 0.4s, modifier
    // flags, or a force-click's pressure ramp — those all stay raw.
    private static func coalescedClick(in evs: [RecordedEvent], at start: Int)
        -> (ManualAction, Int, Double)? {
        let pairs: [UInt32: (up: UInt32, drag: UInt32, btn: MouseButtonKind)] = [
            1: (2, 6, .left), 3: (4, 7, .right), 25: (26, 27, .middle),
        ]
        guard let kinds = pairs[evs[start].type],
              let firstDown = MAHEventCreateFromData(evs[start].data as CFData)
        else { return nil }
        let origin = firstDown.location

        var count = 0
        var expectedState: Int64 = 1
        var lastT = evs[start].t
        var i = start

        while i < evs.count, evs[i].type == evs[start].type,
              let down = MAHEventCreateFromData(evs[i].data as CFData) {
            let state = down.getIntegerValueField(.mouseEventClickState)
            if count == 0 {
                // A burst must start at click #1; a stray later click of
                // a double (e.g. after a modifier press) stays raw.
                guard state <= 1 else { return nil }
            } else {
                guard state == expectedState,
                      evs[i].t - lastT <= 0.5,
                      near(down.location, origin, 5) else { break }
            }
            guard down.flags.isDisjoint(with: clickMods) else { break }

            // Walk to the matching release, tolerating only cursor
            // jitter and a little trackpad pressure noise. A force
            // click's long pressure ramp fails the cap and stays raw.
            var j = i + 1
            var pressureNoise = 0
            scan: while j < evs.count {
                switch evs[j].type {
                case 34 where pressureNoise < 6:
                    pressureNoise += 1
                    j += 1
                case kinds.drag:
                    guard let drag = MAHEventCreateFromData(
                              evs[j].data as CFData),
                          near(drag.location, origin, 3) else { break scan }
                    j += 1
                default:
                    break scan
                }
            }
            guard j < evs.count, evs[j].type == kinds.up,
                  evs[j].t - evs[i].t <= 0.4,
                  let up = MAHEventCreateFromData(evs[j].data as CFData),
                  near(up.location, origin, 3)
            else { break }

            count += 1
            expectedState = state + 1
            lastT = evs[j].t
            i = j + 1

            // Peek past pressure noise between burst pairs, consuming it
            // only when another matching down actually follows.
            var k = i
            var betweenNoise = 0
            while k < evs.count, evs[k].type == 34, betweenNoise < 6 {
                k += 1
                betweenNoise += 1
            }
            if k < evs.count, evs[k].type == evs[start].type { i = k }
        }

        guard count > 0 else { return nil }
        return (.click(x: origin.x, y: origin.y, button: kinds.btn,
                       count: count),
                i - start, lastT)
    }

    private static func near(_ a: CGPoint, _ b: CGPoint,
                             _ tolerance: Double) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
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
        // "press"/"release" spelled out: the old ↓/↑ glyphs read like
        // the arrow keys, which confused everyone.
        switch type {
        case 1: return "left click (press) \(loc)"
        case 2: return "left click (release) \(loc)"
        case 3: return "right click (press) \(loc)"
        case 4: return "right click (release) \(loc)"
        case 25: return "middle click (press) \(loc)"
        case 26: return "middle click (release) \(loc)"
        case 5: return "move \(loc)"
        case 6, 7, 27: return "drag \(loc)"
        case 10, 11:
            let code = ev.map {
                UInt16($0.getIntegerValueField(.keyboardEventKeycode))
            } ?? 0
            return "key \(KeyNames.name(for: code)) \(type == 10 ? "(press)" : "(release)")"
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
