import AppKit
import BucketCore
import ImageIO

// The panel's content: a flipped view tree measured with `PanelMetrics`. It knows nothing about the
// archive: it gets a `PanelData`, draws it and reports clicks through callbacks. The same view is drawn in the live
// window (over a vibrancy view) and offscreen by `Bucket render` (with the opaque fallback).

/// What the panel shows. Built by the controller from the bucket and the library, or faked by the renders.
struct PanelData {
    struct Item { let id: String; let path: String }
    var items: [Item] = []            // the bucket, in order
    var lastBatch: [String] = []      // image paths of the last batch
    var savedIn = ""                  // "~/Bucket/2026-10-24"
    var ocrPending = 0
    var permissionError = false
    var captureSymbols = ["⌘", "⇧", "4"]
}

// MARK: Look

enum PanelColor {
    private static func dynamic(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: name) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
    /// `edge`: 0.5 pt interior contour of the panel and the thumbnails.
    static let edge = dynamic("bucket.edge", light: NSColor(white: 0, alpha: 0.10), dark: NSColor(white: 1, alpha: 0.12))
    /// Opaque stand-in of the `.popover` material for offscreen renders.
    static let material = dynamic("bucket.material", light: NSColor(srgbRed: 0xF4 / 255, green: 0xF4 / 255, blue: 0xF6 / 255, alpha: 1),
                                  dark: NSColor(srgbRed: 0x2A / 255, green: 0x2B / 255, blue: 0x30 / 255, alpha: 1))
    static let chip = NSColor(srgbRed: 1, green: 0x5C / 255, blue: 0x9A / 255, alpha: 1)          // bucket.chip
    static let chipInk = NSColor(srgbRed: 0x11 / 255, green: 0x13 / 255, blue: 0x18 / 255, alpha: 1) // bucket.chipInk
    static let scrim = NSColor(white: 0, alpha: 0.62)                                                // overlay.scrim
    static let overlayInk = NSColor.white                                                             // overlay.ink
}

enum PanelFont {
    static let title = PillFont.rounded(15, .semibold)
    static let body = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let button = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let hint = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let section = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let footer = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let path = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let order = PillFont.tabular(PillFont.rounded(11, .bold))
    static let overlay = NSFont.systemFont(ofSize: 10, weight: .medium)
    static let kbd = NSFont.systemFont(ofSize: 11, weight: .semibold)
}

/// Draws one line of text vertically centered in `rect` (the views are flipped, so this reads top-down).
@discardableResult
func drawText(_ s: String, _ font: NSFont, _ color: NSColor, in rect: CGRect, align: NSTextAlignment = .left, kern: CGFloat = 0) -> CGFloat {
    let style = NSMutableParagraphStyle()
    style.alignment = align
    style.lineBreakMode = .byTruncatingTail
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
    if kern != 0 { attrs[.kern] = kern }
    let str = NSAttributedString(string: s, attributes: attrs)
    let h = ceil(str.size().height)
    str.draw(in: CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h))
    return str.size().width
}

func textWidth(_ s: String, _ font: NSFont) -> CGFloat { PillFont.width(s, font) }

