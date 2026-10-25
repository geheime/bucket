import AppKit
import BucketCore
import QuartzCore

extension GlyphBitmap {
    /// Master glyph, empty and struck through (`error` state): erase M10 8 L56 58 at 8, then stroke it at 3.2.
    static func slashed(size: CGFloat, palette: PillPalette, scale: Int = 2) -> CGImage? {
        let px = Int(size) * scale
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        ctx.translateBy(x: 0, y: size)
        ctx.scaleBy(x: 1, y: -1)
        Glyph.drawMaster(.empty, in: ctx, size: size, ink: palette.ink, stripe: palette.accent)
        ctx.saveGState()
        ctx.scaleBy(x: size / 64, y: size / 64)
        ctx.translateBy(x: 0, y: 2)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 10, y: 8)); ctx.addLine(to: CGPoint(x: 56, y: 58))
        ctx.setBlendMode(.clear); ctx.setLineWidth(8); ctx.strokePath()
        ctx.move(to: CGPoint(x: 10, y: 8)); ctx.addLine(to: CGPoint(x: 56, y: 58))
        ctx.setBlendMode(.normal); ctx.setStrokeColor(palette.ink); ctx.setLineWidth(3.2); ctx.strokePath()
        ctx.restoreGState()
        return ctx.makeImage()
    }
}

/// The pill of the Screen Recording error: the ONE clickable piece of the companion. Another panel,
/// nonactivating, that does not follow the cursor and does not leave by itself. It closes when the permission is granted,
/// when "Open Settings…" is used, with ESC once it has been clicked (it never grabs focus on its own), or when a new
/// capture starts.
final class ErrorPill {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    static let pad: CGFloat = 24

    private var panel: BucketPanel?
    private var poll: Timer?
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Asks whether the permission is there now (injected so the pill does not know about CoreGraphics).
    var permissionGranted: () -> Bool = { false }
    var onGranted: () -> Void = {}

    init() { BucketWindows.register { [weak self] in self?.close() } }

    var isShown: Bool { panel?.isVisible == true }

    /// Layers of the pill on its own coordinate space (y-down, origin at the pill's top-left + pad). `opaque` is for renders.
    static func build(palette: PillPalette, opaque: Bool) -> (layer: CALayer, pill: CGRect, size: CGSize) {
        let text = CompanionCopy.permissionNeeded, link = CompanionCopy.openSettings
        let tf = NSFont.systemFont(ofSize: 13, weight: .regular), lf = NSFont.systemFont(ofSize: 13, weight: .medium)
        let tw = PillFont.width(text, tf), lw = PillFont.width(link, lf)
        let w = 4 + PillRig.expandedGlyph + 6 + tw + 12 + lw + 14, h = CompanionPlacement.expandedHeight
        let size = CGSize(width: w + 2 * pad, height: h + 2 * pad)
        let root = CALayer()
        root.bounds = CGRect(origin: .zero, size: size)
        root.anchorPoint = .zero
        root.isGeometryFlipped = true
        let pill = CGRect(x: pad, y: pad, width: w, height: h)

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

        let g = CALayer()
        g.bounds = CGRect(x: 0, y: 0, width: PillRig.expandedGlyph, height: PillRig.expandedGlyph)
        g.anchorPoint = .zero
        g.position = CGPoint(x: pill.minX + 4, y: pill.minY + 4)
        g.contents = GlyphBitmap.slashed(size: PillRig.expandedGlyph, palette: palette)
        g.contentsScale = 2
        root.addSublayer(g)

        func label(_ s: String, _ f: NSFont, _ color: CGColor, x: CGFloat, w: CGFloat) {
            let t = CATextLayer()
            t.contentsScale = 2; t.font = f; t.fontSize = f.pointSize; t.string = s; t.foregroundColor = color
            t.alignmentMode = .left
            t.frame = CGRect(x: x, y: pill.midY - 8, width: w + 2, height: 16)
            root.addSublayer(t)
        }
        label(text, tf, palette.ink, x: pill.minX + 40, w: tw)
        // bucket.accentInk: the one text that carries the accent.
        let ink = palette.dark ? PillPalette.hex(0xFF7FB0) : PillPalette.hex(0xB30A4B)
        label(link, lf, ink, x: pill.minX + 40 + tw + 12, w: lw)
        return (root, pill, size)
    }

    func show(at cursor: CGPoint) {
        close()
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let palette = PillPalette(dark: dark)
        let built = ErrorPill.build(palette: palette, opaque: true)
        let panel = BucketPanel(size: built.size, ignoresMouse: false)
        panel.acceptsKey = true
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = ErrorPillView(frame: CGRect(origin: .zero, size: built.size))
        host.wantsLayer = true
        host.onClick = { [weak self] in
            NSWorkspace.shared.open(ErrorPill.settingsURL)
            self?.close()
        }
        host.onEscape = { [weak self] in self?.close() }
        let p = built.pill
        host.layer?.addSublayer(built.layer)
        built.layer.position = .zero
        panel.contentView = host

        // Same offset as the companion, fixed where the capture was attempted.
        let off = CGFloat(Motion.Behavior.cursorOffset)
        panel.setFrame(CGRect(x: cursor.x + off - ErrorPill.pad, y: cursor.y - off - p.height - ErrorPill.pad, width: built.size.width, height: built.size.height), display: false)
        panel.orderFrontRegardless()
        self.panel = panel

        // Missing permission: 180 ms outStrong at t = 480 (after the bar's shake), opacity + rise 4; it does not leave by itself.
        let base = Anim.now, step = reduceMotion ? Motion.Reduced.crossfade : Motion.Edges.permissionErrorAppear
        built.layer.add(Anim.basic("opacity", from: 0, to: 1, step, base: base), forKey: "in")
        if !reduceMotion {
            built.layer.add(Anim.basic("position.y", from: Motion.Pill.appearRise, to: 0, step, base: base, additive: true), forKey: "rise")
        }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.permissionGranted() else { return }
            self.close(); self.onGranted()
        }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    func close() {
        poll?.invalidate(); poll = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class ErrorPillView: NSView {
    var onClick: (() -> Void)?
    var onEscape: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); onClick?() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) } }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
