import AppKit
import BucketCore
import QuartzCore

/// The panel's window: borderless, nonactivating, but able to be key so ESC and the focus loss work.
private final class PanelWindow: NSPanel {
    var onEscape: (() -> Void)?
    var onResign: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// The default would push a borderless window under the menu bar or inside the screen; the controller places it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) } }
    override func resignKey() { super.resignKey(); onResign?() }
}

/// Opens, places, animates and closes the panel, and keeps its content honest with the bucket and the OCR queue.
/// What the buttons do is the status controller's business (it owns the exporter and the companion): hooks below.
final class PanelController: NSObject {
    // Hooks.
    var statusFrame: () -> CGRect? = { nil }
    var onOpenChanged: (Bool) -> Void = { _ in }
    var actions: (copyNow: () -> Void, recopy: () -> Void, sendLast: () -> Void, clear: () -> Void, remove: (String) -> Void)
        = ({}, {}, {}, {}, { _ in })

    private let library: Library
    private let bucket: BucketStore
    private let window: PanelWindow
    private let root = NSView()
    private let view = PanelView(frame: CGRect(x: 0, y: 0, width: PanelMetrics.width, height: 312))
    private var monitor: Any?
    private var closing = false
    /// A click on the status item first takes key away from the panel (it closes) and then lands as an action:
    /// without this memory the same click would reopen what it just closed.
    private var closedByFocusLoss: Date?

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var isOpen: Bool { window.isVisible && !closing }

    init(library: Library, bucket: BucketStore) {
        self.library = library
        self.bucket = bucket
        window = PanelWindow(contentRect: CGRect(x: 0, y: 0, width: PanelMetrics.width, height: 312),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        window.level = .popUpMenu
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.becomesKeyOnlyIfNeeded = false
        window.sharingType = .readOnly // open during a capture it may appear in the shot
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.onEscape = { [weak self] in self?.close() }
        window.onResign = { [weak self] in self?.resigned() }

        root.wantsLayer = true
        root.frame = CGRect(x: 0, y: 0, width: PanelMetrics.width, height: 312)
        let fx = NSVisualEffectView(frame: root.bounds)
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active // Bucket is LSUIElement: without this the vibrancy is off
        fx.maskImage = PanelController.maskImage()
        fx.autoresizingMask = [.width, .height]
        root.addSubview(fx)
        root.addSubview(view)
        window.contentView = root

        view.onEscape = { [weak self] in self?.close() }
        view.onCopyNow = { [weak self] in self?.actions.copyNow() }
        view.onRecopy = { [weak self] in
            guard let self else { return }
            self.view.confirmCopy(on: self.view.recopyButton)
            self.actions.recopy()
        }
        view.onSendLast = { [weak self] in self?.actions.sendLast() }
        view.onClear = { [weak self] in self?.actions.clear() }
        view.onRemove = { [weak self] id in self?.actions.remove(id) }
        view.onReveal = { path in NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        view.onOpenFolder = { [weak self] in
            guard let self else { return }
            let dir = self.library.root.appendingPathComponent(Library.dayPath(Date()))
            // The day folder only exists once something was captured today.
            NSWorkspace.shared.open(FileManager.default.fileExists(atPath: dir.path) ? dir : self.library.root)
        }
        view.onOpenSettings = { NSWorkspace.shared.open(ErrorPill.settingsURL) }
        view.onResize = { [weak self] h in self?.resize(to: h) }

        BucketWindows.register(staysIfVisible: true) { [weak self] in self?.closeNow() }
        NotificationCenter.default.addObserver(self, selector: #selector(ocrChanged(_:)), name: OCRQueue.didChange, object: nil)
    }

    /// Rounded rect r16 as a stretchable mask, so the window shadow follows the shape too.
    private static func maskImage() -> NSImage {
        let d: CGFloat = 16
        let image = NSImage(size: NSSize(width: 2 * d + 1, height: 2 * d + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: d, yRadius: d).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: d, left: d, bottom: d, right: d)
        image.resizingMode = .stretch
        return image
    }

    // MARK: Data

    private func currentData() -> PanelData {
        let items = bucket.items
        return PanelData(
            items: items.map { PanelData.Item(id: $0.id, path: $0.path) },
            lastBatch: bucket.lastBatch.map(\.path),
            savedIn: PanelCopy.savedIn(root: library.root, day: Library.dayPath(Date())),
            ocrPending: OCRQueue.shared.pendingCount,
            permissionError: !CGPreflightScreenCaptureAccess(),
            captureSymbols: Shortcut.capture.symbols)
    }

    /// The bucket changed while the panel is open (remove, clear, send, copy, a capture from the CLI…).
    func refresh() {
        guard isOpen else { return }
        view.reload(currentData(), animated: true)
    }

    @objc private func ocrChanged(_ note: Notification) {
        guard isOpen else { return }
        view.setOCR(pending: OCRQueue.shared.pendingCount)
    }

    func flash(_ text: String) { if isOpen { view.flashFooter(text) } }

    /// "Copy now" confirms on its button when it survives the action (it does not when the bucket empties).
    func confirmCopyNow() { if isOpen, !view.copyNowButton.isHidden { view.confirmCopy(on: view.copyNowButton) } }

    // MARK: Open / close

    func toggle() {
        if isOpen { close(); return }
        // The click that closed it by taking focus away must not reopen it.
        if let t = closedByFocusLoss, Date().timeIntervalSince(t) < 0.4 { closedByFocusLoss = nil; return }
        open()
    }

    func open() {
        guard !isOpen else { return }
        closing = false
        window.alphaValue = 1
        view.reload(currentData(), animated: false)
        place()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        onOpenChanged(true)
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard !BucketWindows.isCapturing else { return } // the native selection is not "another app"
            self?.close() // a click in another app (our own windows do not reach a global monitor)
        }
        animateOpen()
    }

    /// 120 ms outQuart, opacity → 0. Reduce Motion: crossfade 160.
    func close() {
        guard isOpen else { return }
        closing = true
        removeMonitor()
        onOpenChanged(false)
        let step = reduceMotion ? Motion.Reduced.crossfade : Motion.Panel.close
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = step.seconds
            c.timingFunction = step.curve.timing
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.closing else { return }
            self.window.orderOut(nil)
            self.closing = false
        })
    }