/// Aspect fill anchored to the top: the top of a capture is usually what identifies it.
func drawAspectFill(_ image: NSImage, in rect: CGRect) {
    let iw = image.size.width, ih = image.size.height
    guard iw > 0, ih > 0 else { return }
    let s = max(rect.width / iw, rect.height / ih)
    let dw = iw * s, dh = ih * s
    image.draw(in: CGRect(x: rect.minX + (rect.width - dw) / 2, y: rect.minY, width: dw, height: dh), from: .zero,
               operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
}

func fadeTransition(_ step: Motion.Step, on layer: CALayer?) {
    let t = CATransition()
    t.type = .fade
    t.duration = step.seconds
    t.timingFunction = step.curve.timing
    layer?.add(t, forKey: "fade")
}

// MARK: Thumbnails

/// Thumbnails are decoded off the main thread and kept: the panel opens with what it has and fills in the rest.
final class ThumbCache {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "studio.bast.bucket.thumbs", qos: .userInitiated, attributes: .concurrent)

    func cached(_ path: String) -> NSImage? { cache.object(forKey: path as NSString) }
    /// Offscreen renders put their drawn fillers here under a fake path.
    func seed(_ path: String, _ image: NSImage) { cache.setObject(image, forKey: path as NSString) }
    func forget(_ path: String) { cache.removeObject(forKey: path as NSString) }

    /// 2x of the grid cell (aspect fill), which also covers the mini strip.
    func load(_ path: String, completion: @escaping (NSImage?) -> Void) {
        if let hit = cached(path) { completion(hit); return }
        queue.async {
            let image = ThumbCache.decode(path)
            DispatchQueue.main.async {
                if let image { self.cache.setObject(image, forKey: path as NSString) }
                completion(image)
            }
        }
    }

    static func decode(_ path: String) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double, let h = props[kCGImagePropertyPixelHeight] as? Double,
              w > 0, h > 0 else { return nil }
        let cell = PanelMetrics.thumbSize
        let fill = max(2 * cell.width / w, 2 * cell.height / h, 0.001)
        let maxPixel = ceil(max(w, h) * min(fill, 1))
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
    }
}

// MARK: Small parts

