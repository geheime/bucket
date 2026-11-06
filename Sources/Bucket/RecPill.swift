import AppKit
import BucketCore
import QuartzCore

extension PillPalette {
    /// text.secondary
    var secondary: CGColor { PillPalette.resolve(.secondaryLabelColor, dark: dark) }
    /// fill.control
    var control: CGColor { PillPalette.resolve(.quaternarySystemFill, dark: dark) }
}

/// The recording pill (states B / B′ of the mock) and the "Reading 0:14…" pill (C): a Core Animation tree, drawn live in a
/// window and, with the opaque material, offscreen by `Bucket render`, like the other pills.
/// Layout, y down, inside a canvas with `pad` of room around the capsule for its shadow.
final class RecPillLayers {
    enum Kind { case recording, reading }

    static let pad: CGFloat = 24
    static let height = CompanionPlacement.expandedHeight // 38, radius 19
    static let button: CGFloat = 28
    static let dot: CGFloat = 9

    let root = CALayer()
    let size: CGSize
    /// The capsule, in `root` coordinates.
    let pill: CGRect
    /// Click targets, in `root` coordinates (empty for the reading pill).
    private(set) var stop = CGRect.zero, cancel = CGRect.zero
    let dot = CALayer()
    let time = CATextLayer()
    let spinner = CAShapeLayer()
    private let palette: PillPalette

    /// The widest the clock can be ("10:00", "-0:09"), so the capsule never changes size while the time runs.
    static func clockWidth() -> CGFloat { PillFont.width("00:00", PillFont.compact) + 2 }
    static let keycapFont = NSFont.systemFont(ofSize: 10, weight: .semibold)

    init(kind: Kind, text: String, palette: PillPalette, opaque: Bool) {
        self.palette = palette
        let h = RecPillLayers.height, pad = RecPillLayers.pad
        let keycap = "⌘⇧6"
        let kw = ceil(PillFont.width(keycap, RecPillLayers.keycapFont)) + 10
        let tw = kind == .recording ? RecPillLayers.clockWidth() : PillFont.width(text, PillFont.pill) + 2
        let b = RecPillLayers.button, d = RecPillLayers.dot
        let w: CGFloat = kind == .recording
            ? 14 + d + 8 + tw + 8 + kw + 8 + b + 8 + b + 5
            : 14 + 14 + 8 + tw + 14
        size = CGSize(width: w + 2 * pad, height: h + 2 * pad)
        pill = CGRect(x: pad, y: pad, width: w, height: h)

        root.bounds = CGRect(origin: .zero, size: size)
        root.anchorPoint = .zero
        root.isGeometryFlipped = true

        let shape = CGPath(roundedRect: pill, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)
        let shadow = CALayer()
        shadow.bounds = root.bounds; shadow.anchorPoint = .zero
        shadow.shadowColor = PillPalette.shadow; shadow.shadowOpacity = 0.16; shadow.shadowRadius = 7
        shadow.shadowOffset = CGSize(width: 0, height: 4); shadow.shadowPath = shape
        let hole = CAShapeLayer()
        let hp = CGMutablePath(); hp.addRect(root.bounds.insetBy(dx: -64, dy: -64)); hp.addPath(shape)
        hole.path = hp; hole.fillRule = .evenOdd
        shadow.mask = hole
        root.addSublayer(shadow)
        if opaque {
            let fill = CALayer()
            fill.bounds = root.bounds; fill.anchorPoint = .zero
            fill.backgroundColor = palette.material
            let m = CAShapeLayer(); m.path = shape; fill.mask = m
            root.addSublayer(fill)
        }
        let edge = CAShapeLayer()
        edge.path = CGPath(roundedRect: pill.insetBy(dx: 0.25, dy: 0.25), cornerWidth: h / 2 - 0.25, cornerHeight: h / 2 - 0.25, transform: nil)
        edge.fillColor = nil; edge.strokeColor = palette.edge; edge.lineWidth = 0.5
        root.addSublayer(edge)

        func label(_ layer: CATextLayer, _ s: String, _ f: NSFont, _ color: CGColor, x: CGFloat, w: CGFloat) {
            layer.contentsScale = 2; layer.font = f; layer.fontSize = f.pointSize; layer.string = s; layer.foregroundColor = color
            layer.alignmentMode = .left
            layer.frame = CGRect(x: x, y: pill.midY - 8, width: w, height: 16)
            root.addSublayer(layer)
        }

        guard kind == .recording else {
            // spinner · "Reading 0:14…"
            let s: CGFloat = 14
            let c = CGPoint(x: pill.minX + 14 + s / 2, y: pill.midY)
            let track = CAShapeLayer()
            track.path = CGPath(ellipseIn: CGRect(x: c.x - s / 2 + 1, y: c.y - s / 2 + 1, width: s - 2, height: s - 2), transform: nil)
            track.fillColor = nil; track.strokeColor = palette.control; track.lineWidth = 2
            root.addSublayer(track)
            spinner.bounds = CGRect(x: 0, y: 0, width: s, height: s)
            spinner.position = c
            spinner.path = CGPath(ellipseIn: CGRect(x: 1, y: 1, width: s - 2, height: s - 2), transform: nil)
            spinner.fillColor = nil; spinner.strokeColor = palette.secondary; spinner.lineWidth = 2
            spinner.strokeStart = 0; spinner.strokeEnd = 0.25
            root.addSublayer(spinner)
            label(time, text, PillFont.pill, palette.ink, x: pill.minX + 14 + s + 8, w: tw)
            return
        }

        // dot · m:ss · ⌘⇧6 · stop · ✕
        var x = pill.minX + 14
        dot.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        dot.cornerRadius = d / 2
        dot.backgroundColor = palette.accent
        dot.position = CGPoint(x: x + d / 2, y: pill.midY)
        root.addSublayer(dot)
        x += d + 8
        label(time, text, PillFont.compact, palette.ink, x: x, w: tw)
        x += tw + 8

        let cap = CALayer()
        cap.frame = CGRect(x: x, y: pill.midY - 9, width: kw, height: 18)
        cap.cornerRadius = 5
        cap.backgroundColor = palette.control
        root.addSublayer(cap)
        let kt = CATextLayer()
        kt.contentsScale = 2; kt.font = RecPillLayers.keycapFont; kt.fontSize = 10; kt.string = keycap; kt.foregroundColor = palette.secondary
        kt.alignmentMode = .center
        kt.frame = CGRect(x: x, y: pill.midY - 6, width: kw, height: 13)
        root.addSublayer(kt)
        x += kw + 8

        stop = CGRect(x: x, y: pill.midY - b / 2, width: b, height: b)
        let circle = CALayer()
        circle.frame = stop; circle.cornerRadius = b / 2; circle.backgroundColor = palette.control
        root.addSublayer(circle)
        let square = CALayer()
        square.bounds = CGRect(x: 0, y: 0, width: 9, height: 9); square.cornerRadius = 2
        square.backgroundColor = palette.ink
        square.position = CGPoint(x: stop.midX, y: stop.midY)
        root.addSublayer(square)
        x += b + 8

        cancel = CGRect(x: x, y: pill.midY - b / 2, width: b, height: b)
        let cross = CAShapeLayer()
        let p = CGMutablePath(), r: CGFloat = 4
        p.move(to: CGPoint(x: cancel.midX - r, y: cancel.midY - r)); p.addLine(to: CGPoint(x: cancel.midX + r, y: cancel.midY + r))
        p.move(to: CGPoint(x: cancel.midX + r, y: cancel.midY - r)); p.addLine(to: CGPoint(x: cancel.midX - r, y: cancel.midY + r))
        cross.path = p; cross.strokeColor = palette.secondary; cross.lineWidth = 1.5; cross.lineCap = .round; cross.fillColor = nil
        root.addSublayer(cross)
    }

