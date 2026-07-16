import Foundation
import AppKit
import SwiftUI

// A line-based script language that maps 1:1 onto macro steps, with
// enough AutoHotkey v1 compatibility that many AHK scripts paste
// straight in. Variables, expressions and control structures have no
// equivalent here — those lines come back as warnings instead of
// silently vanishing.
//
//   ; comments start with ; (or #, AHK directives are skipped)
//   F6::                     ; AHK hotkey label → becomes the macro hotkey
//   ::btw::by the way        ; hotstring → system-wide text expansion
//   click 100, 200           ; left click (also: click 100 200 right 2)
//   mousedown 100, 200       ; press and hold (AHK `click 100 200 down`)
//   mouseup 300, 400         ; release — press/move/release makes a drag
//   mousemove 300, 400
//   send Hello world{Enter}  ; types text; {Enter}/{Tab}/{Space} expand
//   press cmd+shift+a        ; key combo (AHK ^!+# prefixes work too)
//   scroll 0, -120
//   run Safari               ; open/activate an app (AHK Run/WinActivate)
//   run https://apple.com    ; …or a URL, in the default browser
//   winwait Untitled, 10     ; wait for a window title (max 10s)
//   ifwinactive Safari       ; NEXT step runs only if the app is frontmost
//   clipboard Hello          ; put text on the clipboard
//   paste                    ; press ⌘V
//   notify All done          ; notification banner (AHK MsgBox/TrayTip)
//   beep                     ; system alert sound
//   sleep 500                ; ms — becomes the next step's delay
//   wait 1.5                 ; seconds — same thing
//   waituntil key f6, 10     ; pause until condition (max 10s, 0=forever)
//   waituntil window Save As ; …conditions can be app-aware, too
//   goto 2, 50               ; jump to step 2, at most 50 times
//   stop                     ; end playback
//   repeat 1000, 0.1, 0.3    ; modifies the PREVIOUS step: run 1000×,
//                            ; random 0.1–0.3s apart (one number = fixed)
//   onlyif key f6            ; previous step runs only while F6 is held
//   onlyifnot mouse right    ; ...or only while right button is NOT held
//
// Conditions: key <name> · mouse <left|right|middle> · mods <cmd+shift>
//             · region <x> <y> <w> <h> · pixel <x> <y> <#rrggbb> [tol]
//             · app <name> · window <title fragment> · clipboard <text>
enum ScriptParser {
    struct Result {
        var items: [MacroItem] = []
        var warnings: [String] = []
        var hotkey: Hotkey?
        var hotstrings: [Hotstring] = []
        // Set by ifwinactive; consumed by the next appended step.
        var pendingCondition: Condition?
    }

    private static let defaultGap = 0.05