/// Capsule on `overlay.scrim`, drawn over a thumbnail: the × and "Show in Finder".
final class ScrimButton: NSView {
    enum Kind { case remove, finder }
    let kind: Kind
    var onClick: (() -> Void)?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(_ kind: Kind) {
        self.kind = kind
        let w = kind == .remove ? 18 : textWidth(PanelCopy.showInFinder, PanelFont.overlay) + 16
        super.init(frame: CGRect(x: 0, y: 0, width: w, height: 18))
        alphaValue = 0
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        PanelColor.scrim.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        switch kind {
        case .remove:
            // Two strokes of 8 × 1.5 at ±45°.
            PanelColor.overlayInk.setStroke()
            let p = NSBezierPath()
            p.lineWidth = 1.5; p.lineCapStyle = .round
            let c = CGPoint(x: bounds.midX, y: bounds.midY), d: CGFloat = 4 / 2.0.squareRoot()
            p.move(to: CGPoint(x: c.x - d, y: c.y - d)); p.line(to: CGPoint(x: c.x + d, y: c.y + d))
            p.move(to: CGPoint(x: c.x - d, y: c.y + d)); p.line(to: CGPoint(x: c.x + d, y: c.y - d))
            p.stroke()
        case .finder:
            drawText(PanelCopy.showInFinder, PanelFont.overlay, PanelColor.overlayInk, in: bounds, align: .center)
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// One shot of the bucket: 104 × 72, radius 8, aspect fill, magenta order chip; hover brings × and "Show in Finder".
final class ThumbView: NSView {
    let id: String
    let path: String
    var image: NSImage? { didSet { needsDisplay = true } }
    /// What is drawn. `target` is where the numbering is going (it changes 420 ms after a removal).
    private(set) var number: Int
    var targetNumber: Int
    var onRemove: ((String) -> Void)?
    var onReveal: ((String) -> Void)?
    private let remove = ScrimButton(.remove), finder = ScrimButton(.finder)
    private(set) var hovering = false
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(id: String, path: String, number: Int) {
        self.id = id; self.path = path; self.number = number; self.targetNumber = number
        super.init(frame: CGRect(origin: .zero, size: PanelMetrics.thumbSize))
        wantsLayer = true
        remove.frame.origin = CGPoint(x: bounds.width - 5 - 18, y: 5)
        finder.frame.origin = CGPoint(x: (bounds.width - finder.frame.width) / 2, y: bounds.height - 5 - 18)
        remove.onClick = { [weak self] in if let s = self { s.onRemove?(s.id) } }
        finder.onClick = { [weak self] in if let s = self { s.onReveal?(s.path) } }
        addSubview(remove); addSubview(finder)
    }
    required init?(coder: NSCoder) { nil }

    func setNumber(_ n: Int, fade: Bool) {
        guard n != number else { return }
        if fade { fadeTransition(Motion.Step(0, 120, .linear), on: layer) }
        number = n
        needsDisplay = true
    }

    /// Hover is instant to decide and 120 ms (in) / 80 ms (out) to show. `animated: false` is for renders.
    func setHover(_ on: Bool, animated: Bool = true) {
        guard on != hovering else { return }
        hovering = on
        let step = on ? Motion.Panel.hoverIn : Motion.Panel.hoverOut
        let apply = { [remove, finder] in remove.animator().alphaValue = on ? 1 : 0; finder.animator().alphaValue = on ? 1 : 0 }
        if animated {
            NSAnimationContext.runAnimationGroup { c in c.duration = step.seconds; c.timingFunction = step.curve.timing; apply() }
        } else { remove.alphaValue = on ? 1 : 0; finder.alphaValue = on ? 1 : 0 }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    /// The overlays only take clicks while they are visible.
    override func hitTest(_ point: NSPoint) -> NSView? { hovering ? super.hitTest(point) : (frame.contains(point) ? self : nil) }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        let rm = NSMenuItem(title: PanelCopy.remove, action: #selector(removeClicked), keyEquivalent: "")
        let rv = NSMenuItem(title: PanelCopy.showInFinder, action: #selector(revealClicked), keyEquivalent: "")
        rm.target = self; rv.target = self
        m.addItem(rm); m.addItem(rv)
        return m
    }
    @objc private func removeClicked() { onRemove?(id) }
    @objc private func revealClicked() { onReveal?(path) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).addClip()
        if let image { drawAspectFill(image, in: r) } else { NSColor.quaternarySystemFill.setFill(); r.fill() }
        NSGraphicsContext.restoreGraphicsState()

        // Order chip: the same magenta as `[Image #N]` in the terminal.
        let n = "\(number)"
        let w = max(18, textWidth(n, PanelFont.order) + 10)
        let chip = CGRect(x: 5, y: 5, width: w, height: 18)
        PanelColor.chip.setFill()
        NSBezierPath(roundedRect: chip, xRadius: 9, yRadius: 9).fill()
        drawText(n, PanelFont.order, PanelColor.chipInk, in: chip, align: .center)

        PanelColor.edge.setStroke()
        let edge = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: 7.75, yRadius: 7.75)
        edge.lineWidth = 0.5
        edge.stroke()
    }
}

/// Capsule button (24 high, radius 12): "Copy now", "Re-copy ⌥⇧V", "Open Settings…".
final class PillButton: NSView {
    private(set) var title: String
    private let hint: String?
    var onClick: (() -> Void)?
    private var pressed = false
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(_ title: String, hint: String? = nil) {
        self.title = title; self.hint = hint
        super.init(frame: .zero)
        wantsLayer = true
        sizeToContent(minTitle: title)
    }
    required init?(coder: NSCoder) { nil }

    /// Width follows the widest label it will show, so "Copy now" → "Copied" does not move the button.
    private func sizeToContent(minTitle: String) {
        var w = 20 + max(textWidth(title, PanelFont.button), textWidth(PanelCopy.copied, PanelFont.button), textWidth(minTitle, PanelFont.button))
        if let hint { w += 6 + textWidth(hint, PanelFont.hint) }
        frame.size = CGSize(width: ceil(w), height: 24)
    }

    func setTitle(_ t: String, animated: Bool) {
        guard t != title else { return }
        if animated { fadeTransition(Motion.Step(0, Motion.Panel.copied.fade, .linear), on: layer) }
        title = t
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        (pressed ? NSColor.tertiarySystemFill : NSColor.quaternarySystemFill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        var x: CGFloat = 10
        if let hint {
            let tw = textWidth(title, PanelFont.button)
            let hw = textWidth(hint, PanelFont.hint)
            let total = tw + 6 + hw
            x = (bounds.width - total) / 2
            drawText(title, PanelFont.button, .labelColor, in: CGRect(x: x, y: 0, width: tw + 2, height: 24))
            drawText(hint, PanelFont.hint, .secondaryLabelColor, in: CGRect(x: x + tw + 6, y: 0, width: hw + 2, height: 24))
        } else {
            drawText(title, PanelFont.button, .labelColor, in: bounds, align: .center)
        }
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true; needsDisplay = true
        // Track until the button goes up: a click counts only if it ends inside.
        while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if e.type == .leftMouseUp {
                pressed = false; needsDisplay = true
                if bounds.contains(convert(e.locationInWindow, from: nil)) { onClick?() }
                return
            }
        }
    }
}

/// A row of the actions block: 28 high, radius 6. Hover = `fill.control` instantly, like a menu. Disabled = no hover, no click.
final class ActionRow: NSView {
    let title: String
    let hint: String?
    var isEnabled = true { didSet { needsDisplay = true } }
    var forcedHover = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(_ title: String, hint: String? = nil) { self.title = title; self.hint = hint; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (hovering || forcedHover) {
            NSColor.quaternarySystemFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        drawText(title, PanelFont.body, isEnabled ? .labelColor : .tertiaryLabelColor, in: bounds.insetBy(dx: 10, dy: 0))
        if let hint { // right edge lines up with the ⌥⇧V hint on Re-copy
            let hw = textWidth(hint, PanelFont.hint)
            drawText(hint, PanelFont.hint, isEnabled ? .secondaryLabelColor : .tertiaryLabelColor,
                     in: CGRect(x: bounds.width - 16 - hw, y: 0, width: hw + 2, height: bounds.height))
        }
    }
    override func mouseDown(with event: NSEvent) { if isEnabled { onClick?() } }
}

/// Hairline of the panel (0.5 pt `separator`) inside a 1 pt box, inset 16 at each side.
final class SeparatorView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        CGRect(x: PanelMetrics.gridInset, y: 0.25, width: bounds.width - 2 * PanelMetrics.gridInset, height: 0.5).fill()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The 0.5 pt `edge` contour of the whole panel, on top of everything.
private final class EdgeView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        PanelColor.edge.setStroke()
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 15.75, yRadius: 15.75)
        p.lineWidth = 0.5
        p.stroke()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Gear in the footer: opens the status-item menu (the one place settings live). 28 pt hit area, SF Symbol `gearshape`.
final class GearButton: NSView {
    static let side: CGFloat = 28
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: GearButton.side, height: GearButton.side))
        toolTip = "Settings"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Settings")
    }
    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        guard let symbol = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) else { return }
        let color: NSColor = hovering ? .labelColor : .secondaryLabelColor
        let tinted = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r); color.set(); r.fill(using: .sourceIn); return true
        }
        tinted.draw(in: CGRect(x: (bounds.width - symbol.size.width) / 2, y: (bounds.height - symbol.size.height) / 2,
                               width: symbol.size.width, height: symbol.size.height))
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: Sections