    /// Before a capture: off screen this instant, nothing left animating.
    func closeNow() {
        let wasOpen = window.isVisible
        removeMonitor()
        root.layer?.removeAllAnimations()
        window.alphaValue = 1
        window.orderOut(nil)
        if wasOpen && !closing { onOpenChanged(false) }
        closing = false
    }

    /// The capture is over: the panel (if still open) takes key back so ESC works again, and the new shot is in the grid.
    func captureEnded() {
        guard isOpen else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        refresh()
    }

    private func resigned() {
        guard isOpen, !BucketWindows.isCapturing else { return } // screencapture takes key; the panel stays
        closedByFocusLoss = Date()
        close()
    }

    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    // MARK: Placement and motion

    /// Top edge 6 pt under the menu bar, centered on the status item, kept inside `visibleFrame` with 8 pt of margin.
    private func place() {
        let size = CGSize(width: PanelMetrics.width, height: view.frame.height)
        guard let bar = statusFrame() else { window.setFrame(CGRect(origin: window.frame.origin, size: size), display: false); return }
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: bar.midX, y: bar.midY)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var x = bar.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - 8 - size.width)
        window.setFrame(CGRect(x: x, y: bar.minY - 6 - size.height, width: size.width, height: size.height), display: false)
        window.invalidateShadow()
    }

    /// The content grew or shrank: the top edge stays where it is.
    private func resize(to height: CGFloat) {
        root.frame.size = CGSize(width: PanelMetrics.width, height: height)
        guard window.isVisible else { window.setContentSize(CGSize(width: PanelMetrics.width, height: height)); return }
        var f = window.frame
        f.origin.y += f.height - height
        f.size.height = height
        window.setFrame(f, display: true)
        window.invalidateShadow()
    }

    /// Opacity 0→1 · scale .98→1 · translateY +4→0 (it comes down from the bar), anchored at the top center.
    private func animateOpen() {
        let step = reduceMotion ? Motion.Reduced.crossfade : Motion.Panel.open
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { c in
            c.duration = step.seconds
            c.timingFunction = step.curve.timing
            window.animator().alphaValue = 1
        }
        guard !reduceMotion, let layer = root.layer else { return }
        let b = layer.bounds, a = layer.anchorPoint
        // Pivot = top center of the content, relative to the layer's own anchor (same trick as the bar bounce).
        let px = b.midX - a.x * b.width
        let py = (root.isFlipped ? b.minY : b.maxY) - a.y * b.height
        let from = Motion.Panel.openScaleFrom, rise = Motion.Panel.openRise
        let up: CGFloat = root.isFlipped ? -1 : 1 // the layer's y axis points up unless the view is flipped
        layer.add(Anim.sampled("transform", step, base: Anim.now, backwards: false) { u in
            let s = from + (1 - from) * u
            var t = CATransform3DMakeTranslation(CGFloat((1 - s)) * px, CGFloat((1 - s)) * py + up * CGFloat(rise * (1 - u)), 0)
            t = CATransform3DScale(t, CGFloat(s), CGFloat(s), 1)
            return NSValue(caTransform3D: t)
        }, forKey: "open")
    }
}
