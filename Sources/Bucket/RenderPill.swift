import AppKit
import BucketCore
import QuartzCore

/// Offscreen renders of the companion and the keycaps: the live layer tree on the reference canvas, with the
/// opaque material fallback. States ending in `@0.5` are fixed poses, not interpolated frames.
enum PillRender {
    static let scale = 2
    /// Reference canvas: 200 × 64 pt.
    static let size = CompanionPlacement.canvas

    static let states: [String: (Bool) -> Data?] = [
        "pill-1": { png(dark: $0) { $0.still(count: 1, text: CompanionCopy.count(1), form: .expanded) } },
        "pill-3": { png(dark: $0) { $0.still(count: 3, text: CompanionCopy.count(3), form: .expanded) } },
        "pill-compact": { png(dark: $0) { $0.still(count: 7, text: CompanionCopy.count(7), form: .compact) } },
        "pill-absorb@0.5": { png(dark: $0) { $0.absorbPose() } },
        "pill-release@0.5": { png(dark: $0) { $0.releasePose() } },
        "pill-error": { errorPNG(dark: $0) },
        "keycaps-capture": { keycapsPNG(["⌘", "⇧", "4"], dark: $0) },
        "keycaps-paste": { keycapsPNG(["⌘", "V"], dark: $0) },
        "keycaps-recopy": { keycapsPNG(["⌥", "⇧", "V"], dark: $0) },
    ]

    /// Renders `build`'s layer tree on the reference canvas with a drawn cursor at (8, 8).
    static func png(dark: Bool, build: (PillRig) -> Void) -> Data? {
        let rig = PillRig(dark: dark, opaqueMaterial: true)
        build(rig)
        let root = CALayer()
        root.bounds = CGRect(origin: .zero, size: size)
        root.anchorPoint = .zero
        root.backgroundColor = rig.palette.canvas
        root.masksToBounds = true
        // The rig canvas is the window (reference canvas + bleed); the reference canvas sits at (bleed, bleed) inside it.
        rig.canvas.position = CGPoint(x: -CompanionPlacement.bleed, y: -CompanionPlacement.bleed)
        root.addSublayer(rig.canvas)
        root.addSublayer(cursorLayer(at: CGPoint(x: CompanionPlacement.bleed + 8, y: CompanionPlacement.bleed + 8), rig: rig))
        return rasterize(root, size: size)
    }