private final class HeaderView: NSView {
    var count = 0 { didSet { needsDisplay = true } }
    let copyNow = PillButton(PanelCopy.copyNow)
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(copyNow)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        copyNow.isHidden = count == 0
        copyNow.frame.origin = CGPoint(x: bounds.width - 12 - copyNow.frame.width, y: (bounds.height - 24) / 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        Glyph.masterImage(GlyphState(count: count), size: 24).draw(in: CGRect(x: 14, y: 14, width: 24, height: 24))
        drawText(PanelCopy.title(count), PanelFont.title, .labelColor, in: CGRect(x: 46, y: 0, width: bounds.width - 46 - 12 - (count == 0 ? 0 : copyNow.frame.width + 8), height: bounds.height), kern: -0.15)
    }
}

/// The permission problem sits between the header and the grid. The dot tints the state, not the row.
private final class PermissionRow: NSView {
    let openSettings = PillButton(CompanionCopy.openSettings)
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); addSubview(openSettings) }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        openSettings.frame.origin = CGPoint(x: bounds.width - 16 - openSettings.frame.width, y: (bounds.height - 24) / 2)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: CGRect(x: 16, y: bounds.midY - 3, width: 6, height: 6)).fill()
        drawText(CompanionCopy.permissionNeeded, PanelFont.body, .labelColor, in: CGRect(x: 30, y: 0, width: 200, height: bounds.height))
    }
}

