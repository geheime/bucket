import AppKit

/// Hand-test aid: Bucket windows exclude themselves from screen sharing/recording (`.none`). With
/// `defaults write studio.bast.bucket recordableWindows -bool YES` (or `BUCKET_RECORDABLE=1`) every window created
/// afterwards is `.readOnly`, so ⌘⇧5 can record the pill. Read at each window creation; off by default.
enum Recordable {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["BUCKET_RECORDABLE"] == "1" || UserDefaults.standard.bool(forKey: "recordableWindows")
    }
    static var sharingType: NSWindow.SharingType { enabled ? .readOnly : .none }
}
