import AppKit
import BucketCore

/// What the region picker draws (state A of the mock): a light scrim over the screen, the selection cut out of it with a
/// 1.5 pt `bucket.accent` border, and the size in a neutral capsule. Shared by the live overlay and `Bucket render`.
/// Coordinates are the view's own (y up).
final class RegionCanvas: NSView {
    var selection: CGRect? { didSet { needsDisplay = true } }
    /// Opaque material stand-in for the capsule (the overlay is a plain window, no blur).
    static let scrimAlpha: CGFloat = 0.28
    static let border: CGFloat = 1.5

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let scrim = NSBezierPath(rect: bounds)
        if let s = selection { scrim.append(NSBezierPath(rect: s)); scrim.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(RegionCanvas.scrimAlpha).setFill()
        scrim.fill()
        guard let s = selection, s.width > 0, s.height > 0 else { return }

        Glyph.accent.setStroke()
        let line = NSBezierPath(rect: s.insetBy(dx: -RegionCanvas.border / 2, dy: -RegionCanvas.border / 2)) // the border sits outside the selection
        line.lineWidth = RegionCanvas.border
        line.stroke()

        // Live measures, in points. Under the selection on the right; inside it when there is no room below.
        let text = "\(Int(s.width.rounded())) × \(Int(s.height.rounded()))"
        let font = PillFont.tabular(PillFont.rounded(11, .semibold))
        let w = PillFont.width(text, font) + 16, h: CGFloat = 20
        var cap = CGRect(x: s.maxX - w, y: s.minY - 8 - h, width: w, height: h)
        if cap.minY < bounds.minY + 4 { cap.origin.y = s.minY + 8 }
        cap.origin.x = min(max(cap.minX, bounds.minX + 4), bounds.maxX - w - 4)
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

/// The region picker: one window over the screen the cursor is on. Drag to choose; Esc, or a click without a drag, cancels
/// (a stray click must never record the whole screen). The window is out of the way (ordered out) BEFORE `done` is called.
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = PickerView(frame: CGRect(origin: .zero, size: screen.frame.size))
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
    private let canvas = RegionCanvas()
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
        canvas.selection = RecordingRegion.rect(from: a, to: convert(event.locationInWindow, from: nil)).intersection(bounds)
    }
    override func mouseUp(with event: NSEvent) {
        guard let a = anchor else { return }
        let r = RecordingRegion.rect(from: a, to: convert(event.locationInWindow, from: nil)).intersection(bounds)
        finish(r.isNull || RecordingRegion.isClick(r) ? nil : r)
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
    static let room: CGFloat = 4

    func show(region: CGRect) {
        close()
        let room = RegionBorder.room
        let frame = region.insetBy(dx: -room, dy: -room)
        let panel = BucketPanel(size: frame.size, ignoresMouse: true)
        panel.contentView = RegionBorderView(frame: CGRect(origin: .zero, size: frame.size))
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() { panel?.orderOut(nil); panel = nil }
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
