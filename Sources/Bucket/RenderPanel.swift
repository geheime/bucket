import AppKit
import BucketCore

/// Offscreen panel states: the live `PanelView` over the opaque material fallback, with filler thumbnails
/// drawn like the design. Hover and the OCR spinner are forced where the design shows them.
enum PanelRender {
    static let states: [String: () -> NSView] = [
        "panel-empty": { make(.empty) },
        "panel-3": { make(.three) },
        "panel-error": { make(.error) },
        "panel-10": { make(.ten) },
    ]

    enum Kind { case empty, three, error, ten }

    static func make(_ kind: Kind) -> NSView {
        seedFillers()
        var data = PanelData(savedIn: "~/Bucket/2026-10-24")
        let view = PanelView(frame: CGRect(x: 0, y: 0, width: PanelMetrics.width, height: 360))
        view.opaqueMaterial = true
        switch kind {
        case .empty:
            data.lastBatch = ["fake:code", "fake:web", "fake:term"]
        case .three:
            data.items = [.init(id: "a", path: "fake:code"), .init(id: "b", path: "fake:web"), .init(id: "c", path: "fake:term")]
            data.lastBatch = ["fake:ui", "fake:web"]
            data.ocrPending = 2
            view.forcedHoverIndex = 1       // hover on #2: × and "Show in Finder"
            view.forcedActionHover = true   // "Send last to Desktop" under the pointer
        case .ten: // 10 shots: the grid scrolls inside its 3 rows
            let fillers = ["fake:code", "fake:web", "fake:term", "fake:ui"]
            data.items = (0 ..< 10).map { .init(id: "s\($0)", path: fillers[$0 % 4]) }
            data.lastBatch = ["fake:ui", "fake:web"]
        case .error:
            data.items = [.init(id: "a", path: "fake:code"), .init(id: "b", path: "fake:web"), .init(id: "c", path: "fake:term")]
            data.lastBatch = ["fake:ui", "fake:web"]
            data.permissionError = true
        }
        view.reload(data, animated: false)
        return view
    }

    // MARK: Fillers (104 × 72)

    private static var seeded = false
    private static func seedFillers() {
        guard !seeded else { return }
        seeded = true
        ThumbCache.shared.seed("fake:code", shot(code))
        ThumbCache.shared.seed("fake:web", shot(web))
        ThumbCache.shared.seed("fake:term", shot(term))
        ThumbCache.shared.seed("fake:ui", shot(ui))
    }

    /// A 104 × 72 pt image drawn y-down like CSS.
    private static func shot(_ draw: @escaping (CGContext) -> Void) -> NSImage {
        NSImage(size: PanelMetrics.thumbSize, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(ctx)
            return true
        }
    }

    private static func hex(_ v: Int, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }
    private static func bar(_ ctx: CGContext, x: CGFloat, y: CGFloat, w: CGFloat, color: CGColor) {
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: 3), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
        ctx.fillPath()
    }

    private static func code(_ ctx: CGContext) {
        ctx.setFillColor(hex(0x1E2027)); ctx.fill(CGRect(x: 0, y: 0, width: 104, height: 72))
        for (c, t, w) in [(0xC678DD, 12, 30), (0x61AFEF, 20, 52), (0x98C379, 28, 40), (0xE5C07B, 36, 58), (0xABB2BF, 44, 34), (0x61AFEF, 52, 46), (0xABB2BF, 60, 24)] {
            bar(ctx, x: 8, y: CGFloat(t), w: 104 * CGFloat(w) / 100, color: hex(c, 0.8))
        }
    }

    private static func web(_ ctx: CGContext) {
        ctx.setFillColor(hex(0xFAFAFB)); ctx.fill(CGRect(x: 0, y: 0, width: 104, height: 72))
        ctx.setFillColor(hex(0xECEDF0)); ctx.fill(CGRect(x: 0, y: 0, width: 104, height: 10))
        let hero = CGRect(x: 8, y: 16, width: 104 * 0.4, height: 72 * 0.44)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: hero, cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.clip()
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [hex(0x9FB4D8), hex(0x5D74A8), hex(0x2E3E66)] as CFArray, locations: [0, 0.6, 1])!
        ctx.drawLinearGradient(g, start: hero.origin, end: CGPoint(x: hero.maxX, y: hero.maxY), options: [])
        ctx.restoreGState()
        for (t, w) in [(18, 38), (26, 30), (34, 34), (42, 22)] {
            let ww = 104 * CGFloat(w) / 100
            bar(ctx, x: 104 - 8 - ww, y: CGFloat(t), w: ww, color: hex(0xD9DCE1))
        }
    }

    private static func term(_ ctx: CGContext) {
        ctx.setFillColor(hex(0x0E1013)); ctx.fill(CGRect(x: 0, y: 0, width: 104, height: 72))
        for (t, w, c) in [(8, 40, 0x7CC77C), (16, 62, 0x5E636B), (24, 54, 0x5E636B), (32, 30, 0xE06C75), (40, 48, 0x5E636B), (48, 20, 0x7CC77C)] {
            bar(ctx, x: 7, y: CGFloat(t), w: 104 * CGFloat(w) / 100, color: hex(c))
        }
    }

    private static func ui(_ ctx: CGContext) {
        ctx.setFillColor(hex(0xF2F3F5)); ctx.fill(CGRect(x: 0, y: 0, width: 104, height: 72))
        let card = CGRect(x: 20, y: 10, width: 64, height: 52)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: hex(0x000000, 0.12))
        ctx.setFillColor(hex(0xFFFFFF))
        ctx.addPath(CGPath(roundedRect: card, cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.fillPath()
        ctx.restoreGState()
        for (t, w) in [(8, 50), (15, 70), (22, 40)] { bar(ctx, x: card.minX + 8, y: card.minY + CGFloat(t), w: card.width * CGFloat(w) / 100, color: hex(0xC9CDD3)) }
        ctx.setFillColor(hex(0x2E6BE6))
        ctx.addPath(CGPath(roundedRect: CGRect(x: card.maxX - 8 - 24, y: card.maxY - 8 - 7, width: 24, height: 7), cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)); ctx.fillPath()
    }
}