    /// The macOS arrow, box origin at the cursor point, drawn in the window's y-down space.
    static func cursorLayer(at p: CGPoint, rig: PillRig, side: PillSide = PillSide(), canvasHeight: CGFloat = CompanionPlacement.canvas.height) -> CALayer {
        let l = CAShapeLayer()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 1, y: 1)); path.addLine(to: CGPoint(x: 1, y: 18)); path.addLine(to: CGPoint(x: 5.5, y: 13.8))
        path.addLine(to: CGPoint(x: 8.5, y: 20.6)); path.addLine(to: CGPoint(x: 11.3, y: 19.4)); path.addLine(to: CGPoint(x: 8.3, y: 12.8))
        path.addLine(to: CGPoint(x: 14, y: 12.8)); path.closeSubpath()
        var t = CGAffineTransform(scaleX: 14 / 16, y: 20 / 22)
        l.path = path.copy(using: &t)
        l.fillColor = CGColor(gray: rig.palette.dark ? 1 : 0, alpha: 1)
        l.strokeColor = CGColor(gray: rig.palette.dark ? 0 : 1, alpha: 1)
        l.lineWidth = 1.2
        l.lineJoin = .round
        l.bounds = CGRect(x: 0, y: 0, width: 14, height: 20)
        l.anchorPoint = .zero
        // This layer is a child of root (y-up), the point is in window (y-down) coordinates.
        l.position = CGPoint(x: p.x - CompanionPlacement.bleed, y: canvasHeight - (p.y - CompanionPlacement.bleed) - 20)
        l.isGeometryFlipped = true
        return l
    }

    static func rasterize(_ root: CALayer, size: CGSize) -> Data? {
        let pw = Int(size.width) * scale, ph = Int(size.height) * scale
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let ctx = gc.cgContext
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.layoutIfNeeded()
        root.render(in: ctx)
        CATransaction.commit()
        gc.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }

    /// Optional `pill-error`: wider than the reference canvas (the text and the link do not fit in 200 pt), same 64 pt of height.
    static func errorPNG(dark: Bool) -> Data? {
        let palette = PillPalette(dark: dark)
        let built = ErrorPill.build(palette: palette, opaque: true)
        let w = max(size.width, 26 + built.pill.width + 8)
        let root = CALayer()
        root.bounds = CGRect(x: 0, y: 0, width: w, height: size.height)
        root.anchorPoint = .zero
        root.backgroundColor = palette.canvas
        root.masksToBounds = true
        let l = built.layer
        // The layer carries 24 pt of padding around the pill: put the pill at (26, 26) like the other pills.
        let off = 26 - ErrorPill.pad
        l.position = CGPoint(x: off, y: size.height - off - l.bounds.height)
        root.addSublayer(l)
        let cursor = cursorLayer(at: CGPoint(x: CompanionPlacement.bleed + 8, y: CompanionPlacement.bleed + 8), rig: PillRig(dark: dark, opaqueMaterial: true))
        root.addSublayer(cursor)
        return rasterize(root, size: CGSize(width: w, height: size.height))
    }

    static func keycapsPNG(_ symbols: [String], dark: Bool) -> Data? {
        let palette = PillPalette(dark: dark)
        let row = KeycapRow(symbols: symbols, palette: palette, opaqueMaterial: true)
        let root = CALayer()
        root.bounds = CGRect(origin: .zero, size: size)
        root.anchorPoint = .zero
        root.backgroundColor = palette.canvas
        root.masksToBounds = true
        let r = row.layer
        // Centered in the reference canvas (the live window centers on the screen instead).
        r.position = CGPoint(x: (size.width - r.bounds.width) / 2, y: (size.height - r.bounds.height) / 2)
        root.addSublayer(r)
        return rasterize(root, size: size)
    }
}

extension PillRig {
    /// A resting pill.
    func still(count: Int, text: String, form: CompanionModel.Form, side: PillSide = PillSide()) {
        apply(PillState(side: side, form: form, text: text, number: "\(count)", glyph: GlyphState(count: count)))
    }

    /// `pill-absorb@0.5`, 2 → 3: expanded "3 in bucket"; glyph squashed (1.08, .90) from 50 % · 92 %;
    /// stripe0 and stripe1 whole, stripe2 at scaleY .6 from the bottom; no drop.
    func absorbPose() {
        still(count: 3, text: CompanionCopy.count(3), form: .expanded)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let q = Motion.Absorb.squashKeys[1]
        squash.setAffineTransform(CGAffineTransform(scaleX: q.x, y: q.y))
        stripes[2].setAffineTransform(CGAffineTransform(scaleX: 1, y: 0.6))
        CATransaction.commit()
    }

    /// `pill-release@0.5`: 3 shots, no text; glyph centered in the capsule and tilted toward the cursor about its
    /// bottom-center, all inside the capsule; stripe2 already emptied, stripe1 halfway (opacity .5, scaleY .7 from its base),
    /// stripe0 still in the bucket.
    func releasePose() {
        still(count: 3, text: CompanionCopy.count(3), form: .expanded) // the pill is still as wide as "3 in bucket"
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let theta = -CGFloat(Motion.Release.tiltDegrees) * .pi / 180 // the pill is right of the cursor: it leans left
        let r = rect(for: state)
        place.position = CGPoint(x: r.midX - inkCenterX(rotatedBy: theta), y: r.midY)
        textNew.opacity = 0
        tilt.setAffineTransform(CGAffineTransform(rotationAngle: theta))
        stripes[2].isHidden = true
        stripes[1].opacity = 0.5
        stripes[1].setAffineTransform(CGAffineTransform(scaleX: 1, y: (1 + CGFloat(Motion.Release.pourScaleY)) / 2))
        CATransaction.commit()
    }
}
