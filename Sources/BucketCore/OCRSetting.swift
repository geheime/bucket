import Foundation

/// The "Read text in screenshots" switch. On unless the user turned it off, so an upgrade changes nothing.
/// The app (menu) and the CLI (`search`, `ocr --backfill`) read the same key.
public enum OCRSetting {
    public static let key = "ocrEnabled"

    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    public static func set(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: key)
    }

    public static var enabled: Bool {
        get { isEnabled() }
        set { set(newValue) }
    }

    /// What the CLI says on stderr when the switch is off.
    public static let searchNotice = "OCR is off: new screenshots are not searchable"
    public static let backfillNotice = "OCR is off: nothing was read (turn on \"Read text in screenshots\" in the menu)"
}