/// Replaces the grid with the empty bucket glyph and "⌘ ⇧ 4 to capture".
private final class EmptyBlock: NSView {
    var symbols = ["⌘", "⇧", "4"] { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        // Content area is the block minus the 16 pt below it: 48 + 12 + 18 centered in 120.
        let top = (bounds.height - 16 - (48 + 12 + 18)) / 2
        // Opaque ink composited at the tertiary alpha: stroking with the translucent color would darken where strokes overlap.
        Glyph.masterImage(.empty, size: 48, ink: .labelColor).draw(in: CGRect(x: (bounds.width - 48) / 2, y: top, width: 48, height: 48),
                                                                     from: .zero, operation: .sourceOver, fraction: 0.26, respectFlipped: true, hints: nil)
        let label = PanelCopy.emptyHint
        let lw = textWidth(label, PanelFont.body)
        let total = CGFloat(symbols.count) * 18 + CGFloat(symbols.count) * 6 + lw
        var x = (bounds.width - total) / 2
        let y = top + 48 + 12
        for s in symbols {
            let r = CGRect(x: x, y: y, width: 18, height: 18)
            NSColor.quaternarySystemFill.setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            drawText(s, PanelFont.kbd, .labelColor, in: r, align: .center)
            x += 24
        }
        drawText(label, PanelFont.body, .secondaryLabelColor, in: CGRect(x: x, y: y, width: lw + 4, height: 18))
    }
}

private final class LastBatchView: NSView {
    var paths: [String] = [] { didSet { load(); needsDisplay = true } }
    let recopy = PillButton(PanelCopy.recopy, hint: PanelCopy.recopyHint)
    override var isFlipped: Bool { true }
    private var images: [String: NSImage] = [:]

    override init(frame: NSRect) { super.init(frame: frame); addSubview(recopy) }
    required init?(coder: NSCoder) { nil }

    private func load() {
        for p in paths.prefix(PanelMetrics.maxMinis) {
            ThumbCache.shared.load(p) { [weak self] img in
                guard let self, let img else { return }
                self.images[p] = img
                self.needsDisplay = true
            }
        }
    }

    override func layout() {
        super.layout()
        recopy.frame.origin = CGPoint(x: bounds.width - 12 - recopy.frame.width, y: (bounds.height - 24) / 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawText(PanelCopy.lastBatch(paths.count), PanelFont.section, .secondaryLabelColor, in: CGRect(x: 16, y: 12, width: 180, height: 14))
        var x: CGFloat = 16
        let size = PanelMetrics.miniSize
        for p in paths.prefix(PanelMetrics.maxMinis) {
            let r = CGRect(x: x, y: 32, width: size.width, height: size.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).addClip()
            if let img = images[p] ?? ThumbCache.shared.cached(p) { drawAspectFill(img, in: r) } else { NSColor.quaternarySystemFill.setFill(); r.fill() }
            NSGraphicsContext.restoreGraphicsState()
            PanelColor.edge.setStroke()
            let e = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: 3.75, yRadius: 3.75)
            e.lineWidth = 0.5; e.stroke()
            x += size.width + 4
        }
        if paths.count > PanelMetrics.maxMinis {
            drawText("+\(paths.count - PanelMetrics.maxMinis)", PanelFont.section, .secondaryLabelColor, in: CGRect(x: x + 2, y: 32, width: 40, height: size.height))
        }
    }
}

private final class ActionsView: NSView {
    let sendLast = ActionRow(PanelCopy.sendLast), clear = ActionRow(PanelCopy.clear, hint: PanelCopy.clearHint)
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(sendLast); addSubview(clear)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        sendLast.frame = CGRect(x: 6, y: 6, width: bounds.width - 12, height: 28)
        clear.frame = CGRect(x: 6, y: 34, width: bounds.width - 12, height: 28)
    }
}

