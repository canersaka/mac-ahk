import Foundation
import AppKit
import SwiftUI

// Hotstrings: system-wide text expansion, AHK's `::btw::by the way`.
// A listen-only key monitor keeps a small buffer of what you type; when
// it ends with a trigger, the trigger is erased with backspaces and the
// replacement typed in its place. Expansion fires the moment the trigger
// is completed (AHK's `*` option) — no end character needed.

struct Hotstring: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var trigger: String = ""
    var replacement: String = ""
    var enabled: Bool = true
}

// Persists hotstrings as one JSON file next to the macros.
@MainActor
final class HotstringStore: ObservableObject {
    @Published var hotstrings: [Hotstring] = [] {
        didSet {
            guard !loading else { return }
            persist()
            onChange?()
        }
    }
    var onChange: (() -> Void)?

    private let url: URL
    private var loading = false

    init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MacAHK", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("hotstrings.json")
        loading = true
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([Hotstring].self,
                                                from: data) {
            hotstrings = list
        }
        loading = false
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let data = try? enc.encode(hotstrings) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// The expansion engine. NSEvent monitors are listen-only (they can't
// swallow keystrokes), so the typed trigger is removed with synthetic
// backspaces — the same approach most expanders use. Needs the
// permissions the app already holds: Input Monitoring to see keys,
// Accessibility to post the replacement.
@MainActor
final class HotstringCenter {
    // Set while recording or playing — expansions during either would
    // corrupt the recording or fight the macro.
    var suspended = false
    // Set while a sheet is teaching a key combo.
    var captureSuspended = false

    private var active: [Hotstring] = []
    private var buffer = ""
    private var expanding = false
    private var monitors: [Any] = []

    func rebuild(from list: [Hotstring], masterEnabled: Bool) {
        active = list.filter { $0.enabled && !$0.trigger.isEmpty }
        let needed = masterEnabled && !active.isEmpty
        if needed {
            guard monitors.isEmpty else { return }
            if let m = NSEvent.addGlobalMonitorForEvents(
                matching: .keyDown, handler: { [weak self] e in
                    self?.handleKey(e)
                }) {
                monitors.append(m)
            }
            if let m = NSEvent.addLocalMonitorForEvents(
                matching: .keyDown, handler: { [weak self] e in
                    self?.handleKey(e)
                    return e
                }) {
                monitors.append(m)
            }
            // A click means the caret probably moved: what was typed
            // before it is no longer "just before the cursor".
            if let m = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown],
                handler: { [weak self] _ in
                    self?.buffer = ""
                }) {
                monitors.append(m)
            }
        } else {
            shutdown()
        }
    }

    func shutdown() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        buffer = ""
    }

    private func handleKey(_ e: NSEvent) {
        guard !suspended, !captureSuspended, !expanding else { return }
        // Shortcuts aren't typing.
        if !e.modifierFlags.intersection([.command, .control]).isEmpty {
            buffer = ""
            return
        }
        if e.keyCode == 51 {  // ⌫ takes back the last character
            if !buffer.isEmpty { buffer.removeLast() }
            return
        }
        guard let chars = e.characters, !chars.isEmpty else { return }
        // Arrows, function keys etc. arrive as F700-region code points —
        // the caret moved, so start over.
        if chars.unicodeScalars.contains(
            where: { $0.value >= 0xF700 && $0.value <= 0xF8FF }) {
            buffer = ""
            return
        }
        buffer += chars
        if buffer.count > 64 {
            buffer.removeFirst(buffer.count - 64)
        }
        let lower = buffer.lowercased()
        for h in active
        where lower.hasSuffix(h.trigger.lowercased()) {
            expand(h)
            break
        }
    }

    private func expand(_ h: Hotstring) {
        expanding = true
        buffer = ""
        let eraseCount = h.trigger.count
        let replacement = h.replacement
        DispatchQueue.global(qos: .userInteractive).async {
            let src = CGEventSource(stateID: .combinedSessionState)
            for _ in 0..<eraseCount {
                Synth.tapKey(51, source: src)  // ⌫
            }
            Thread.sleep(forTimeInterval: 0.03)
            Synth.typeText(replacement, source: src)
            // Our own synthetic keystrokes echo back through the
            // monitors; keep ignoring input until they have flushed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                [weak self] in
                self?.expanding = false
            }
        }
    }
}

// MARK: - management sheet

struct HotstringsSheet: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var store: HotstringStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("Hotstrings")
                .font(.headline)
                .padding(.top, 18)
            Text("Type a trigger anywhere on your Mac and it's instantly replaced by its expansion — like AutoHotkey's ::btw::by the way. Paused while recording or playing a macro.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
                .multilineTextAlignment(.center)

            Toggle("Enable text expansion", isOn: $app.hotstringsEnabled)
                .toggleStyle(.switch)

            if !Permissions.accessibility {
                Text("Expansion needs the Accessibility permission (to type the replacement).")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            List {
                ForEach($store.hotstrings) { $h in
                    HStack(spacing: 8) {
                        TextField("trigger", text: $h.trigger)
                            .font(.body.monospaced())
                            .frame(width: 120)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.tertiary)
                        TextField("expansion", text: $h.replacement)
                        Toggle("", isOn: $h.enabled)
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .help("Enable this hotstring")
                        Button {
                            store.hotstrings.removeAll { $0.id == h.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete this hotstring")
                    }
                }
                if store.hotstrings.isEmpty {
                    Text("No hotstrings yet — add one below, or import an AHK script containing ::trigger::replacement lines.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 520, height: 220)

            HStack {
                Button {
                    store.hotstrings.append(Hotstring())
                } label: {
                    Label("Add Hotstring", systemImage: "plus")
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .frame(width: 520)
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 24)
    }
}