    func setTime(_ s: String) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        time.string = s
        CATransaction.commit()
    }

    /// The dot breathes; with Reduce Motion it stays still.
    func startMotion(reduceMotion: Bool) {
        if kindHasDot, !reduceMotion {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1; a.toValue = 0.35; a.duration = 0.7; a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(a, forKey: "pulse")
        }
        if spinner.superlayer != nil {
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0; a.toValue = -2 * Double.pi; a.duration = 0.8; a.repeatCount = .infinity
            spinner.add(a, forKey: "spin")
        }
    }
    private var kindHasDot: Bool { dot.superlayer != nil }
}

/// The live window of either pill. Nonactivating and clickable: the stop and the ✕ work without taking focus from the app
/// being recorded. `sharingType = .none` (BucketPanel), so it is not in the video.
final class RecPillPanel {
    private var panel: BucketPanel?
    private var layers: RecPillLayers?
    var onStop: () -> Void = {}
    var onCancel: () -> Void = {}

    var isShown: Bool { panel?.isVisible == true }
    var frame: CGRect? { panel?.frame }

    private static var dark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    /// `capsule` is where the capsule goes on screen (AppKit, y up): the window is that plus the shadow room.
    func show(kind: RecPillLayers.Kind, text: String, capsule: (CGSize) -> CGRect) {
        close()
        let dark = RecPillPanel.dark
        let built = RecPillLayers(kind: kind, text: text, palette: PillPalette(dark: dark), opaque: true)
        let panel = BucketPanel(size: built.size, ignoresMouse: kind == .reading)
        panel.level = RegionBorder.pillLevel // above the scrim and the frame, always
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let view = RecPillView(frame: CGRect(origin: .zero, size: built.size))
        view.wantsLayer = true
        view.layer?.addSublayer(built.root)
        built.root.position = .zero
        view.stop = built.stop; view.cancel = built.cancel
        view.onStop = { [weak self] in self?.onStop() }
        view.onCancel = { [weak self] in self?.onCancel() }
        panel.contentView = view
        let c = capsule(built.pill.size)
        let pad = RecPillLayers.pad
        panel.setFrame(CGRect(x: c.minX - pad, y: c.minY - pad, width: built.size.width, height: built.size.height), display: false)
        panel.orderFrontRegardless()
        built.startMotion(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        self.panel = panel
        self.layers = built
    }

    func setTime(_ s: String) { layers?.setTime(s) }

    func close() {
        panel?.orderOut(nil)
        panel = nil; layers = nil
    }
}

private final class RecPillView: NSView {
    var stop = CGRect.zero, cancel = CGRect.zero // y down, view coordinates
    var onStop: (() -> Void)?, onCancel: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Hit areas are the 28 pt circles, a little generous (the capsule is 38 high).
    private func down(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: bounds.height - p.y) }
    override func mouseDown(with event: NSEvent) {
        let p = down(convert(event.locationInWindow, from: nil))
        if stop != .zero, stop.insetBy(dx: -2, dy: -5).contains(p) { onStop?() }
        else if cancel != .zero, cancel.insetBy(dx: -2, dy: -5).contains(p) { onCancel?() }
    }
    override func resetCursorRects() {
        for r in [stop, cancel] where r != .zero {
            addCursorRect(CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height), cursor: .pointingHand)
        }
    }
}
