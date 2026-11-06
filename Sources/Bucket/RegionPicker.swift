import AppKit
import BucketCore

/// What the region picker draws (state A of the mock): a light scrim over the screen, the selection cut out of it with a
/// 1.5 pt `bucket.accent` border, and the size in a neutral capsule. Shared by the live overlay and `Bucket render`.
/// Coordinates are the view's own (y up).
final class RegionCanvas: NSView {
    var selection: CGRect? { didSet { needsDisplay = true } }
    /// Before anything is dragged the capsule follows the cursor and says what a click does.
    /// The live scrim during a recording draws only the dimming: the dashed frame is its own window, above it.
    var showsBorder = true
    var cursor: CGPoint? { didSet { needsDisplay = true } }
    static let clickHint = "Click for full screen"
    /// Opaque material stand-in for the capsule (the overlay is a plain window, no blur).
    static let scrimAlpha: CGFloat = 0.28
    static let border: CGFloat = 1.5

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let scrim = NSBezierPath(rect: bounds)
        if let s = selection { scrim.append(NSBezierPath(rect: s)); scrim.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(RegionCanvas.scrimAlpha).setFill()
        scrim.fill()
        guard showsBorder else { return }
        guard let s = selection, s.width > 0, s.height > 0 else {
            if let c = cursor { capsule(RegionCanvas.clickHint, near: c) }
            return
        }

        Glyph.accent.setStroke()
        let line = NSBezierPath(rect: s.insetBy(dx: -RegionCanvas.border / 2, dy: -RegionCanvas.border / 2)) // the border sits outside the selection
        line.lineWidth = RegionCanvas.border
        line.stroke()

        // Live measures, in points. Under the selection on the right; inside it when there is no room below.
        let text = "\(Int(s.width.rounded())) × \(Int(s.height.rounded()))"
        let w = PillFont.width(text, RegionCanvas.capsuleFont) + 16, h: CGFloat = 20
        var cap = CGRect(x: s.maxX - w, y: s.minY - 8 - h, width: w, height: h)
        if cap.minY < bounds.minY + 4 { cap.origin.y = s.minY + 8 }
        cap.origin.x = min(max(cap.minX, bounds.minX + 4), bounds.maxX - w - 4)
        drawCapsule(text, in: cap)
    }

    static let capsuleFont = PillFont.tabular(PillFont.rounded(11, .semibold))

    /// The neutral capsule next to the cursor (below and to the right; flipped to the other side at the edges).
    private func capsule(_ text: String, near c: CGPoint) {
        let w = PillFont.width(text, RegionCanvas.capsuleFont) + 16, h: CGFloat = 20
        var cap = CGRect(x: c.x + 16, y: c.y - 16 - h, width: w, height: h)
        if cap.maxX > bounds.maxX - 4 { cap.origin.x = c.x - 16 - w }
        if cap.minY < bounds.minY + 4 { cap.origin.y = c.y + 16 }
        drawCapsule(text, in: cap)
    }

    private func drawCapsule(_ text: String, in cap: CGRect) {
        let font = RegionCanvas.capsuleFont, h = cap.height
        PanelColor.material.setFill()
        NSBezierPath(roundedRect: cap, xRadius: h / 2, yRadius: h / 2).fill()
        PanelColor.edge.setStroke()
        let edge = NSBezierPath(roundedRect: cap.insetBy(dx: 0.25, dy: 0.25), xRadius: h / 2 - 0.25, yRadius: h / 2 - 0.25)
        edge.lineWidth = 0.5
        edge.stroke()
        let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let sz = str.size()
        str.draw(at: CGPoint(x: cap.midX - sz.width / 2, y: cap.midY - sz.height / 2))
    }
}

/// The region picker: one window over the screen the cursor is on. Drag to choose; a click without a drag takes the whole
/// screen; Esc or a right click cancels. The window is out of the way (ordered out) BEFORE `done` is called.
final class RegionPicker {
    private var panel: PickerPanel?
    private var previousApp: NSRunningApplication?

    var isShown: Bool { panel != nil }

    /// `done` gets the region in AppKit global coordinates (y up) and its screen, or nil if cancelled.
    func begin(done: @escaping (CGRect?, NSScreen?) -> Void) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        previousApp = NSWorkspace.shared.frontmostApplication.flatMap { $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0 }

