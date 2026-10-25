import AppKit
import BucketCore
import QuartzCore

/// The glyph as a bitmap, for the layers that travel between the pill and the bar.
enum GlyphBitmap {
    static func image(_ g: GlyphState, size: CGFloat, palette: PillPalette, scale: Int = 2) -> CGImage? {
        let px = Int(size) * scale
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        ctx.translateBy(x: 0, y: size)
        ctx.scaleBy(x: 1, y: -1)       // drawMaster is y-down
        Glyph.drawMaster(g, in: ctx, size: size, ink: palette.ink, stripe: palette.accent)
        return ctx.makeImage()
    }
}

/// Flight to the bar: a temporary transparent window over the screens where the glyph of the pill travels
/// to (or from) the status item. The window is the only thing that can draw outside the companion canvas.
final class BarFlight {
    private var panel: BucketPanel?
    private var closing: DispatchWorkItem?
    /// `companion-check`: no window ever opens.
    var headless = false
    /// `companion-check`: how many flights were asked for (counted even when headless, where no window opens).
    static var launches = 0

    init() { BucketWindows.register { [weak self] in self?.cancel() } }

    /// Screen coordinates (y up). `from`/`to` are the glyph centers; sizes are the glyph's side in pt.
    func fly(_ glyph: GlyphState, palette: PillPalette, from: CGPoint, fromSize: CGFloat, to: CGPoint, toSize: CGFloat,
             step: Motion.Step, base: CFTimeInterval) {
        cancel()
        BarFlight.launches += 1
        guard !headless else { return }
        let frame = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        guard !frame.isNull, let img = GlyphBitmap.image(glyph, size: PillRig.expandedGlyph, palette: palette) else { return }
        let panel = BucketPanel(size: frame.size)
        panel.setFrame(frame, display: false)
        let host = NSView(frame: CGRect(origin: .zero, size: frame.size))
        host.wantsLayer = true
        let l = CALayer()
        let side = PillRig.expandedGlyph
        l.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        l.contents = img
        l.contentsScale = 2
        host.layer?.addSublayer(l)
        panel.contentView = host
        self.panel = panel

        func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - frame.minX, y: p.y - frame.minY) }
        l.position = local(to)
        l.setAffineTransform(CGAffineTransform(scaleX: toSize / side, y: toSize / side))
        l.add(Anim.basic("position", from: NSValue(point: local(from)), to: NSValue(point: local(to)), step, base: base), forKey: "p")
        l.add(Anim.basic("transform.scale", from: fromSize / side, to: toSize / side, step, base: base), forKey: "s")
        panel.orderFrontRegardless()
        let w = DispatchWorkItem { [weak self] in self?.cancel() }
        closing = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, base - Anim.now) + step.seconds + 0.08, execute: w)
    }

    func cancel() {
        closing?.cancel(); closing = nil
        panel?.contentView?.layer?.sublayers?.forEach { $0.removeAllAnimations() }
        panel?.orderOut(nil)
        panel = nil
    }
}
