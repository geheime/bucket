import Foundation

/// What the frontmost app is, as far as pasting goes.
public enum FrontAppKind: Equatable {
    case terminal, browser, app
    /// System UI (and Bucket's own panel): activating it never changes what is on the clipboard.
    case ignore
}

/// How the clipboard is laid out for the app that is about to receive the paste.
public enum PasteMode: Equatable, CaseIterable {
    /// One item, plain text: the shell-quoted paths in the chosen paste format.
    case terminal
    /// One item per screenshot offering PNG data only.
    case browser
    /// One item per screenshot offering a file URL and PNG data.
    case app
}

public enum PasteTarget {
    public static let terminals: Set<String> = [
        "com.googlecode.iterm2", "com.apple.Terminal", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "com.github.wez.wezterm", "org.alacritty", "net.kovidgoyal.kitty", "co.zeit.hyper",
        // Code editors with an integrated terminal: text paths are the safe default (not tested individually).
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
    ]

    /// Only Safari was tested by hand; the others are assumed to behave the same way.
    public static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.brave.Browser", "com.microsoft.edgemac", "com.operasoftware.Opera",
    ]

    public static let ignored: Set<String> = [
        "com.apple.loginwindow", "com.apple.screencaptureui", "com.apple.dock", "com.apple.controlcenter",
        "com.apple.Spotlight", "studio.bast.bucket",
    ]

    public static func classify(bundleID: String?) -> FrontAppKind {
        guard let id = bundleID else { return .app }
        if ignored.contains(id) { return .ignore }
        if terminals.contains(id) { return .terminal }
        if browsers.contains(id) { return .browser }
        return .app
    }

    /// The paste mode for an app kind; nil for system UI, which must not trigger a re-stage.
    public static func mode(for kind: FrontAppKind) -> PasteMode? {
        switch kind {
        case .terminal: return .terminal
        case .browser: return .browser
        case .app: return .app
        case .ignore: return nil
        }
    }
}
