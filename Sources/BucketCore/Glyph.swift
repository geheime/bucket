import AppKit

/// Bucket "Arco" glyph. Lives in Core so the checks can test the geometry it draws.
public enum GlyphState: Int, CaseIterable, Sendable {
    case empty, one, two, three, full
    /// No Screen Recording permission: the empty bucket struck through. Only the bar draws it (`count` never maps here).
    case slash

    /// 0 → empty · 1 · 2 · 3 → that many stripes · ≥4 → full block.
    public init(count n: Int) {
        switch n {
        case ...0: self = .empty
        case 1: self = .one
        case 2: self = .two
        case 3: self = .three
        default: self = .full
        }
    }

    /// Stripes drawn individually; `full` replaces them with one block.
    public var stripeCount: Int { self == .full || self == .slash ? 0 : rawValue }
    public var name: String { ["bucket.empty", "bucket.1", "bucket.2", "bucket.3", "bucket.full", "bucket.slash"][rawValue] }
}

private func poly(_ pts: [(CGFloat, CGFloat)]) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
    for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.0, y: q.1)) }
    p.closeSubpath()
    return p
}

/// Pixel-fitted menu bar drawings, copied from the design (not scaled from each other). Coordinates are y-down.
public struct BarGeometry {
    public let px: Int
    /// Body outline (even-odd: outer minus inner trapezoid).
    public let body: CGPath
    public let lip: CGRect
    public let handleCenter: CGPoint
    public let handleRadius: CGFloat
    public let handleWidth: CGFloat
    private let handleFrom: CGPoint
    private let handleTo: CGPoint
    private let stripeRects: [CGRect]
    private let fullBlock: CGPath
    /// `bucket.slash`: erase a wide line (blend clear), then stroke the same line with round caps.
    public let slash: (from: CGPoint, to: CGPoint, eraseWidth: CGFloat, width: CGFloat)

    /// Stripes bottom-up for a state (`stripe0` first). Empty for `empty` and `full`.
    public func stripes(_ s: GlyphState) -> [CGRect] { Array(stripeRects.prefix(s.stripeCount)) }
    public func block(_ s: GlyphState) -> CGPath? { s == .full ? fullBlock : nil }

    /// Only the two sizes the design defines: 18 px (@1x) and 36 px (@2x).
    public static func forPixels(_ px: Int) -> BarGeometry? { px == 18 ? at18 : px == 36 ? at36 : nil }

    private static func arcEnds(_ c: CGPoint, _ halfSpan: CGFloat, y: CGFloat) -> (CGPoint, CGPoint) {
        (CGPoint(x: c.x - halfSpan, y: y), CGPoint(x: c.x + halfSpan, y: y))
    }

    static let at18: BarGeometry = {
        let body = CGMutablePath()
        body.addPath(poly([(3, 7), (15, 7), (13.5, 17), (4.5, 17)]))
        body.addPath(poly([(4, 7), (14, 7), (12.5, 16), (5.5, 16)]))
        let c = CGPoint(x: 9, y: 6.525)
        let ends = arcEnds(c, 5.5, y: 6)
        return BarGeometry(px: 18, body: body, lip: CGRect(x: 1.5, y: 6, width: 15, height: 2),
                           handleCenter: c, handleRadius: 5.525, handleWidth: 1, handleFrom: ends.0, handleTo: ends.1,
                           stripeRects: [CGRect(x: 6, y: 14, width: 6, height: 1), CGRect(x: 6, y: 12, width: 6, height: 1),
                                         CGRect(x: 6, y: 10, width: 6, height: 1)],
                           fullBlock: poly([(5, 8), (13, 8), (12, 15), (6, 15)]),
                           slash: (CGPoint(x: 2.5, y: 2), CGPoint(x: 16, y: 17), 3, 1))
    }()