        let panel = PickerPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = Recordable.sharingType
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = PickerView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.canvas.cursor = CGPoint(x: mouse.x - screen.frame.minX, y: mouse.y - screen.frame.minY)
        view.onFinish = { [weak self] rect in
            self?.close()
            done(rect.map { $0.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) }, rect == nil ? nil : screen)
        }
        panel.contentView = view
        panel.setFrame(screen.frame, display: false)
        self.panel = panel
        // Esc needs a key window: Bucket takes focus for the length of the pick and gives it back (`close`).
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        NSCursor.crosshair.push()
    }

    /// Ordered out for good, focus back to the app the user was in.
    func close() {
        guard panel != nil else { return }
        NSCursor.pop()
        panel?.orderOut(nil)
        panel = nil
        previousApp?.activate()
        previousApp = nil
    }
}

private final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class PickerView: NSView {
    let canvas = RegionCanvas()
    private var anchor: CGPoint?
    var onFinish: ((CGRect?) -> Void)?
    private var finished = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        canvas.frame = bounds
        canvas.autoresizingMask = [.width, .height]
        addSubview(canvas)
    }
    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) { canvas.cursor = convert(event.locationInWindow, from: nil) }

    private func finish(_ rect: CGRect?) {
        guard !finished else { return }
        finished = true
        onFinish?(rect)
    }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        canvas.selection = nil
    }
    override func mouseDragged(with event: NSEvent) {
        guard let a = anchor else { return }
        let p = convert(event.locationInWindow, from: nil)
        canvas.cursor = p
        let r = RecordingRegion.rect(from: a, to: p).intersection(bounds)
        canvas.selection = r.isNull || RecordingRegion.isClick(r) ? nil : r // still a click: the capsule keeps its hint
    }
    override func mouseUp(with event: NSEvent) {
        guard let a = anchor else { return }
        let r = RecordingRegion.rect(from: a, to: convert(event.locationInWindow, from: nil)).intersection(bounds)
        // A click without a drag records the whole screen (hot corners make starting from the edge impossible otherwise).
        finish(r.isNull || RecordingRegion.isClick(r) ? bounds : r)
    }
    override func rightMouseDown(with event: NSEvent) { finish(nil) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(nil) } else { NSSound.beep() } // Esc; any other key is not ours
    }
    override func cancelOperation(_ sender: Any?) { finish(nil) }
}

/// The dashed accent border that marks the region while it records: its own window, with `sharingType = .none`, drawn OUTSIDE
/// the recorded rect so not even a screen recorder that ignores the flag would pick it up.
final class RegionBorder {
    private var panel: BucketPanel?
    private var scrim: BucketPanel?
    static let room: CGFloat = 4

    /// Window levels while recording, bottom to top: the scrim, then the frame, then the pill. Distinct levels, so what is on top
    /// never depends on the order the windows were ordered front.
    static let scrimLevel = NSWindow.Level.statusBar
    static let borderLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    static let pillLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)

    /// The dimmed screen (outside the region) and the dashed frame. Both are excluded from capture and let the mouse through.
    func show(region: CGRect, screen: NSScreen) {
        close()
        let dim = BucketPanel(size: screen.frame.size, ignoresMouse: true)
        dim.level = RegionBorder.scrimLevel
        let dimView = RegionCanvas(frame: CGRect(origin: .zero, size: screen.frame.size))
        dimView.selection = region.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        dimView.showsBorder = false
        dim.contentView = dimView
        dim.setFrame(screen.frame, display: false)
        dim.orderFrontRegardless()
        scrim = dim

        let room = RegionBorder.room
        let frame = region.insetBy(dx: -room, dy: -room)
        let panel = BucketPanel(size: frame.size, ignoresMouse: true)
        panel.level = RegionBorder.borderLevel
        panel.contentView = RegionBorderView(frame: CGRect(origin: .zero, size: frame.size))
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() { panel?.orderOut(nil); panel = nil; scrim?.orderOut(nil); scrim = nil }
}

final class RegionBorderView: NSView {
    /// The recorded rect inside this view, y up.
    var recorded: CGRect { bounds.insetBy(dx: RegionBorder.room, dy: RegionBorder.room) }
    override func draw(_ dirtyRect: NSRect) {
        Glyph.accent.setStroke()
        let w = RegionCanvas.border
        let path = NSBezierPath(rect: recorded.insetBy(dx: -w / 2, dy: -w / 2)) // the stroke lies wholly outside the rect
        path.lineWidth = w
        path.setLineDash([6, 4], count: 2, phase: 0)
        path.stroke()
    }
}
