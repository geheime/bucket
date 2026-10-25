import AppKit
import BucketCore
import Carbon

/// A capture shortcut the user can pick. A free-form recorder belongs in Settings (phase 4).
struct Shortcut: Equatable {
    let id: String
    let title: String
    let keyCode: Int
    let modifiers: Int
    let menuKey: String
    let menuMask: NSEvent.ModifierFlags

    static let presets: [Shortcut] = [
        Shortcut(id: "cmdShift4", title: "⌘⇧4  (replaces the macOS area screenshot)", keyCode: kVK_ANSI_4,
                 modifiers: cmdKey | shiftKey, menuKey: "4", menuMask: [.command, .shift]),
        Shortcut(id: "cmdShift2", title: "⌘⇧2", keyCode: kVK_ANSI_2,
                 modifiers: cmdKey | shiftKey, menuKey: "2", menuMask: [.command, .shift]),
        Shortcut(id: "optShift2", title: "⌥⇧2", keyCode: kVK_ANSI_2,
                 modifiers: optionKey | shiftKey, menuKey: "2", menuMask: [.option, .shift]),
    ]

    /// Keycap symbols: modifiers in ⌥ ⌘ ⇧ order, then the key.
    var symbols: [String] {
        (menuMask.contains(.option) ? ["⌥"] : []) + (menuMask.contains(.command) ? ["⌘"] : [])
            + (menuMask.contains(.shift) ? ["⇧"] : []) + [menuKey.uppercased()]
    }

    static var capture: Shortcut {
        get { presets.first { $0.id == UserDefaults.standard.string(forKey: "captureShortcut") } ?? presets[0] }
        set { UserDefaults.standard.set(newValue.id, forKey: "captureShortcut") }
    }
}
