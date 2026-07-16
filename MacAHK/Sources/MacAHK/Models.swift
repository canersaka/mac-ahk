import Foundation
import AppKit

// One captured input event: a serialized raw CGEvent plus the moment it
// happened, in seconds since the start of the recording. Keeping the raw
// bytes means keys, clicks, drags, scrolls (with momentum phases) and
// trackpad gestures all round-trip with full fidelity.
struct RecordedEvent: Codable {
    var t: Double
    var type: UInt32
    var data: Data
}

struct Hotkey: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt  // NSEvent.ModifierFlags rawValue, device-independent

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + KeyNames.name(for: keyCode)
    }
}

struct Macro: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var created: Date = Date()
    var hotkey: Hotkey?
    var events: [RecordedEvent]

    static func == (a: Macro, b: Macro) -> Bool { a.id == b.id }

    var duration: Double { events.last?.t ?? 0 }

    // Small human summary for the UI: "12 clicks, 340 keys, 3 gestures".
    var summary: String {
        var clicks = 0, keys = 0, scrolls = 0, gestures = 0, moves = 0
        for e in events {
            switch e.type {
            case 1, 2, 3, 4, 25, 26: clicks += 1
            case 10, 11, 12: keys += 1
            case 22: scrolls += 1
            case 5, 6, 7, 27: moves += 1
            case 18, 19, 20, 29, 30, 31, 32, 34: gestures += 1
            default: break
            }
        }
        var parts: [String] = []
        if clicks > 0 { parts.append("\(clicks) click ev") }
        if keys > 0 { parts.append("\(keys) key ev") }
        if scrolls > 0 { parts.append("\(scrolls) scroll ev") }
        if gestures > 0 { parts.append("\(gestures) gesture ev") }
        if moves > 0 { parts.append("\(moves) move ev") }
        if parts.isEmpty { parts.append("\(events.count) events") }
        return parts.joined(separator: ", ") + String(format: "  ·  %.1fs", duration)
    }
}

// Persists macros as individual JSON files in Application Support, so
// they survive updates and can be backed up or synced like any document.
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
        macros = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func upsert(_ macro: Macro) {
        if let i = macros.firstIndex(where: { $0.id == macro.id }) {
            macros[i] = macro
        } else {
            macros.append(macro)
            macros.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
        50: "`", 51: "⌫", 53: "⎋", 96: "F5", 97: "F6", 98: "F7",
        99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10",
        111: "F12", 118: "F4", 120: "F2", 122: "F1", 123: "←",
        124: "→", 125: "↓", 126: "↑",
    ]

    static func name(for code: UInt16) -> String {
        map[code] ?? "key \(code)"
    }
}