/// "Saved in ~/Bucket/2026-10-24" (click = open that folder) and the OCR state, alive.
private final class FooterView: NSView {
    var savedIn = "" { didSet { needsDisplay = true } }
    var onOpenFolder: (() -> Void)?
    let gear = GearButton()
    /// Right edge of the OCR text: the gear sits to its right (12 pt from the panel edge).
    private var textEdge: CGFloat { bounds.width - 12 - GearButton.side - 4 }
    private(set) var pending = 0
    private var flash: String?
    private let spinner = NSProgressIndicator()
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        addSubview(spinner)
        addSubview(gear)
    }
    required init?(coder: NSCoder) { nil }

    private var rightText: String { flash ?? PanelCopy.ocr(pending: pending, enabled: OCRSetting.enabled) }
    private var reading: Bool { flash == nil && pending > 0 && OCRSetting.enabled }

    func setOCR(pending n: Int, animated: Bool) {
        guard n != pending else { return }
        let toggled = (n > 0) != (pending > 0)
        pending = n
        if toggled && animated && flash == nil { fadeTransition(Motion.Panel.ocrFade, on: layer) }
        sync()
    }

    /// "Sent to Desktop" in place of the OCR state for 1500 ms, with 120 ms crossfades.
    func flash(_ text: String) {
        fadeTransition(Motion.Step(0, Motion.Panel.sentFade, .linear), on: layer)
        flash = text; sync()
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.Panel.sentFlash / 1000) { [weak self] in
            guard let self, self.flash == text else { return }
            fadeTransition(Motion.Step(0, Motion.Panel.sentFade, .linear), on: self.layer)
            self.flash = nil; self.sync()
        }
    }

    /// The switch can change while the panel is closed: re-read it when the panel opens.
    func refreshOCRState() { sync() }

    private func sync() {
        if reading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        needsLayout = true; needsDisplay = true
    }

    private var pathRect: CGRect {
        let w = textWidth("Saved in ", PanelFont.footer) + textWidth(savedIn, PanelFont.path)
        return CGRect(x: 16, y: 0, width: min(w + 2, bounds.width - 32 - 120 - GearButton.side), height: bounds.height)
    }

    override func layout() {
        super.layout()
        let w = textWidth(rightText, PanelFont.footer)
        gear.frame.origin = CGPoint(x: bounds.width - 12 - GearButton.side, y: (bounds.height - GearButton.side) / 2)
        spinner.frame.origin = CGPoint(x: textEdge - w - 6 - 10, y: (bounds.height - 10) / 2)
    }

    override func resetCursorRects() { addCursorRect(pathRect, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {
        if pathRect.contains(convert(event.locationInWindow, from: nil)) { onOpenFolder?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
        let lead = "Saved in "
        let lw = textWidth(lead, PanelFont.footer)
        drawText(lead, PanelFont.footer, .secondaryLabelColor, in: CGRect(x: 16, y: 0, width: lw + 2, height: bounds.height))
        drawText(savedIn, PanelFont.path, .labelColor, in: CGRect(x: 16 + lw, y: 0, width: pathRect.width - lw, height: bounds.height))
        let rw = textWidth(rightText, PanelFont.footer)
        drawText(rightText, PanelFont.footer, .secondaryLabelColor, in: CGRect(x: textEdge - rw - 2, y: 0, width: rw + 4, height: bounds.height), align: .right)
    }
}

private final class GridScroll: NSScrollView {
    override var isFlipped: Bool { true }
}

private final class GridDoc: NSView {
    override var isFlipped: Bool { true }
}

// MARK: The panel

final class PanelView: NSView {
    // Callbacks the controller fills in.
    var onCopyNow: () -> Void = {}
    var onRecopy: () -> Void = {}
    var onSendLast: () -> Void = {}
    var onClear: () -> Void = {}
    var onRemove: (String) -> Void = { _ in }
    var onReveal: (String) -> Void = { _ in }
    var onOpenFolder: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    /// The gear: the view and the point (in it) where the settings menu should open.
    var onOpenMenu: (NSView, NSPoint) -> Void = { _, _ in }
    var onEscape: () -> Void = {}
    /// The height changed (the number of rows, the last batch, the permission row): the window follows.
    var onResize: (CGFloat) -> Void = { _ in }

    /// Renders draw the opaque material themselves; the live window has vibrancy behind this view.
    var opaqueMaterial = false
    /// Renders force the states that need a pointer.
    var forcedHoverIndex: Int?
    var forcedActionHover = false

    private(set) var data = PanelData()
    private let header = HeaderView(), permission = PermissionRow(), emptyBlock = EmptyBlock()
    private let sep1 = SeparatorView(), lastBatch = LastBatchView(), sep2 = SeparatorView()
    private let actions = ActionsView(), footer = FooterView(), edge = EdgeView()
    private let scroll = GridScroll(), doc = GridDoc()
    private var thumbs: [String: ThumbView] = [:]
    private var reflowToken = 0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = doc
        for v in [header, permission, emptyBlock, scroll, sep1, lastBatch, sep2, actions, footer, edge] { addSubview(v) }
        header.copyNow.onClick = { [weak self] in self?.onCopyNow() }
        permission.openSettings.onClick = { [weak self] in self?.onOpenSettings() }
        lastBatch.recopy.onClick = { [weak self] in self?.onRecopy() }
        actions.sendLast.onClick = { [weak self] in self?.onSendLast() }
        actions.clear.onClick = { [weak self] in self?.onClear() }
        footer.onOpenFolder = { [weak self] in self?.onOpenFolder() }
        footer.gear.onClick = { [weak self] in
            guard let self else { return }
            self.onOpenMenu(self.footer.gear, CGPoint(x: self.footer.gear.bounds.minX, y: self.footer.gear.bounds.minY))
        }
    }
    required init?(coder: NSCoder) { nil }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape() } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard opaqueMaterial else { return }
        PanelColor.material.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).fill()
    }

    // MARK: Data

    func reload(_ new: PanelData, animated: Bool) {
        data = new
        let ids = Set(new.items.map(\.id))
        let removed = thumbs.keys.filter { !ids.contains($0) }
        let reflow = animated && !removed.isEmpty && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // Leaving thumbnails: opacity 1→0 and scale 1→.96 in 200 (inQuart), then they are gone from the view tree only.
        for id in removed {
            guard let tv = thumbs.removeValue(forKey: id) else { continue }
            if reflow { dismiss(tv) } else { tv.removeFromSuperview() }
        }

        var moves: [(ThumbView, CGRect)] = []
        for (i, item) in new.items.enumerated() {
            let tv: ThumbView
            if let existing = thumbs[item.id] { tv = existing } else {
                tv = ThumbView(id: item.id, path: item.path, number: i + 1)
                tv.onRemove = { [weak self] id in self?.onRemove(id) }
                tv.onReveal = { [weak self] p in self?.onReveal(p) }
                doc.addSubview(tv)
                thumbs[item.id] = tv
                if let hit = ThumbCache.shared.cached(item.path) { tv.image = hit }
                else { ThumbCache.shared.load(item.path) { [weak tv] img in tv?.image = img } }
                tv.frame = PanelMetrics.cell(i)
            }
            tv.targetNumber = i + 1
            let target = PanelMetrics.cell(i)
            if reflow { moves.append((tv, target)) } else { tv.frame = target; tv.setNumber(i + 1, fade: false) }
        }
        if let k = forcedHoverIndex, k < new.items.count { thumbs[new.items[k].id]?.setHover(true, animated: false) }

        if reflow {
            // After the leaving one is gone: the others glide to their new cell (220, outStrong), then renumber (crossfade 120 at 420).
            reflowToken += 1
            let token = reflowToken
            let step = Motion.Panel.reflow
            DispatchQueue.main.asyncAfter(deadline: .now() + step.delay) { [weak self] in
                guard let self, self.reflowToken == token else { return }
                NSAnimationContext.runAnimationGroup { c in
                    c.duration = step.seconds; c.timingFunction = step.curve.timing
                    for (tv, target) in moves { tv.animator().frame = target }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + step.end / 1000) { [weak self] in
                guard let self, self.reflowToken == token else { return }
                for (tv, _) in moves { tv.setNumber(tv.targetNumber, fade: true) }
            }
        } else { reflowToken += 1 }

        header.count = new.items.count
        permission.isHidden = !new.permissionError
        lastBatch.paths = new.lastBatch
        emptyBlock.symbols = new.captureSymbols
        footer.savedIn = new.savedIn
        footer.setOCR(pending: new.ocrPending, animated: animated)
        footer.refreshOCRState()
        let has = !new.items.isEmpty
        actions.sendLast.isEnabled = has
        actions.clear.isEnabled = has
        actions.sendLast.forcedHover = forcedActionHover
        layoutSections()
    }

    func setOCR(pending: Int) {
        data.ocrPending = pending
        footer.setOCR(pending: pending, animated: true)
    }

    func flashFooter(_ text: String) { footer.flash(text) }

    /// "Copy now" / "Re-copy" confirm with "Copied" for 1200 ms.
    func confirmCopy(on button: PillButton) {
        button.setTitle(PanelCopy.copied, animated: true)
        let original = button === header.copyNow ? PanelCopy.copyNow : PanelCopy.recopy
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.Panel.copied.hold / 1000) { button.setTitle(original, animated: true) }
    }
    var copyNowButton: PillButton { header.copyNow }
    var recopyButton: PillButton { lastBatch.recopy }

    private func dismiss(_ tv: ThumbView) {
        guard let layer = tv.layer else { tv.removeFromSuperview(); return }
        let step = Motion.Panel.removeOut
        let to = CGFloat(Motion.Panel.removeScaleTo)
        layer.opacity = 0
        layer.setAffineTransform(CGAffineTransform(scaleX: to, y: to)) // about the layer's center
        layer.add(Anim.basic("transform.scale", from: 1, to: Motion.Panel.removeScaleTo, step, base: Anim.now), forKey: "scale")
        layer.add(Anim.basic("opacity", from: 1, to: 0, step, base: Anim.now), forKey: "out")
        DispatchQueue.main.asyncAfter(deadline: .now() + step.seconds) { tv.removeFromSuperview() }
    }

    // MARK: Layout

    /// Stacks the sections top-down with the fixed heights and tells the window the new total.
    private func layoutSections() {
        let w = PanelMetrics.width
        let n = data.items.count
        var y: CGFloat = 0
        func place(_ v: NSView, _ h: CGFloat) { v.frame = CGRect(x: 0, y: y, width: w, height: h); y += h }

        place(header, PanelMetrics.header)
        if data.permissionError { place(permission, PanelMetrics.permissionRow) }
        if n == 0 {
            scroll.isHidden = true; emptyBlock.isHidden = false
            place(emptyBlock, PanelMetrics.emptyBlock)
        } else {
            emptyBlock.isHidden = true; scroll.isHidden = false
            place(scroll, PanelMetrics.gridHeight(shots: n))
            doc.frame = CGRect(x: 0, y: 0, width: w, height: PanelMetrics.gridContentHeight(shots: n))
            scroll.hasVerticalScroller = PanelMetrics.scrolls(shots: n)
            scroll.verticalScrollElasticity = PanelMetrics.scrolls(shots: n) ? .automatic : .none
        }
        let hasLast = !data.lastBatch.isEmpty
        sep1.isHidden = !hasLast; lastBatch.isHidden = !hasLast
        if hasLast { place(sep1, PanelMetrics.separator); place(lastBatch, PanelMetrics.lastBatch) }
        place(sep2, PanelMetrics.separator)
        place(actions, PanelMetrics.actions)
        place(footer, PanelMetrics.footer)
        setFrameSize(CGSize(width: w, height: y))
        edge.frame = bounds
        needsDisplay = true
        onResize(y)
    }
}