    // Lip width is 30 (30.5 in the original sketch was 0.25 pt off-axis).
    static let at36: BarGeometry = {
        let body = CGMutablePath()
        body.addPath(poly([(5.5, 15), (30.5, 15), (27, 34), (9, 34)]))
        body.addPath(poly([(7.5, 15), (28.5, 15), (25.5, 32), (10.5, 32)]))
        let c = CGPoint(x: 18, y: 13.222)
        let ends = arcEnds(c, 11, y: 11)
        return BarGeometry(px: 36, body: body, lip: CGRect(x: 3, y: 11, width: 30, height: 3),
                           handleCenter: c, handleRadius: 11.222, handleWidth: 2.5, handleFrom: ends.0, handleTo: ends.1,
                           stripeRects: [CGRect(x: 12, y: 28, width: 12, height: 2), CGRect(x: 12, y: 24, width: 12, height: 2),
                                         CGRect(x: 11, y: 20, width: 14, height: 2)],
                           fullBlock: poly([(10, 17), (26, 17), (23.5, 30), (12.5, 30)]),
                           slash: (CGPoint(x: 4.5, y: 3), CGPoint(x: 31.5, y: 34), 7.5, 2.5))
    }()

    /// Fills everything with the context's current fill color. Context must be y-down, 1 unit = 1 px.
    func draw(_ s: GlyphState, in ctx: CGContext) {
        ctx.addPath(body)
        ctx.fillPath(using: .evenOdd)
        ctx.addPath(CGPath(roundedRect: lip, cornerWidth: lip.height / 2, cornerHeight: lip.height / 2, transform: nil))
        ctx.fillPath()
        // SVG sweep=1 from the left end to the right end = increasing angle in y-down space, over the top.
        let a0 = atan2(handleFrom.y - handleCenter.y, handleFrom.x - handleCenter.x)
        let a1 = atan2(handleTo.y - handleCenter.y, handleTo.x - handleCenter.x)
        let arc = CGMutablePath()
        arc.addArc(center: handleCenter, radius: handleRadius, startAngle: a0, endAngle: a1, clockwise: false)
        ctx.addPath(arc)
        ctx.setLineWidth(handleWidth)
        ctx.setLineCap(.butt)
        ctx.strokePath()
        for r in stripes(s) { ctx.fill(r) }
        if let b = block(s) { ctx.addPath(b); ctx.fillPath() }
        if s == .slash {
            ctx.setLineCap(.round)
            ctx.saveGState()
            ctx.setBlendMode(.clear); ctx.setLineWidth(slash.eraseWidth)
            ctx.move(to: slash.from); ctx.addLine(to: slash.to); ctx.strokePath()
            ctx.restoreGState()
            ctx.setLineWidth(slash.width)
            ctx.move(to: slash.from); ctx.addLine(to: slash.to); ctx.strokePath()
        }
    }
}

/// Master 64 drawing (stroke) for the pill and the panel. viewBox `0 -2 64 64`, y-down.
public enum MasterGeometry {
    public static let handle: CGPath = {
        let c = CGPoint(x: 32, y: 25.33)
        let a0 = atan2(27 - c.y, 12.74 - c.x)
        var a1 = atan2(27 - c.y, 51.26 - c.x)
        if a1 < a0 { a1 += 2 * .pi }
        let p = CGMutablePath()
        p.addArc(center: c, radius: 19.33, startAngle: a0, endAngle: a1, clockwise: false)
        return p
    }()
    public static let body: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 12, y: 22))
        p.addLine(to: CGPoint(x: 16.42, y: 52.04))
        p.addQuadCurve(to: CGPoint(x: 21, y: 56), control: CGPoint(x: 17, y: 56))
        p.addLine(to: CGPoint(x: 43, y: 56))
        p.addQuadCurve(to: CGPoint(x: 47.58, y: 52.04), control: CGPoint(x: 47, y: 56))
        p.addLine(to: CGPoint(x: 52, y: 22))
        return p
    }()
    public static let lip: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 10, y: 22)); p.addLine(to: CGPoint(x: 54, y: 22))
        return p
    }()
    /// `stripe0` (bottom, first shot) first. One CGPath each so the companion can give every stripe its own layer.
    public static let stripes: [CGPath] = [
        poly([(20.36, 47.6), (43.64, 47.6), (43.11, 51.2), (20.89, 51.2)]),
        poly([(19.39, 41), (44.61, 41), (44.08, 44.6), (19.92, 44.6)]),
        poly([(18.42, 34.4), (45.58, 34.4), (45.05, 38), (18.95, 38)]),
    ]
    public static let full: CGPath = poly([(17.98, 31.4), (46.02, 31.4), (43.11, 51.2), (20.89, 51.2)])

    public static func stripes(_ s: GlyphState) -> [CGPath] { Array(stripes.prefix(s.stripeCount)) }
}

