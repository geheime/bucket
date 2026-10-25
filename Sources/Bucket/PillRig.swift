import AppKit
import BucketCore
import QuartzCore

/// Colors of the companion for one appearance. Resolved once per appearance change, not per frame.
struct PillPalette {
    let dark: Bool
    let ink: CGColor          // text.primary
    let accent: CGColor       // bucket.accent
    let edge: CGColor         // edge: 0.5 pt interior contour
    let separator: CGColor    // separator: keycap bottom edge
    let material: CGColor     // opaque fallback of .popover, only for offscreen renders
    let canvas: CGColor       // render canvas background

    init(dark: Bool) {
        self.dark = dark
        ink = PillPalette.resolve(.labelColor, dark: dark)
        accent = PillPalette.resolve(Glyph.accent, dark: dark)
        separator = PillPalette.resolve(.separatorColor, dark: dark)
        edge = dark ? CGColor(gray: 1, alpha: 0.12) : CGColor(gray: 0, alpha: 0.10)
        material = dark ? PillPalette.hex(0x2A2B30) : PillPalette.hex(0xF4F4F6)
        canvas = dark ? PillPalette.hex(0x1B1D22) : PillPalette.hex(0xD5DAE1)
    }

    static func resolve(_ c: NSColor, dark: Bool) -> CGColor {
        var out = c.cgColor
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { out = c.cgColor }
        return out
    }
    static func hex(_ v: Int) -> CGColor {
        CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    static let shadow = hex(0x0F1115)
}

enum PillFont {
    /// SF Pro Rounded: the friendly count voice.
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) else { return base }
        return f
    }
    static func tabular(_ font: NSFont) -> NSFont {
        let d = font.fontDescriptor.addingAttributes([.featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                                                          NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]])
        return NSFont(descriptor: d, size: font.pointSize) ?? font
    }
    static let pill = rounded(13, .semibold)          // count.pill
    static let compact = tabular(rounded(13, .semibold)) // count.compact
    static func width(_ s: String, _ font: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: font]).width) }
}

/// What a pill shows at rest. The rig turns it into layers; animations only ever move between two of these.
struct PillState: Equatable {
    var side = PillSide()
    var form: CompanionModel.Form = .expanded
    var text = ""        // expanded text
    var number = ""      // compact text
    var glyph: GlyphState = .empty
}

/// The companion as a Core Animation tree. Lives in a fixed canvas (the window never changes size:
/// animations move layers). Coordinates inside `canvas` are y-down. The same tree is drawn in the window and, with
/// an opaque material, offscreen by `Bucket render`, so a render shows exactly what the window animates.
final class PillRig {
    static let expandedGlyph: CGFloat = 30
    static let compactGlyph: CGFloat = 24

    private(set) var palette: PillPalette
    let canvas = CALayer()          // y-down, window size
    let group = CALayer()           // the whole pill: enters, slides between sides
    let bgGroup = CALayer()         // shadow + material + edge: fades while flying to the bar
    let texts = CALayer()
    let shadow = CALayer()
    let shadowMask = CAShapeLayer()
    let fill = CALayer()            // opaque material: render only
    let fillMask = CAShapeLayer()
    let edge = CAShapeLayer()
    let textOld = CATextLayer(), textNew = CATextLayer(), number = CATextLayer()

    // Glyph: place (compact scale) → squash → tilt → relief → master. Each box is 30 × 30 and sits on its parent,
    // with its own anchor point, because an anchor is per layer and every motion pivots somewhere else.
    let place = CALayer(), squash = CALayer(), tilt = CALayer(), relief = CALayer(), master = CALayer()
    let handle = CAShapeLayer(), body = CAShapeLayer(), lip = CAShapeLayer()
    private(set) var stripes: [CAShapeLayer] = []
    let full = CAShapeLayer()
    private var fullBox = CGRect.zero

    /// Layers that must follow `group` (the live NSVisualEffectView): (layer, y sign of translations).
    var mirrors: [(layer: CALayer, flipY: CGFloat)] = []
    /// y-up mask of the live material, kept in sync with the capsule.
    var liveMask: CAShapeLayer?
    /// Anything born during an event (shot, drop, flying bars): thrown away when the event ends or is interrupted.
    var transient: [CALayer] = []

    private(set) var state = PillState()
    private(set) var expandedWidth: CGFloat = 124
    private(set) var compactWidth: CGFloat = 50

