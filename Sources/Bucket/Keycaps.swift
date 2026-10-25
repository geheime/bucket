import AppKit
import BucketCore
import Carbon
import QuartzCore

/// The keys of a gesture drawn as keycaps: 32 × 32, radius 8, material, 0.5 pt edge, 1 pt bottom edge, shadow.
final class KeycapRow {
    static let pad: CGFloat = 16          // room around the row for the shadow
    static let capSize: CGFloat = 32
    static let gap: CGFloat = 6
    static let radius: CGFloat = 8

    let layer = CALayer()                 // y-down, row + padding
    let group = CALayer()                 // enters, holds, leaves
    private(set) var caps: [CALayer] = []
    let size: CGSize                      // row only
    var windowSize: CGSize { CGSize(width: size.width + 2 * KeycapRow.pad, height: size.height + 2 * KeycapRow.pad) }
    let palette: PillPalette
    /// y-up mask of the live material (one rounded rect per key) and the layers that mirror `group` animations.
    let liveMask = CAShapeLayer()
    var mirrors: [(layer: CALayer, flipY: CGFloat)] = []
    private var rects: [CGRect] = []      // per key, in layer coordinates (y-down)

    init(symbols: [String], palette: PillPalette, opaqueMaterial: Bool) {
        self.palette = palette
        let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let widths = symbols.map { max(KeycapRow.capSize, PillFont.width($0, font) + 20) }
        let total = widths.reduce(0, +) + KeycapRow.gap * CGFloat(max(symbols.count - 1, 0))
        size = CGSize(width: total, height: KeycapRow.capSize)
        let ws = size.width + 2 * KeycapRow.pad, hs = size.height + 2 * KeycapRow.pad
        layer.bounds = CGRect(x: 0, y: 0, width: ws, height: hs)
        layer.anchorPoint = .zero
        layer.isGeometryFlipped = true
        group.bounds = layer.bounds   // scales about its center (enter .96→1, exit →.98)
        group.position = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        layer.addSublayer(group)

        var x = KeycapRow.pad
        for (i, sym) in symbols.enumerated() {
            let r = CGRect(x: x, y: KeycapRow.pad, width: widths[i], height: KeycapRow.capSize)
            rects.append(r)
            let cap = CALayer()                       // pivot of the press: its own center
            cap.bounds = CGRect(origin: .zero, size: r.size)
            cap.position = CGPoint(x: r.midX, y: r.midY)
            group.addSublayer(cap)
            caps.append(cap)
            build(cap, symbol: sym, font: font, opaqueMaterial: opaqueMaterial)
            x += widths[i] + KeycapRow.gap
        }
        liveMask.path = maskPath(scale: 1, dy: 0)
    }

    private func build(_ cap: CALayer, symbol: String, font: NSFont, opaqueMaterial: Bool) {
        let b = cap.bounds
        let shape = CGPath(roundedRect: b, cornerWidth: KeycapRow.radius, cornerHeight: KeycapRow.radius, transform: nil)

        // Shadow outside only, so a translucent material is not darkened from below.
        let shadow = CALayer()
        shadow.frame = b.insetBy(dx: -KeycapRow.pad, dy: -KeycapRow.pad)
        shadow.shadowColor = PillPalette.shadow
        shadow.shadowOpacity = 0.14
        shadow.shadowRadius = 6
        shadow.shadowOffset = CGSize(width: 0, height: 4)
        var toShadow = CGAffineTransform(translationX: KeycapRow.pad, y: KeycapRow.pad)
        shadow.shadowPath = shape.copy(using: &toShadow)
        let hole = CAShapeLayer()
        hole.frame = shadow.bounds
        let hp = CGMutablePath(); hp.addRect(hole.bounds); hp.addPath(shape.copy(using: &toShadow)!)
        hole.path = hp; hole.fillRule = .evenOdd
        shadow.mask = hole
        cap.addSublayer(shadow)

        if opaqueMaterial {
            let fill = CALayer()
            fill.frame = b
            fill.backgroundColor = palette.material
            fill.cornerRadius = KeycapRow.radius
            cap.addSublayer(fill)
        }

        // 1 pt bottom edge inside the key: the cap minus itself shifted up, clipped to the cap.
        let canto = CAShapeLayer()
        canto.frame = b
        let cp = CGMutablePath(); cp.addPath(shape)
        var up = CGAffineTransform(translationX: 0, y: -1)
        cp.addPath(shape.copy(using: &up)!)
        canto.path = cp; canto.fillRule = .evenOdd
        canto.fillColor = palette.separator
        let clip = CAShapeLayer(); clip.frame = b; clip.path = shape
        canto.mask = clip
        cap.addSublayer(canto)

        let edge = CAShapeLayer()
        edge.frame = b
        edge.path = CGPath(roundedRect: b.insetBy(dx: 0.25, dy: 0.25), cornerWidth: KeycapRow.radius - 0.25,
                           cornerHeight: KeycapRow.radius - 0.25, transform: nil)
        edge.fillColor = nil
        edge.strokeColor = palette.edge
        edge.lineWidth = 0.5
        cap.addSublayer(edge)

        let text = CATextLayer()
        text.contentsScale = 2
        text.font = font
        text.fontSize = font.pointSize
        text.string = symbol
        text.foregroundColor = palette.ink
        text.alignmentMode = .center
        text.frame = CGRect(x: 0, y: (b.height - 18) / 2, width: b.width, height: 18)
        cap.addSublayer(text)
    }