    static func parse(_ text: String) -> Result {
        var result = Result()
        var pendingDelay = 0.0

        for (lineNo, rawLine) in text.components(separatedBy: .newlines)
            .enumerated() {
            let n = lineNo + 1
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") { continue }
            if line.hasPrefix("#") {
                warn(&result, n, "AHK directive skipped: \(line)")
                continue
            }
            if let r = line.range(of: " ;") {
                line = String(line[..<r.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }

            // Hotstrings: `::btw::by the way` (an AHK options block like
            // `:*:` is accepted and ignored — expansion always fires
            // immediately here, which is what * means).
            if line.hasPrefix(":") {
                if let hs = hotstring(fromLine: line) {
                    result.hotstrings.append(hs)
                } else {
                    warn(&result, n, "couldn't read hotstring: \(line)")
                }
                continue
            }

            // AHK hotkey labels: `F6::` / `^!a::`.
            if line.hasSuffix("::") {
                let combo = String(line.dropLast(2))
                if let hk = hotkey(fromAHKLabel: combo) {
                    if result.hotkey == nil {
                        result.hotkey = hk
                    } else {
                        warn(&result, n,
                             "only one hotkey per macro; extra label ignored")
                    }
                } else {
                    warn(&result, n, "couldn't read hotkey label: \(line)")
                }
                continue
            }
            if line == "{" || line == "}" || line.lowercased() == "return" {
                continue  // AHK block noise; harmless to drop
            }

            parseCommand(line, lineNo: n, into: &result,
                         pendingDelay: &pendingDelay)
        }
        return result
    }

    // MARK: command dispatch

    private static func parseCommand(_ line: String, lineNo: Int,
                                     into result: inout Result,
                                     pendingDelay: inout Double) {
        let (head, tail) = splitCommand(line)
        let args = splitArgs(tail)

        switch head {
        case "click", "leftclick", "rightclick", "middleclick",
             "doubleclick":
            let numbers = args.compactMap { Double($0) }
            guard numbers.count >= 2 else {
                warn(&result, lineNo,
                     "click needs coordinates, e.g. `click 100, 200` — line skipped")
                return
            }
            var button: MouseButtonKind = head == "rightclick" ? .right
                : head == "middleclick" ? .middle : .left
            var count = head == "doubleclick" ? 2 : 1
            var pressOnly = false
            var releaseOnly = false
            for word in args where Double(word) == nil {
                let w = word.lowercased()
                if let b = MouseButtonKind(rawValue: w) {
                    button = b
                } else if w == "down" || w == "d" {   // AHK `Click Down`
                    pressOnly = true
                } else if w == "up" || w == "u" {     // AHK `Click Up`
                    releaseOnly = true
                }
            }
            if numbers.count >= 3 { count = max(1, Int(numbers[2])) }
            if pressOnly {
                append(.mouseDown(x: numbers[0], y: numbers[1],
                                  button: button),
                       to: &result, pendingDelay: &pendingDelay)
            } else if releaseOnly {
                append(.mouseUp(x: numbers[0], y: numbers[1],
                                button: button),
                       to: &result, pendingDelay: &pendingDelay)
            } else {
                append(.click(x: numbers[0], y: numbers[1], button: button,
                              count: count),
                       to: &result, pendingDelay: &pendingDelay)
            }

        case "mousedown", "clickdown", "mouseup", "clickup":
            let numbers = args.compactMap { Double($0) }
            guard numbers.count >= 2 else {
                warn(&result, lineNo,
                     "\(head) needs coordinates, e.g. `mousedown 100, 200` — line skipped")
                return
            }
            var button: MouseButtonKind = .left
            for word in args where Double(word) == nil {
                if let b = MouseButtonKind(rawValue: word.lowercased()) {
                    button = b
                }
            }
            let isDown = head == "mousedown" || head == "clickdown"
            append(isDown
                       ? .mouseDown(x: numbers[0], y: numbers[1],
                                    button: button)
                       : .mouseUp(x: numbers[0], y: numbers[1],
                                  button: button),
                   to: &result, pendingDelay: &pendingDelay)

        case "mousemove", "move":
            let numbers = args.compactMap { Double($0) }
            guard numbers.count >= 2 else {
                warn(&result, lineNo, "mousemove needs x, y — line skipped")
                return
            }
            append(.movePointer(x: numbers[0], y: numbers[1]),
                   to: &result, pendingDelay: &pendingDelay)

        case "send", "sendinput", "sendraw", "sendtext", "type":
            handleSend(tail, lineNo: lineNo, raw: head == "sendraw",
                       into: &result, pendingDelay: &pendingDelay)

        case "press", "sendkey", "key":
            if let hk = hotkey(fromCombo: tail) {
                append(.keyPress(keyCode: hk.keyCode,
                                 modifiers: hk.modifiers),
                       to: &result, pendingDelay: &pendingDelay)
            } else {
                warn(&result, lineNo, "couldn't read key combo: \(tail)")
            }

        case "scroll", "mousewheel":
            let numbers = args.compactMap { Int($0) }
            guard numbers.count >= 2 else {
                warn(&result, lineNo, "scroll needs dx, dy — line skipped")
                return
            }
            append(.scroll(dx: numbers[0], dy: numbers[1]),
                   to: &result, pendingDelay: &pendingDelay)

        case "wheelup":
            append(.scroll(dx: 0, dy: 120), to: &result,
                   pendingDelay: &pendingDelay)
        case "wheeldown":
            append(.scroll(dx: 0, dy: -120), to: &result,
                   pendingDelay: &pendingDelay)

        case "sleep":
            pendingDelay += (Double(args.first ?? "") ?? 0) / 1000.0
        case "wait", "delay":
            pendingDelay += Double(args.first ?? "") ?? 0

        case "waituntil":
            // A trailing number is a timeout — but only when the rest
            // still parses as a condition without it (a region condition
            // legitimately ends in numbers).
            if args.count >= 2, let timeout = Double(args.last!),
               let cond = condition(
                   from: args.dropLast().joined(separator: " ")) {
                append(.waitUntil(condition: cond, timeout: max(0, timeout)),
                       to: &result, pendingDelay: &pendingDelay)
            } else if let cond = condition(from: tail) {
                append(.waitUntil(condition: cond, timeout: 0),
                       to: &result, pendingDelay: &pendingDelay)
            } else {
                warn(&result, lineNo, "couldn't read condition: \(tail)")
            }

        case "goto", "jump":
            let numbers = args.compactMap { Int($0) }
            guard let step = numbers.first else {
                warn(&result, lineNo, "goto needs a step number")
                return
            }
            append(.goTo(step: max(1, step),
                         times: numbers.count >= 2 ? max(0, numbers[1]) : 0),
                   to: &result, pendingDelay: &pendingDelay)

        case "stop", "exit", "exitapp":
            append(.stopPlayback, to: &result, pendingDelay: &pendingDelay)

        case "run", "open":
            guard !tail.isEmpty else {
                warn(&result, lineNo, "\(head) needs an app name or URL")
                return
            }
            if tail.contains("://") || tail.lowercased().hasPrefix("mailto:") {
                append(.openURL(url: tail), to: &result,
                       pendingDelay: &pendingDelay)
            } else {
                append(.openApp(name: tail), to: &result,
                       pendingDelay: &pendingDelay)
            }

        case "url", "openurl":
            guard !tail.isEmpty else {
                warn(&result, lineNo, "url needs an address")
                return
            }
            append(.openURL(url: tail), to: &result,
                   pendingDelay: &pendingDelay)

        case "winactivate", "activate":
            guard !tail.isEmpty else {
                warn(&result, lineNo, "\(head) needs an app name")
                return
            }
            append(.openApp(name: tail), to: &result,
                   pendingDelay: &pendingDelay)

        case "winwait":
            // winwait <title>[, timeout seconds]
            guard !args.isEmpty else {
                warn(&result, lineNo, "winwait needs a window title")
                return
            }
            var title = tail
            var timeout = 0.0
            if args.count >= 2, let t = Double(args.last!) {
                timeout = max(0, t)
                title = args.dropLast().joined(separator: " ")
            }
            append(.waitUntil(
                       condition: Condition(kind: .windowTitled,
                                            text: title),
                       timeout: timeout),
                   to: &result, pendingDelay: &pendingDelay)

        case "ifwinactive":
            guard !tail.isEmpty else {
                warn(&result, lineNo, "ifwinactive needs an app name")
                return
            }
            // AHK style: the line after this one is the guarded one.
            result.pendingCondition = Condition(kind: .appFrontmost,
                                                text: tail)

        case "clipboard", "setclipboard":
            append(.setClipboard(text: tail), to: &result,
                   pendingDelay: &pendingDelay)

        case "paste":
            append(.pasteClipboard, to: &result,
                   pendingDelay: &pendingDelay)

        case "notify", "msgbox", "traytip", "tooltip":
            guard !tail.isEmpty else {
                warn(&result, lineNo, "\(head) needs a message")
                return
            }
            append(.notify(message: tail), to: &result,
                   pendingDelay: &pendingDelay)

        case "beep", "soundbeep":
            append(.beep, to: &result, pendingDelay: &pendingDelay)

        case "repeat":
            guard !result.items.isEmpty else {
                warn(&result, lineNo, "repeat must follow a step")
                return
            }
            let numbers = args.compactMap { Double($0) }
            guard let count = numbers.first, count >= 2 else {
                warn(&result, lineNo,
                     "repeat needs a count of 2 or more, e.g. `repeat 1000, 0.1, 0.3`")
                return
            }
            let lo = numbers.count >= 2 ? max(0, numbers[1]) : 0.1
            let hi = numbers.count >= 3 ? max(numbers[2], lo) : lo
            result.items[result.items.count - 1].repeats =
                RepeatSpec(count: Int(count), minInterval: lo,
                           maxInterval: hi)

        case "onlyif", "onlyifnot", "if", "ifnot":
            guard !result.items.isEmpty else {
                warn(&result, lineNo, "\(head) must follow a step")
                return
            }
            if var cond = condition(from: tail) {
                cond.negated = head.hasSuffix("not") ? !cond.negated
                                                     : cond.negated
                result.items[result.items.count - 1].condition = cond
            } else {
                warn(&result, lineNo, "couldn't read condition: \(tail)")
            }

        case "loop":
            warn(&result, lineNo,
                 "AHK Loop blocks aren't supported — use `repeat` on a step, or `goto` with a max count")

        case "imagesearch":
            warn(&result, lineNo,
                 "imagesearch needs an image file — add a Click Image action or an image-on-screen condition in the editor instead")

        case "winclose", "controlclick", "controlsend", "pixelsearch",
             "pixelgetcolor":
            warn(&result, lineNo,
                 "\(head) has no macOS equivalent in MacAHK — line skipped")

        default:
            warn(&result, lineNo, "unknown command: \(head)")
        }
    }

    private static func handleSend(_ text: String, lineNo: Int, raw: Bool,
                                   into result: inout Result,
                                   pendingDelay: inout Double) {
        var t = text
        if !raw {
            // Pure modifier-combo sends like `^c` or `#+s` become a key
            // press instead of typed text.
            let symbols = CharacterSet(charactersIn: "^!+#")
            if t.count >= 2, t.count <= 5,
               let last = t.last,
               t.dropLast().allSatisfy({ c in
                   c.unicodeScalars.allSatisfy { symbols.contains($0) }
               }),
               last.isLetter || last.isNumber,
               t.dropLast().count >= 1 {
                if let hk = hotkey(fromAHKLabel: t) {
                    append(.keyPress(keyCode: hk.keyCode,
                                     modifiers: hk.modifiers),
                           to: &result, pendingDelay: &pendingDelay)
                    return
                }
            }
            for (token, replacement) in [("{Enter}", "\n"), ("{enter}", "\n"),
                                         ("{Tab}", "\t"), ("{tab}", "\t"),
                                         ("{Space}", " "), ("{space}", " "),
                                         ("{{}", "{"), ("{}}", "}")] {
                t = t.replacingOccurrences(of: token, with: replacement)
            }
            while let open = t.range(of: "{"),
                  let close = t.range(of: "}",
                                      range: open.upperBound..<t.endIndex) {
                let token = String(t[open.upperBound..<close.lowerBound])
                warn(&result, lineNo,
                     "send token {\(token)} isn't supported and was dropped — use `press \(token.lowercased())` as its own step")
                t.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        guard !t.isEmpty else { return }
        append(.typeText(text: t), to: &result, pendingDelay: &pendingDelay)
    }

    // MARK: pieces

    private static func append(_ action: ManualAction,
                               to result: inout Result,
                               pendingDelay: inout Double) {
        var item = MacroItem(delay: max(0, pendingDelay),
                             payload: .action(action),
                             label: action.label)
        if let cond = result.pendingCondition {
            item.condition = cond
            result.pendingCondition = nil
        }
        result.items.append(item)
        pendingDelay = defaultGap
    }

    // `::trigger::replacement`, optionally with an AHK options block:
    // `:*:trigger::replacement`. Options are accepted and ignored.
    static func hotstring(fromLine line: String) -> Hotstring? {
        guard line.hasPrefix(":") else { return nil }
        let afterFirst = line.dropFirst()
        guard let optsEnd = afterFirst.firstIndex(of: ":") else {
            return nil
        }
        let body = afterFirst[afterFirst.index(after: optsEnd)...]
        guard let sep = body.range(of: "::") else { return nil }
        let trigger = String(body[..<sep.lowerBound])
        let replacement = String(body[sep.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        guard !trigger.isEmpty, !replacement.isEmpty else { return nil }
        return Hotstring(trigger: trigger, replacement: replacement)
    }

    private static func warn(_ result: inout Result, _ line: Int,
                             _ message: String) {
        result.warnings.append("line \(line): \(message)")
    }

    private static func splitCommand(_ line: String) -> (String, String) {
        // `Send, text` and `Send text` both work.
        guard let space = line.firstIndex(where: { $0 == " " || $0 == "," })
        else { return (line.lowercased(), "") }
        let head = String(line[..<space]).lowercased()
        var tail = String(line[line.index(after: space)...])
        if line[space] == " ", tail.hasPrefix(",") { tail.removeFirst() }
        return (head, tail.trimmingCharacters(in: .whitespaces))
    }

    private static func splitArgs(_ tail: String) -> [String] {
        tail.split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func keyCode(for name: String) -> UInt16? {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        let aliases: [String: UInt16] = [
            "space": 49, "enter": 36, "return": 36, "tab": 48,
            "esc": 53, "escape": 53, "backspace": 51, "delete": 51,
            "del": 51, "up": 126, "down": 125, "left": 123, "right": 124,
        ]
        if let code = aliases[n] { return code }
        let upper = n.uppercased()
        for (code, label) in KeyNames.map
        where label == upper || label.lowercased() == n {
            return code
        }
        return nil
    }

    // Word style: cmd+shift+a
    static func hotkey(fromCombo combo: String) -> Hotkey? {
        var mods: NSEvent.ModifierFlags = []
        var keyName: String?
        for token in combo.lowercased()
            .split(separator: "+").map(String.init) {
            switch token.trimmingCharacters(in: .whitespaces) {
            case "cmd", "command", "win", "meta": mods.insert(.command)
            case "ctrl", "control": mods.insert(.control)
            case "alt", "opt", "option": mods.insert(.option)
            case "shift": mods.insert(.shift)
            case let other: keyName = other
            }
        }
        guard let keyName, let code = keyCode(for: keyName) else {
            return nil
        }
        return Hotkey(keyCode: code, modifiers: mods.rawValue)
    }

    // AHK symbol style: ^!a  (^ ctrl, ! alt, + shift, # win→cmd)
    static func hotkey(fromAHKLabel label: String) -> Hotkey? {
        var mods: NSEvent.ModifierFlags = []
        var rest = label.trimmingCharacters(in: .whitespaces)
        loop: while let first = rest.first {
            switch first {
            case "^": mods.insert(.control)
            case "!": mods.insert(.option)
            case "+": mods.insert(.shift)
            case "#": mods.insert(.command)
            default: break loop
            }
            rest.removeFirst()
        }
        if rest.isEmpty { return nil }
        // Also accept word style after symbols, and plain word style.
        if rest.contains("+") {
            guard let hk = hotkey(fromCombo: rest) else { return nil }
            return Hotkey(keyCode: hk.keyCode,
                          modifiers: hk.flags.union(mods).rawValue)
        }
        guard let code = keyCode(for: rest) else { return nil }
        return Hotkey(keyCode: code, modifiers: mods.rawValue)
    }

    static func condition(from text: String) -> Condition? {
        // Keywords compare lowercased, but the payload of the text
        // conditions (app names, window titles) keeps its case.
        var tokens = text
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map(String.init)
        guard !tokens.isEmpty else { return nil }
        var negated = false
        if tokens[0].lowercased() == "not" {
            negated = true
            tokens.removeFirst()
        }
        guard let kind = tokens.first?.lowercased() else { return nil }
        let rest = Array(tokens.dropFirst())
        switch kind {
        case "key":
            guard let name = rest.first,
                  let code = keyCode(for: name) else { return nil }
            return Condition(kind: .keyHeld, negated: negated, keyCode: code)
        case "mouse", "button":
            guard let name = rest.first?.lowercased(),
                  let b = MouseButtonKind(rawValue: name) else { return nil }
            return Condition(kind: .mouseHeld, negated: negated, button: b)
        case "mods", "modifiers":
            guard let combo = rest.first else { return nil }
            var mods: NSEvent.ModifierFlags = []
            for part in combo.lowercased().split(separator: "+") {
                switch part {
                case "cmd", "command": mods.insert(.command)
                case "ctrl", "control": mods.insert(.control)
                case "alt", "opt", "option": mods.insert(.option)
                case "shift": mods.insert(.shift)
                default: return nil
                }
            }
            guard !mods.isEmpty else { return nil }
            return Condition(kind: .modifiersHeld, negated: negated,
                             modifiers: mods.rawValue)
        case "app":
            let name = rest.joined(separator: " ")
            guard !name.isEmpty else { return nil }
            return Condition(kind: .appFrontmost, negated: negated,
                             text: name)
        case "window", "win", "title":
            let fragment = rest.joined(separator: " ")
            guard !fragment.isEmpty else { return nil }
            return Condition(kind: .windowTitled, negated: negated,
                             text: fragment)
        case "clipboard", "clip":
            let fragment = rest.joined(separator: " ")
            guard !fragment.isEmpty else { return nil }
            return Condition(kind: .clipboardContains, negated: negated,
                             text: fragment)
        case "region":
            let numbers = rest.compactMap { Double($0) }
            guard numbers.count >= 4 else { return nil }
            return Condition(kind: .pointerIn, negated: negated,
                             x: numbers[0], y: numbers[1],
                             w: numbers[2], h: numbers[3])
        case "pixel":
            // pixel <x> <y> <#rrggbb> [tolerance%]
            guard rest.count >= 3,
                  let px = Double(rest[0]), let py = Double(rest[1])
            else { return nil }
            let hex = rest[2].replacingOccurrences(of: "#", with: "")
            guard hex.count == 6, let value = UInt32(hex, radix: 16)
            else { return nil }
            let tol = rest.count >= 4 ? (Double(rest[3]) ?? 12) : 12
            return Condition(kind: .pixelColor, negated: negated,
                             x: px, y: py,
                             r: Int((value >> 16) & 0xFF),
                             g: Int((value >> 8) & 0xFF),
                             b: Int(value & 0xFF),
                             tolerance: tol)
        default:
            return nil
        }
    }

    // MARK: export

    // Best-effort script for an existing macro. Manual actions round-trip
    // exactly; raw recorded events aren't expressible as text and export
    // as comments (convert them to editable actions first if you want
    // them in the script).
    static func export(_ macro: Macro) -> String {
        var lines: [String] = ["; \(macro.name)"]
        if let hk = macro.hotkey {
            lines.append(comboText(hk) + "::")
        }
        for item in macro.items {
            if item.delay > 0.0005 {
                lines.append("sleep \(Int((item.delay * 1000).rounded()))")
            }
            switch item.payload {
            case .raw:
                lines.append("; [recorded event, not scriptable: \(item.label)]")
                continue
            case .action(let action):
                lines.append(actionText(action))
            }
            if let r = item.repeats {
                if r.randomized {
                    lines.append("repeat \(r.count), \(trim(r.minInterval)), \(trim(r.maxInterval))")
                } else {
                    lines.append("repeat \(r.count), \(trim(r.minInterval))")
                }
            }
            if let c = item.condition {
                if c.kind == .regionLooksLike || c.kind == .imageOnScreen {
                    lines.append("; [snapshot condition on the step above can't be scripted — re-add it in the editor]")
                } else {
                    lines.append((c.negated ? "onlyifnot " : "onlyif ")
                                 + conditionText(c))
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func actionText(_ action: ManualAction) -> String {
        switch action {
        case .click(let x, let y, let button, let count):
            var s = "click \(Int(x)), \(Int(y))"
            if button != .left || count > 1 { s += ", \(button.rawValue)" }
            if count > 1 { s += ", \(count)" }
            return s
        case .mouseDown(let x, let y, let button):
            var s = "mousedown \(Int(x)), \(Int(y))"
            if button != .left { s += ", \(button.rawValue)" }
            return s
        case .mouseUp(let x, let y, let button):
            var s = "mouseup \(Int(x)), \(Int(y))"
            if button != .left { s += ", \(button.rawValue)" }
            return s
        case .movePointer(let x, let y):
            return "mousemove \(Int(x)), \(Int(y))"
        case .keyPress(let code, let mods):
            return "press " + comboText(Hotkey(keyCode: code,
                                               modifiers: mods))
        case .typeText(let text):
            return "send " + text
                .replacingOccurrences(of: "\n", with: "{Enter}")
                .replacingOccurrences(of: "\t", with: "{Tab}")
        case .scroll(let dx, let dy):
            return "scroll \(dx), \(dy)"
        case .openApp(let name):
            return "run \(name)"
        case .openURL(let url):
            return "run \(url)"
        case .setClipboard(let text):
            return "clipboard " + text
                .replacingOccurrences(of: "\n", with: " ")
        case .pasteClipboard:
            return "paste"
        case .clickImage:
            return "; [click-image step can't be scripted — re-add it in the editor]"
        case .notify(let message):
            return "notify \(message.replacingOccurrences(of: "\n", with: " "))"
        case .beep:
            return "beep"
        case .wait:
            return "; (wait step — its time is the sleep above)"
        case .waitUntil(let condition, let timeout):
            if condition.kind == .regionLooksLike
                || condition.kind == .imageOnScreen {
                return "; [waituntil with a snapshot condition can't be scripted — re-add it in the editor]"
            }
            var s = "waituntil " + (condition.negated ? "not " : "")
                + conditionText(condition)
            if timeout > 0 { s += ", \(trim(timeout))" }
            return s
        case .goTo(let step, let times):
            return times > 0 ? "goto \(step), \(times)" : "goto \(step)"
        case .stopPlayback:
            return "stop"
        }
    }

    private static func conditionText(_ c: Condition) -> String {
        switch c.kind {
        case .keyHeld:
            return "key \(KeyNames.name(for: c.keyCode).lowercased())"
        case .mouseHeld:
            return "mouse \(c.button.rawValue)"
        case .modifiersHeld:
            var parts: [String] = []
            let f = NSEvent.ModifierFlags(rawValue: c.modifiers)
            if f.contains(.command) { parts.append("cmd") }
            if f.contains(.control) { parts.append("ctrl") }
            if f.contains(.option) { parts.append("alt") }
            if f.contains(.shift) { parts.append("shift") }
            return "mods \(parts.joined(separator: "+"))"
        case .pointerIn:
            return "region \(Int(c.x)) \(Int(c.y)) \(Int(c.w)) \(Int(c.h))"
        case .pixelColor:
            return "pixel \(Int(c.x)) \(Int(c.y)) \(c.hexColor) \(trim(c.tolerance))"
        case .appFrontmost:
            return "app \(c.text)"
        case .windowTitled:
            return "window \(c.text)"
        case .clipboardContains:
            return "clipboard \(c.text)"
        case .regionLooksLike, .imageOnScreen:
            return "region-snapshot"  // placeholder; handled by export()
        }
    }

    private static func comboText(_ hk: Hotkey) -> String {
        var parts: [String] = []
        if hk.flags.contains(.control) { parts.append("ctrl") }
        if hk.flags.contains(.option) { parts.append("alt") }
        if hk.flags.contains(.shift) { parts.append("shift") }
        if hk.flags.contains(.command) { parts.append("cmd") }
        parts.append(KeyNames.name(for: hk.keyCode).lowercased())
        return parts.joined(separator: "+")
    }

    private static func trim(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

// MARK: - import sheet

struct ImportScriptSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var name = "Imported Macro"

    private var parsed: ScriptParser.Result { ScriptParser.parse(text) }

    var body: some View {
        VStack(spacing: 12) {
            Text("Import Script")
                .font(.headline)
                .padding(.top, 18)
            Text("Paste a MacAHK script or an AutoHotkey script. Clicks, keys, Send, Sleep, Run, WinWait, hotkey labels and ::hotstrings:: translate; anything unsupported is flagged below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
                .multilineTextAlignment(.center)

            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(width: 520, height: 240)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(.quaternary))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(Self.sample)
                            .font(.body.monospaced())
                            .foregroundStyle(.tertiary)
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Text("\(parsed.items.count) steps")
                    .font(.callout)
                if let hk = parsed.hotkey {
                    Text("hotkey \(hk.display)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !parsed.hotstrings.isEmpty {
                    Text("\(parsed.hotstrings.count) hotstrings")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !parsed.warnings.isEmpty {
                    Text("\(parsed.warnings.count) warnings")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            .frame(width: 520)

            if !parsed.warnings.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(parsed.warnings.indices, id: \.self) { i in
                            Text(parsed.warnings[i])
                                .font(.caption.monospaced())
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 520, height: 70)
            }

            HStack {
                TextField("Macro name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(parsed.items.isEmpty ? "Add Hotstrings"
                                            : "Create Macro") {
                    if !parsed.items.isEmpty {
                        app.createMacro(named: name, items: parsed.items,
                                        hotkey: parsed.hotkey)
                    }
                    app.addHotstrings(parsed.hotstrings)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled((parsed.items.isEmpty
                           && parsed.hotstrings.isEmpty)
                          || (!parsed.items.isEmpty && name
                              .trimmingCharacters(in: .whitespaces).isEmpty))
            }
            .frame(width: 520)
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 24)
    }

    private static let sample = """
    ; example — click loop while F6 is held
    F6::
    run Safari
    winwait Safari, 5
    click 500, 400
    repeat 1000, 0.1, 0.3
    onlyif key f6
    notify done
    ::btw::by the way
    """
}
