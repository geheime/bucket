import AppKit
import BucketCore

/// Offscreen UI renderer: draws a named state to a 2x PNG with no window and no Screen Recording.
/// Each UI slice registers its own states in `states`.
enum Render {
    static let scale = 2

    static let states: [String: () -> NSView] = PanelRender.states // panel-*

    /// States drawn straight to PNG by Core (they need no view tree): the menu bar glyph canvas.
    static let canvases: [String: (Bool) -> Data?] = [
        "menubar-0": { MenubarCanvas.png(.empty, dark: $0) },
        "menubar-1": { MenubarCanvas.png(.one, dark: $0) },
        "menubar-2": { MenubarCanvas.png(.two, dark: $0) },
        "menubar-3": { MenubarCanvas.png(.three, dark: $0) },
        "menubar-full": { MenubarCanvas.png(.full, dark: $0) },
        "menubar-error": { MenubarCanvas.png(.slash, dark: $0) }, // no Screen Recording permission
    ].merging(PillRender.states) { a, _ in a } // pill-* and keycaps-* (companion layer tree)

    static func run(state: String, out: URL, dark: Bool) -> Int32 {
        _ = NSApplication.shared // AppKit needs an app object to draw, even without windows
        if let canvas = canvases[state] {
            guard let png = canvas(dark) else { Cli.fail("png encoding failed") }
            return write(png, to: out)
        }
        guard let make = states[state] else {
            Cli.fail("unknown state '\(state)' (\((Array(states.keys) + Array(canvases.keys)).sorted().joined(separator: ", ")))")
        }
        let view = make()
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.layoutSubtreeIfNeeded()

        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { Cli.fail("cannot allocate bitmap") }
        rep.size = size // points; the extra pixels make it 2x
        view.cacheDisplay(in: view.bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else { Cli.fail("png encoding failed") }
        return write(png, to: out)
    }

    private static func write(_ png: Data, to out: URL) -> Int32 {
        do {
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: out)
        } catch { Cli.fail("write failed: \(error.localizedDescription)") }
        print(out.path)
        return 0
    }
}