    init(dark: Bool, opaqueMaterial: Bool) {
        palette = PillPalette(dark: dark)
        let w = CompanionPlacement.window
        canvas.bounds = CGRect(origin: .zero, size: w)
        canvas.anchorPoint = .zero
        canvas.position = .zero
        canvas.isGeometryFlipped = true
        for l in [group, bgGroup, texts] { l.bounds = canvas.bounds; l.anchorPoint = .zero; l.position = .zero }
        canvas.addSublayer(group)
        group.addSublayer(bgGroup)

        shadow.bounds = canvas.bounds; shadow.anchorPoint = .zero; shadow.position = .zero
        shadow.shadowColor = PillPalette.shadow
        shadow.shadowOpacity = 0.16
        shadow.shadowRadius = 7
        shadow.shadowOffset = CGSize(width: 0, height: 4) // y-down canvas: positive = below (the CSS-style (0, −4) is for y-up)
        shadow.mask = shadowMask
        bgGroup.addSublayer(shadow)

        fill.bounds = canvas.bounds; fill.anchorPoint = .zero; fill.position = .zero
        fill.mask = fillMask
        fill.isHidden = !opaqueMaterial
        bgGroup.addSublayer(fill)

        edge.fillColor = nil
        edge.lineWidth = 0.5
        bgGroup.addSublayer(edge)

        buildGlyph()
        group.addSublayer(place)
        group.addSublayer(texts)
        for t in [textOld, textNew, number] {
            t.contentsScale = 2
            t.alignmentMode = .left
            t.truncationMode = .none
            t.isWrapped = false
            t.allowsFontSubpixelQuantization = true
            texts.addSublayer(t)
        }
        applyPalette(palette)
        apply(PillState())
    }

    // MARK: Palette

    func applyPalette(_ p: PillPalette) {
        palette = p
        fill.backgroundColor = p.material
        edge.strokeColor = p.edge
        for t in [textOld, textNew, number] { t.foregroundColor = p.ink }
        for l in [handle, body, lip] { l.strokeColor = p.ink }
        for s in stripes + [full] { s.fillColor = p.accent }
    }

    // MARK: Glyph (master 64, one layer per stripe)

    private func buildGlyph() {
        let G = PillRig.expandedGlyph
        for l in [place, squash, tilt, relief] { l.bounds = CGRect(x: 0, y: 0, width: G, height: G) }
        place.addSublayer(squash); squash.addSublayer(tilt); tilt.addSublayer(relief); relief.addSublayer(master)
        setAnchor(place, 0, 0.5, in: nil)
        setAnchor(squash, 0.5, 0.92, in: place)
        setAnchor(tilt, 0.5, 0.9, in: squash)
        setAnchor(relief, 0.5, 1.0, in: tilt)

        master.bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
        master.anchorPoint = .zero
        master.position = .zero
        let k = G / 64
        master.setAffineTransform(CGAffineTransform(scaleX: k, y: k).translatedBy(x: 0, y: 2)) // drawMaster: scale, then +2 in y

        func shape(_ l: CAShapeLayer, _ path: CGPath, width: CGFloat) {
            l.frame = master.bounds
            l.path = path
            l.fillColor = nil
            l.lineWidth = width
            l.lineCap = .round
            l.lineJoin = .round
            master.addSublayer(l)
        }
        shape(handle, MasterGeometry.handle, width: 1.6)
        shape(body, MasterGeometry.body, width: 3.2)
        shape(lip, MasterGeometry.lip, width: 3.2)

        // Stripes are boxes of their own so they can scale from the bottom and be copied for the flight.
        func box(_ l: CAShapeLayer, _ p: CGPath) -> CGRect {
            let r = p.boundingBoxOfPath
            l.bounds = CGRect(origin: .zero, size: r.size)
            l.anchorPoint = CGPoint(x: 0.5, y: 1)
            l.position = CGPoint(x: r.midX, y: r.maxY)
            var t = CGAffineTransform(translationX: -r.minX, y: -r.minY)
            l.path = p.copy(using: &t)
            master.addSublayer(l)
            return r
        }
        for p in MasterGeometry.stripes {
            let l = CAShapeLayer()
            _ = box(l, p)
            stripes.append(l)
        }
        fullBox = box(full, MasterGeometry.full)
    }

    /// Anchor at (x, y) of a 30 × 30 box that coincides with its parent (or, for `place`, placed by the caller).
    func setAnchor(_ l: CALayer, _ x: CGFloat, _ y: CGFloat, in parent: CALayer?) {
        l.anchorPoint = CGPoint(x: x, y: y)
        if parent != nil { l.position = CGPoint(x: x * l.bounds.width, y: y * l.bounds.height) }
    }

    func setGlyph(_ g: GlyphState) {
        for (i, s) in stripes.enumerated() { s.isHidden = i >= g.stripeCount }
        full.isHidden = g != .full
    }

    // MARK: Layout

    /// Expanded and compact rects inside the canvas for a state.
    func rects(_ s: PillState) -> (expanded: CGRect, compact: CGRect) {
        let ew = 4 + PillRig.expandedGlyph + 6 + PillFont.width(s.text, PillFont.pill) + 14
        let cw = 4 + PillRig.compactGlyph + 4 + PillFont.width(s.number, PillFont.compact) + 10
        expandedWidth = ew; compactWidth = cw
        let e = CompanionPlacement.expandedRect(side: s.side, width: ew)
        return (e, CompanionPlacement.compactRect(side: s.side, expanded: e, width: cw))
    }

    func rect(for s: PillState) -> CGRect { let r = rects(s); return s.form == .expanded ? r.expanded : r.compact }
    func radius(for form: CompanionModel.Form) -> CGFloat { form == .expanded ? 19 : 16 }

    /// Final, still pose: no animation. Everything animated is built on top of this.
    func apply(_ s: PillState) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        state = s
        let r = rects(s)
        let cur = s.form == .expanded ? r.expanded : r.compact
        setShape(cur, radius: radius(for: s.form))
        setGlyph(s.glyph)

