import Foundation

/// Read-only look at the macOS keyboard shortcut settings. Bucket never writes them.
public enum NativeShortcuts {
    /// Symbolic hotkey 31 is "Save picture of selected area as a file", the native Cmd+Shift+4.
    static let selectedAreaKey = "31"

    /// Whether the native area screenshot shortcut is enabled, given the `AppleSymbolicHotKeys` dictionary.
    /// nil when it cannot be told (no dictionary, no entry 31, or an unexpected shape): the caller then does nothing.
    public static func selectedAreaEnabled(in symbolicHotKeys: Any?) -> Bool? {
        guard let all = symbolicHotKeys as? [String: Any],
              let entry = all[selectedAreaKey] as? [String: Any],
              let enabled = entry["enabled"] else { return nil }
        if let b = enabled as? Bool { return b }
        if let n = enabled as? NSNumber { return n.boolValue }
        return nil
    }

    /// Reads `com.apple.symbolichotkeys` through CFPreferences (read only).
    public static func nativeAreaScreenshotEnabled() -> Bool? {
        let value = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString)
        return selectedAreaEnabled(in: value)
    }
}