public enum Glyph {
    /// `bucket.accent`: stripes and drop of the master glyph.
    public static let accent = NSColor(name: "bucket.accent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0x5C / 255, blue: 0x9A / 255, alpha: 1)
            : NSColor(srgbRed: 0xE7 / 255, green: 0x19 / 255, blue: 0x5E / 255, alpha: 1)
    }

    // MARK: Menu bar (18 pt, two hand-fitted representations)

    /// Template image: rep @1x = drawing of 18 px, rep @2x = drawing of 36 px, both 18×18 pt.
    /// A single drawing handler would be scaled by the system and the stripes would smear.
    public static func barImage(_ state: GlyphState) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for px in [18, 36] { image.addRepresentation(barRep(state, px: px)) }
        image.isTemplate = true
        image.accessibilityDescription = "Bucket"
        return image
    }

    static func barRep(_ state: GlyphState, px: Int) -> NSBitmapImageRep {
        let geometry = BarGeometry.forPixels(px)!
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let gc = NSGraphicsContext(bitmapImageRep: rep)! // rep.size == pixels here: drawing is 1 unit = 1 px
        NSGraphicsContext.current = gc
        let ctx = gc.cgContext
        ctx.translateBy(x: 0, y: CGFloat(px))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        geometry.draw(state, in: ctx)
        gc.flushGraphics()
        rep.size = NSSize(width: 18, height: 18) // points: the pixel count now makes it 1x / 2x
        return rep
    }

    // MARK: Master 64 (pill, panel)

    /// Draws the master glyph into a y-down context whose origin is the top-left of a `size`×`size` box.
    /// Not clipped: a tilted bucket may leave the box.
    public static func drawMaster(_ state: GlyphState, in ctx: CGContext, size: CGFloat, ink: CGColor, stripe: CGColor) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.scaleBy(x: size / 64, y: size / 64)
        ctx.translateBy(x: 0, y: 2)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(1.6); ctx.addPath(MasterGeometry.handle); ctx.strokePath()
        ctx.setLineWidth(3.2); ctx.addPath(MasterGeometry.body); ctx.strokePath()
        ctx.addPath(MasterGeometry.lip); ctx.strokePath()
        ctx.setFillColor(stripe)
        for p in MasterGeometry.stripes(state) { ctx.addPath(p); ctx.fillPath() }
        if state == .full { ctx.addPath(MasterGeometry.full); ctx.fillPath() }
    }

    /// `template == true` paints everything black so the system tints it (stripe color ignored).
    public static func masterImage(_ state: GlyphState, size: CGFloat, stripe: NSColor = Glyph.accent,
                                   ink: NSColor = .labelColor, template: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawMaster(state, in: ctx, size: size,
                       ink: template ? CGColor(gray: 0, alpha: 1) : ink.cgColor,
                       stripe: template ? CGColor(gray: 0, alpha: 1) : stripe.cgColor)
            return true
        }
        image.isTemplate = template
        return image
    }
}

/// Menu bar canvas: 28×24 pt on the bar color, glyph centered and tinted as the system would.
public enum MenubarCanvas {
    public static let size = NSSize(width: 28, height: 24)

    public static func png(_ state: GlyphState, dark: Bool, scale: Int = 2) -> Data? {
        let pw = Int(size.width) * scale, ph = Int(size.height) * scale
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = size // points; NSImage.draw picks the rep that matches this scale, like the status item does
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = gc

        (dark ? NSColor(srgbRed: 0x1E / 255, green: 0x1F / 255, blue: 0x24 / 255, alpha: 1)
              : NSColor(srgbRed: 0xF6 / 255, green: 0xF6 / 255, blue: 0xF8 / 255, alpha: 1)).setFill()
        NSRect(origin: .zero, size: size).fill()

        let glyph = NSRect(x: (size.width - 18) / 2, y: (size.height - 18) / 2, width: 18, height: 18)
        gc.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
        Glyph.barImage(state).draw(in: glyph, from: .zero, operation: .sourceOver, fraction: 1)
        (dark ? NSColor(white: 1, alpha: 0.9) : NSColor(white: 0, alpha: 0.85)).setFill()
        glyph.fill(using: .sourceIn)
        gc.cgContext.endTransparencyLayer()
        gc.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }
}