        // Glyph box sits left-center of the current rect; compact is the same box scaled to 24/30.
        place.position = CGPoint(x: cur.minX + 4, y: cur.midY)
        place.setAffineTransform(s.form == .expanded ? .identity : CGAffineTransform(scaleX: CGFloat(Motion.Pill.compactGlyphScale), y: CGFloat(Motion.Pill.compactGlyphScale)))

        place_texts(r, s)
    }

    private func place_texts(_ r: (expanded: CGRect, compact: CGRect), _ s: PillState) {
        func style(_ t: CATextLayer, _ str: String, font: NSFont, x: CGFloat, midY: CGFloat, alpha: Float) {
            t.font = font
            t.fontSize = font.pointSize
            t.string = str
            let w = PillFont.width(str, font) + 2
            t.frame = CGRect(x: x, y: midY - 8, width: w, height: 16)
            t.opacity = alpha
        }
        style(textNew, s.text, font: PillFont.pill, x: r.expanded.minX + 40, midY: r.expanded.midY, alpha: s.form == .expanded ? 1 : 0)
        style(textOld, s.text, font: PillFont.pill, x: r.expanded.minX + 40, midY: r.expanded.midY, alpha: 0)
        style(number, s.number, font: PillFont.compact, x: r.compact.minX + 32, midY: r.compact.midY, alpha: s.form == .compact ? 1 : 0)
    }

    // MARK: Shape (capsule), shared by shadow, material, edge and the live blur mask

    func setShape(_ rect: CGRect, radius: CGFloat) {
        let p = PillRig.paths(rect: rect, radius: radius, canvas: canvas.bounds)
        shadow.shadowPath = p.capsule
        shadowMask.path = p.hole
        shadowMask.fillRule = .evenOdd
        fillMask.path = p.capsule
        edge.path = p.edge
        liveMask?.path = p.flipped
    }

    struct ShapePaths { let capsule: CGPath; let hole: CGPath; let edge: CGPath; let flipped: CGPath }

    static func paths(rect: CGRect, radius: CGFloat, canvas: CGRect) -> ShapePaths {
        let cap = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let hole = CGMutablePath(); hole.addRect(canvas.insetBy(dx: -64, dy: -64)); hole.addPath(cap)
        let e = rect.insetBy(dx: 0.25, dy: 0.25)
        let edge = CGPath(roundedRect: e, cornerWidth: radius - 0.25, cornerHeight: radius - 0.25, transform: nil)
        // y-up version for the NSVisualEffectView layer (not flipped): mirror around the canvas height.
        let fr = CGRect(x: rect.minX, y: canvas.height - rect.maxY, width: rect.width, height: rect.height)
        let flipped = CGPath(roundedRect: fr, cornerWidth: radius, cornerHeight: radius, transform: nil)
        return ShapePaths(capsule: cap, hole: hole, edge: edge, flipped: flipped)
    }

    /// All shape layers that need the same `path` animation, with the property each one animates.
    func shapeTargets(from a: (CGRect, CGFloat), to b: (CGRect, CGFloat)) -> [(CALayer, String, CGPath, CGPath)] {
        let pa = PillRig.paths(rect: a.0, radius: a.1, canvas: canvas.bounds)
        let pb = PillRig.paths(rect: b.0, radius: b.1, canvas: canvas.bounds)
        var out: [(CALayer, String, CGPath, CGPath)] = [
            (shadow, "shadowPath", pa.capsule, pb.capsule),
            (shadowMask, "path", pa.hole, pb.hole),
            (fillMask, "path", pa.capsule, pb.capsule),
            (edge, "path", pa.edge, pb.edge),
        ]
        if let m = liveMask { out.append((m, "path", pa.flipped, pb.flipped)) }
        return out
    }

    func cleanTransient() {
        transient.forEach { $0.removeAllAnimations(); $0.removeFromSuperlayer() }
        transient.removeAll()
    }

    /// Back to final values: kills every running animation, as required when a new gesture arrives.
    func removeAllAnimations() {
        let all: [CALayer] = [group, bgGroup, texts, shadow, shadowMask, fillMask, edge, textOld, textNew, number,
                              place, squash, tilt, relief, master, full] + stripes + mirrors.map(\.layer) + (liveMask.map { [$0] } ?? [])
        all.forEach { $0.removeAllAnimations() }
        cleanTransient()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        group.opacity = 1
        for l in [place, squash, tilt, relief] { l.opacity = 1 }
        setAnchor(squash, 0.5, 0.92, in: place); setAnchor(tilt, 0.5, 0.9, in: squash)
        for l in [squash, tilt, relief] { l.setAffineTransform(.identity) }
        for s in stripes + [full] { s.opacity = 1; s.setAffineTransform(.identity) }
        // `flightOut` leaves texts, material and its live mirrors at 0 as the model: whatever comes next starts from 1.
        texts.opacity = 1
        bgGroup.opacity = 1
        for m in mirrors { m.layer.opacity = 1 }
        CATransaction.commit()
    }
}