    /// Union of the key shapes in y-up window coordinates (for the live NSVisualEffectView), each key scaled/shifted
    /// about its own center so the blur follows the press.
    func maskPath(scale: CGFloat, dy: CGFloat) -> CGPath {
        let p = CGMutablePath()
        for r in rects {
            let w = r.width * scale, h = r.height * scale
            let yDown = r.midY - h / 2 + dy
            let up = CGRect(x: r.midX - w / 2, y: layer.bounds.height - (yDown + h), width: w, height: h)
            p.addRoundedRect(in: up, cornerWidth: KeycapRow.radius * scale, cornerHeight: KeycapRow.radius * scale)
        }
        return p
    }
}

/// Keycap overlay window. One instance: a new gesture replaces the one on screen.
final class KeycapOverlay {
    private var panel: BucketPanel?
    private var row: KeycapRow?
    private var work: DispatchWorkItem?
    private let policy: KeycapPolicy
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(policy: KeycapPolicy = KeycapPolicy()) {
        self.policy = policy
        BucketWindows.register { [weak self] in self?.hideNow() }
    }

    /// Shows the keys of `gesture` if the policy allows it. Never during the capture itself (the controller calls this
    /// when the capture ended).
    func show(_ gesture: KeycapPolicy.Gesture, captureSymbols: [String]) {
        guard policy.consume(gesture) else { return }
        present(Keycap.symbols(gesture, capture: captureSymbols))
    }

    func hideNow() {
        work?.cancel()
        row?.group.removeAllAnimations()
        panel?.orderOut(nil)
    }

    private func present(_ symbols: [String]) {
        hideNow()
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let row = KeycapRow(symbols: symbols, palette: PillPalette(dark: dark), opaqueMaterial: true)
        self.row = row
        let ws = row.windowSize
        let panel = self.panel ?? BucketPanel(size: ws)
        self.panel = panel

        let host = NSView(frame: CGRect(origin: .zero, size: ws))
        host.wantsLayer = true
        host.layer?.addSublayer(row.layer)
        row.layer.position = .zero
        panel.contentView = host

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let f = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        // Centered, bottom edge 72 pt over the Dock: far from the cursor on purpose, the pill already lives there.
        panel.setFrame(CGRect(x: f.midX - ws.width / 2, y: f.minY + 72 - KeycapRow.pad, width: ws.width, height: ws.height), display: false)
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        panel.orderFrontRegardless()
        KeycapRow.animate(row, base: Anim.now, reduceMotion: reduceMotion)
        let w = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? Motion.Reduced.keycapsTotal : Motion.Keycaps.total) / 1000 + 0.05, execute: w)
    }

}

extension KeycapRow {
    /// The model is the final (hidden) state; the tracks are everything before it. `base` is the media time of t = 0.
    static func animate(_ row: KeycapRow, base: CFTimeInterval, reduceMotion: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        row.group.opacity = 0
        CATransaction.commit()

        func groupTrack(_ make: (CGFloat) -> CAAnimation, _ key: String) {
            row.group.add(make(1), forKey: key)
        }

        if reduceMotion {
            // Opacity only, 1200 ms: in during the first 15 %, out during the last 15 %.
            let e = Motion.Reduced.keycapsEdge
            groupTrack({ _ in Anim.keyframes("opacity", values: [0, 1, 1, 0], times: [0, e, 1 - e, 1], dur: Motion.Reduced.keycapsTotal, base: base) }, "rm")
            return
        }
        let K = Motion.Keycaps.self
        let t1 = K.enter.end / K.total, t2 = K.exit.start / K.total
        let enterC = K.enter.curve, exitC = K.exit.curve, hold = Motion.Curve.linear
        groupTrack({ _ in Anim.keyframes("opacity", values: [0, 1, 1, 0], times: [0, t1, t2, 1], dur: K.total,
                                         curves: [enterC, hold, exitC], base: base) }, "opacity")
        groupTrack({ s in Anim.keyframes("position.y", values: [K.enterRise * s, 0, 0, K.exitDrop * s], times: [0, t1, t2, 1], dur: K.total,
                                         curves: [enterC, hold, exitC], base: base, additive: true) }, "rise")
        row.group.add(Anim.keyframes("transform.scale", values: [K.enterScaleFrom, 1, 1, K.exitScaleTo], times: [0, t1, t2, 1], dur: K.total,
                                     curves: [enterC, hold, exitC], base: base), forKey: "scale")
        let p = K.press
        let down = [1, K.pressScale, 1]
        for cap in row.caps {
            cap.add(Anim.keyframes("transform.scale", values: down, times: [0, 0.5, 1], start: p.start, dur: p.dur,
                                   curves: [p.curve, p.curve], base: base), forKey: "press")
            cap.add(Anim.keyframes("position.y", values: [0, K.pressDrop, 0], times: [0, 0.5, 1], start: p.start, dur: p.dur,
                                   curves: [p.curve, p.curve], base: base, additive: true), forKey: "pressDrop")
        }
    }
}
