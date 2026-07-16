import Foundation
import AppKit
import CoreGraphics

// Low-level input synthesis shared by macro playback and hotstring
// expansion, plus the app-launching and notification helpers behind the
// Open App / Notify actions.

enum Synth {
    // Press and release a key with optional modifier flags.
    static func tapKey(_ code: CGKeyCode, flags: CGEventFlags = [],
                       source: CGEventSource?) {
        if let down = CGEvent(keyboardEventSource: source,
                              virtualKey: code, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.02)
        if let up = CGEvent(keyboardEventSource: source,
                            virtualKey: code, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    // Type arbitrary text via the unicode-string keyboard event. The API
    // takes short runs reliably, so it's chunked.
    static func typeText(_ text: String, source: CGEventSource?) {
        let chars = Array(text.utf16)
        var start = 0
        while start < chars.count {
            let run = Array(chars[start..<min(start + 20, chars.count)])
            if let down = CGEvent(keyboardEventSource: source,
                                  virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: run.count,
                                              unicodeString: run)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source,
                                virtualKey: 0, keyDown: false) {
                up.post(tap: .cghidEventTap)
            }
            start += 20
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}

enum AppLauncher {
    // Open (or, when already running, just activate) an app named by its
    // display name ("Safari"), bundle id ("com.apple.Safari"), or path.
    static func openApp(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        if let running = NSWorkspace.shared.runningApplications.first(
            where: {
                $0.localizedName?.caseInsensitiveCompare(trimmed)
                    == .orderedSame
                || $0.bundleIdentifier?.caseInsensitiveCompare(trimmed)
                    == .orderedSame
            }) {
            running.activate(options: [.activateIgnoringOtherApps])
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let url = appURL(for: trimmed) {
            NSWorkspace.shared.openApplication(at: url,
                                               configuration: config)
        }
    }

    private static func appURL(for name: String) -> URL? {
        if name.hasPrefix("/") || name.hasPrefix("~") {
            return URL(fileURLWithPath: (name as NSString)
                .expandingTildeInPath)
        }
        if name.contains("."),
           let url = NSWorkspace.shared.urlForApplication(
               withBundleIdentifier: name) {
            return url
        }
        let base = name.hasSuffix(".app") ? name : name + ".app"
        let candidates = [
            "/Applications/\(base)",
            "/System/Applications/\(base)",
            "/System/Applications/Utilities/\(base)",
            NSHomeDirectory() + "/Applications/\(base)",
        ]
        for path in candidates
        where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

enum Notifier {
    // Post a notification banner. NSUserNotification is deprecated but
    // still delivers, and unlike UserNotifications it needs no
    // authorization round-trip — right for a fire-and-forget checkpoint.
    // Outside an app bundle (swift run) delivery isn't possible; beep
    // instead so the step still signals something.
    static func show(_ message: String) {
        guard Bundle.main.bundleIdentifier != nil else {
            NSSound.beep()
            return
        }
        let note = NSUserNotification()
        note.title = "MacAHK"
        note.informativeText = message
        NSUserNotificationCenter.default.deliver(note)
    }
}
