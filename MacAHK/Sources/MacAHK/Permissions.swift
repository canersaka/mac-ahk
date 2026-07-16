import Foundation
import AppKit
import ApplicationServices

// The two macOS grants this app needs, and nothing more:
//   Input Monitoring — to record input (the event tap)
//   Accessibility    — to post synthetic input during playback
// No screen recording, no full disk access, no kernel extensions.
enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }

    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }

    static var allGranted: Bool { accessibility && inputMonitoring }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue()
                    as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    static func requestInputMonitoring() {
        CGRequestListenEventAccess()
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private static func open(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
