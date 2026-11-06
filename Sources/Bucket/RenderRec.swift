import AppKit
import BucketCore
import QuartzCore

/// Offscreen renders of the recording states: `rec-pill`, `rec-pill-countdown`, `rec-reading` (the live layer tree with the
/// opaque material) and `rec-region` (the picker's canvas over a mock screen).
enum RecRender {
    static let states: [String: (Bool) -> Data?] = [
        "rec-pill": { pill(.recording, text: "0:12", dark: $0) },
        "rec-pill-countdown": { pill(.recording, text: RecordingClock.display(elapsed: 111, limit: 120).text, dark: $0) },
        "rec-reading": { pill(.reading, text: RecordingClock.reading(14), dark: $0) },
    ]

    static let views: [String: () -> NSView] = [
        "rec-region": { RegionMock(dragged: false) },       // before dragging: a click takes the whole screen
        "rec-region-drag": { RegionMock(dragged: true) },   // dragging: the selection and its measures
    ]

    static func pill(_ kind: RecPillLayers.Kind, text: String, dark: Bool) -> Data? {
        let palette = PillPalette(dark: dark)
        let built = RecPillLayers(kind: kind, text: text, palette: palette, opaque: true)
        let root = CALayer()
        root.bounds = CGRect(origin: .zero, size: built.size)
        root.anchorPoint = .zero
        root.backgroundColor = palette.canvas
        root.masksToBounds = true
        built.root.position = .zero
        root.addSublayer(built.root)
        return PillRender.rasterize(root, size: built.size)
    }
}

/// A mock screen with a window and the picker drawn over it, for `rec-region`.
private final class RegionMock: NSView {
    private let canvas = RegionCanvas()
    init(dragged: Bool) {
        super.init(frame: CGRect(x: 0, y: 0, width: 440, height: 280))
        canvas.frame = bounds
        if dragged { canvas.selection = CGRect(x: 70, y: 70, width: 260, height: 140) } else { canvas.cursor = CGPoint(x: 150, y: 150) }
        addSubview(canvas)
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSColor(cgColor: PillPalette(dark: dark).canvas)?.setFill()
        bounds.fill()
        PanelColor.material.setFill()
        NSBezierPath(roundedRect: CGRect(x: 30, y: 50, width: 340, height: 190), xRadius: 9, yRadius: 9).fill()
        NSColor.secondaryLabelColor.setFill()
        for i in 0 ..< 5 { CGRect(x: 52, y: 200 - CGFloat(i) * 22, width: CGFloat(150 + (i * 37) % 120), height: 7).fill() }
    }
}
