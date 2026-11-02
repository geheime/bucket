import Foundation

/// Read-only look at the macOS keyboard shortcut settings. Bucket never writes them.
public enum NativeShortcuts {
    /// Symbolic hotkey 30 is "Save picture of selected area as a file", the native Cmd+Shift+4 (measured on macOS 26: turning it
    /// off in Settings writes entry 30; entry 31 was already there, disabled, with the same key). While the user never touched it,
    /// entry 30 does not exist and the shortcut is on by default.
    static let selectedAreaKey = "30"
    /// The key code of "4" and the Cmd+Shift modifier mask, as stored in an entry's `value.parameters` (ascii, key code, modifiers).
    static let areaKeyCode = 21
    static let areaModifiers = 1_179_648

    /// Whether the native Cmd+Shift+4 is on, given the `AppleSymbolicHotKeys` dictionary.
    /// - Any enabled entry bound to Cmd+Shift+4 means on, whatever its number.
    /// - Otherwise entry 30 decides: absent = on (the default), present = its `enabled` flag.
    /// nil when it cannot be told (not a dictionary, or entry 30 in an unexpected shape): the caller then does nothing.
    public static func selectedAreaEnabled(in symbolicHotKeys: Any?) -> Bool? {
        guard let all = symbolicHotKeys as? [String: Any] else { return nil }
        for case let entry as [String: Any] in all.values where flag(entry["enabled"]) == true && isCmdShift4(entry) { return true }
        guard let raw = all[selectedAreaKey] else { return true }
        guard let entry = raw as? [String: Any] else { return nil }
        return flag(entry["enabled"])
    }

    private static func flag(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return nil
    }

    private static func isCmdShift4(_ entry: [String: Any]) -> Bool {
        guard let value = entry["value"] as? [String: Any], let p = value["parameters"] as? [Any], p.count >= 3,
              let key = p[1] as? NSNumber, let mods = p[2] as? NSNumber else { return false }
        return key.intValue == areaKeyCode && mods.intValue == areaModifiers
    }

    /// Reads `com.apple.symbolichotkeys` through CFPreferences (read only).
    /// No `AppleSymbolicHotKeys` at all means the user never changed a system shortcut: every default is on, Cmd+Shift+4 too.
    public static func nativeAreaScreenshotEnabled() -> Bool? {
        let value = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString)
        return selectedAreaEnabled(in: value ?? [String: Any]() as CFPropertyList)
    }
}
