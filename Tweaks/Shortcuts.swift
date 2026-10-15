import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// A key plus modifiers, stored in Carbon form for RegisterEventHotKey.
struct Shortcut: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    /// The key as typed, e.g. "/" or "N".
    let key: String

    static let hyperModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    /// "Hyper /" when all four modifiers are held, else "⌃⌥⌘N" style.
    var label: String {
        if modifiers == Self.hyperModifiers { return "Hyper \(key)" }
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + key
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    /// Readable names for keys whose characters aren't printable.
    static func keyName(keyCode: UInt16, characters: String?) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            if let characters, let first = characters.first, !first.isWhitespace { return String(first).uppercased() }
            return "Key \(keyCode)"
        }
    }
}

/// Actions that can have a global shortcut.
enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case keepAwake
    case keepAwakePanel
    case screenOff
    case clearNotifications
    case saveWindowLayout
    case restoreWindowLayout
    case safeEject

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepAwake: "Keep Awake (tap 12 h, hold for options)"
        case .keepAwakePanel: "Open the Keep Awake panel"
        case .screenOff: "Screen off, Mac awake"
        case .clearNotifications: "Clear all notifications"
        case .saveWindowLayout: "Save this display setup's windows"
        case .restoreWindowLayout: "Restore this display setup's windows"
        case .safeEject: "Eject idle external drives"
        }
    }

    var defaultShortcut: Shortcut? {
        switch self {
        case .keepAwake: Shortcut(keyCode: UInt32(kVK_ANSI_Slash), modifiers: Shortcut.hyperModifiers, key: "/")
        case .clearNotifications: Shortcut(keyCode: UInt32(kVK_ANSI_N), modifiers: Shortcut.hyperModifiers, key: "N")
        case .keepAwakePanel, .screenOff, .saveWindowLayout, .restoreWindowLayout, .safeEject: nil
        }
    }
}

/// Saved shortcuts, with defaults for the ones that ship with one.
@MainActor
@Observable
final class ShortcutStore {
    private(set) var shortcuts: [ShortcutAction: Shortcut] = [:]
    var onChange: ((ShortcutAction) -> Void)?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for action in ShortcutAction.allCases {
            if let data = defaults.data(forKey: Self.key(action)) {
                // An empty record means "no shortcut", chosen on purpose.
                shortcuts[action] = try? JSONDecoder().decode(Shortcut.self, from: data)
            } else {
                shortcuts[action] = action.defaultShortcut
            }
        }
    }

    func shortcut(for action: ShortcutAction) -> Shortcut? { shortcuts[action] }

    /// Sets a shortcut, taking it away from any other action that had the same keys.
    func set(_ shortcut: Shortcut?, for action: ShortcutAction) {
        if let shortcut {
            for (other, existing) in shortcuts where other != action && existing == shortcut {
                shortcuts[other] = nil
                save(other)
                onChange?(other)
            }
        }
        shortcuts[action] = shortcut
        save(action)
        onChange?(action)
    }

    func resetToDefault(_ action: ShortcutAction) {
        set(action.defaultShortcut, for: action)
    }

    private func save(_ action: ShortcutAction) {
        let data = shortcuts[action].flatMap { try? JSONEncoder().encode($0) } ?? Data()
        defaults.set(data, forKey: Self.key(action))
    }

    private static func key(_ action: ShortcutAction) -> String { "shortcut.\(action.rawValue)" }
}

/// Click, then press the new keys. Esc cancels, ⌫ clears. Needs at least one of ⌘⌃⌥
/// so a plain letter can't be stolen from every app.
struct ShortcutRecorder: View {
    let shortcut: Shortcut?
    let onChange: (Shortcut?) -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                Text(recording ? (hint ?? "Type shortcut…") : (shortcut?.label ?? "Record"))
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            if shortcut != nil, !recording {
                Button { onChange(nil) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove shortcut")
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        recording = true
        hint = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = Int(event.keyCode)
            if code == kVK_Escape { stopRecording(); return nil }
            if code == kVK_Delete || code == kVK_ForwardDelete { onChange(nil); stopRecording(); return nil }
            let modifiers = Shortcut.carbonModifiers(from: event.modifierFlags)
            guard modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 else {
                hint = "Add ⌘, ⌃ or ⌥"
                return nil
            }
            onChange(Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers,
                              key: Shortcut.keyName(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)))
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        hint = nil
    }
}
