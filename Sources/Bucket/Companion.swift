import AppKit
import BucketCore
import QuartzCore

/// Hosts the layer tree and tells the controller when the appearance changes.
private final class CompanionHost: NSView {
    var onAppearance: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); onAppearance?() }
}

/// The companion: the pill that follows the cursor while the bucket has load.
/// `CompanionModel` decides what is visible; `PillRig` draws and animates; this class owns the window, the 60 Hz timer
/// (only while visible), the schedule of each event and its hand-offs to the bar.
final class Companion {
    // Hooks the status item controller fills in.
    /// Screen rect of the status item button, for the flight to the bar.
    var statusFrame: () -> CGRect? = { nil }
    /// The bar icon waits for the pill (the image changes when the drop lands, not when the file is saved).
    var barHold: (Bool) -> Void = { _ in }
    /// Refresh the bar icon from the real count; `bounce` plays the springSoft 1→1.25→1.
    var barShow: (_ bounce: Bool) -> Void = { _ in }

    private(set) var model: CompanionModel
    private let panel = BucketPanel(size: CompanionPlacement.window)
    private let rig: PillRig
    private let host = CompanionHost()
    private let flight = BarFlight()
    private var timer: Timer?
    private var smoothed = CGPoint.zero
    private var applied = CGPoint(x: CGFloat.nan, y: CGFloat.nan)
    private var side = PillSide()
    private var work: [DispatchWorkItem] = []
    private var busyUntil: CFTimeInterval = 0
    private var barHeld = false
    private var onScreen = false
    /// `Bucket companion-check`: the real companion with no window on screen, no timers and a virtual clock (see `drain`).
    private let headless: Bool
    private var virtual: [(due: Double, seq: Int, item: DispatchWorkItem)] = []
    private var virtualNow = 0.0, virtualSeq = 0
    private let mediaOrigin = Anim.now
    /// Media time of the tracks that start now: the real clock, or (headless) the virtual one, so a step that runs later in
    /// `drain`/`step` begins when the virtual clock says and not at the instant the check ran it.
    private var mediaNow: CFTimeInterval { headless ? mediaOrigin + virtualNow / 1000 : Anim.now }

    static let keepKey = "keepInMenuBar"
    private var reduceMotion: Bool { headless ? false : NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private static var systemDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    private var isDark: Bool { headless ? checkDark ?? Companion.systemDark : Companion.systemDark }

    var keepInMenuBar: Bool {
        get { model.keepInMenuBar }
        set {
            guard newValue != model.keepInMenuBar else { return }
            UserDefaults.standard.set(newValue, forKey: Companion.keepKey)
            interrupt()
            model.keepInMenuBar = newValue
            if model.isVisible { showResting() } else { hide() } // on: no pill at rest · off: it comes back if there is load
        }
    }

    init(count: Int = 0, headless: Bool = false) {
        self.headless = headless
        flight.headless = headless
        model = CompanionModel(count: count, keepInMenuBar: headless ? false : UserDefaults.standard.bool(forKey: Companion.keepKey))
        rig = PillRig(dark: Companion.systemDark, opaqueMaterial: true) // same opaque material as `Bucket render`: no live blur to fail

        host.frame = CGRect(origin: .zero, size: CompanionPlacement.window)
        host.wantsLayer = true
        host.layer?.addSublayer(rig.canvas)
        host.onAppearance = { [weak self] in self?.refreshPalette() }
        panel.contentView = host
        rig.apply(rig.state)

        BucketWindows.register { [weak self] in self?.hideForCapture() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            // Reduce Motion is read at each event; a change mid-event just lands on the final state.
            self?.interrupt()
        }
    }

    /// App launch with load still in the bucket: the pill is there, compact, following the cursor.
    func start() { if model.isVisible { showResting() } }

    // MARK: Events

    private var prepared = false

    /// Call BEFORE the bucket changes (add/take): drops whatever was running and holds the bar icon so it does not jump
    /// ahead of the animation. The event method that follows (absorbed/pasted) continues from here.
    func prepare() {
        interrupt()
        holdBar()
        prepared = true
    }

    /// Start of every event: continue a `prepare()`, or interrupt what is running.
    private func startEvent() {
        if prepared { prepared = false } else { interrupt() }
    }

    /// ⌘⇧4: out of sight BEFORE `screencapture` starts. The caller flushes Core Animation after this.
    func beginCapture() {
        interrupt()
        model.beginCapture()
        hide()
    }

    /// ESC or a capture that left no file: the pill comes back only if there is load (opacity 120 outQuart).
    func cancelCapture() {
        model.endCapture()
        guard model.isVisible else { return }
        showResting()
        if !reduceMotion { rig.fadeIn(Motion.Absorb.cancelReturn, base: mediaNow) }
    }

    /// A shot landed in the bucket (`after` counts it).
    func absorbed(before: Int, after: Int) {
        startEvent()
        model.endCapture()
        model.setCount(after)
        model.begin(.absorb)
        let base = mediaNow, reduce = reduceMotion
        present(at: pointer, state: state(form: .expanded))
        rig.absorb(before: before, after: after, base: base, reduce: reduce)
        let A = Motion.Absorb.self
        busy(A.barBounce.end)
        if reduce {
            later(Motion.Reduced.crossfade.dur) { [self] in releaseBar(bounce: false); scheduleSettle(Motion.Behavior.settleAfter) }
        } else if model.keepInMenuBar {
            // Flash: it does its absorber, waits 700 and flies to the bar; the bar changes when it lands.
            scheduleSettle(A.barBounce.end + Motion.Behavior.flashHold)
        } else {
            later(A.barBounce.start) { [self] in releaseBar(bounce: true) }
            scheduleSettle(A.compactStart)
        }
    }

    /// The paste promise was cashed; `n` shots went out. The glyph pours inside the pill, "Pasted n" is read and the pill leaves
    /// where it is; the bar just turns empty.
    func pasted(_ n: Int) {
        let was = onScreen ? rig.state : nil
        startEvent()
        model.endCapture()
        model.setCount(0)
        model.begin(.release(n))
        let reduce = reduceMotion
        var base = mediaNow
        checkBase = base
        let from: PillState
        if let was { from = was; side = was.side; applyWindowFrame(); updateTimer() }
        else {
            from = PillState(side: side, form: .compact, text: CompanionCopy.count(n), number: "\(n)", glyph: GlyphState(count: n))
        }
        let R = Motion.Release.self
        if was == nil || model.keepInMenuBar {
            // Keep in menu bar (or nothing on screen): it comes down from the bar first (340, outStrong).
            present(at: pointer, state: PillState(side: side, form: .expanded, text: CompanionCopy.count(n), number: "\(n)", glyph: GlyphState(count: n)))
            if !reduce, let bar = statusFrame() {
                let down = Motion.Pill.dropFromBar
                let box = rig.glyphBox()
                flight.fly(GlyphState(count: n), palette: rig.palette, from: CGPoint(x: bar.midX, y: bar.midY), fromSize: CGFloat(Motion.Pill.flightGlyphSize),
                           to: screenPoint(box.center), toSize: box.size, step: down, base: base)
                rig.flightIn(down, base: base)
                base += down.seconds
            }
            rig.release(shots: n, from: PillState(side: side, form: .expanded, text: CompanionCopy.count(n), number: "\(n)", glyph: GlyphState(count: n)),
                        base: base, reduce: reduce)
        } else {
            rig.release(shots: n, from: from, base: base, reduce: reduce)
        }
        let head = (base - mediaNow) * 1000
        busy(head + R.exit.end)
        if reduce {
            later(head + Motion.Reduced.crossfade.dur + Motion.Reduced.pastedHold) { [self] in fadeAway(base: mediaNow) }
        } else {
            later(head + R.exit.start) { [self] in leaveInPlace(R.exit) }
        }
    }

    /// The last batch (`n` shots) is on the clipboard. With load the bucket is untouched: "Re-copied N" and the pill goes
    /// back to its own count (no flying stripes). Empty bucket: the pill shows it refilling for a moment.
    func recopied(_ n: Int, bucketCount: Int) {
        guard bucketCount == 0 else { feedback(CompanionCopy.recopied(n), count: bucketCount); return }
        startEvent()
        releaseBar(bounce: false)
        guard !model.panelOpen else { return } // the panel is open: it already shows the result
        model.recopied(n, bucketCount: 0)
        let base = mediaNow, reduce = reduceMotion
        present(at: pointer, state: PillState(side: side, form: .expanded, text: CompanionCopy.recopied(n), number: "\(n)", glyph: .empty))
        rig.refill(count: n, base: base, reduce: reduce)
        let E = Motion.Edges.self
        busy(E.recopyGo.start)
        if reduce { later(Motion.Reduced.crossfade.dur + Motion.Reduced.pastedHold) { [self] in fadeAway(base: mediaNow) } }
        else { later(E.recopyGo.start) { [self] in leaveToBar(E.recopyGo, tail: Motion.Step(0, Motion.Pill.vanishFade.dur, .linear)) } }
    }

    /// A prepared event ended with nothing to show (the bucket held only entries that no longer load): give the bar back
    /// and put the pill at the real count.
    func abandonPrepared(count n: Int) {
        interrupt()
        model.setCount(n)
        if model.isVisible { showResting() } else { hide() }
    }

    /// A line of words next to the cursor (Re-copied, Sent to Desktop, errors). With load the pill expands and compacts
    /// again; without it, it flies to the bar when done.
    func feedback(_ text: String, count: Int? = nil) {
        let was = onScreen ? rig.state : nil
        startEvent()
        releaseBar(bounce: false) // a feedback never owes the bar an animation
        if let count { model.setCount(count) }
        guard !model.panelOpen else { return } // the panel is open: its footer says it
        model.endCapture()
        model.begin(.feedback(text))
        let base = mediaNow, reduce = reduceMotion
        let target = state(form: .expanded)
        if let was, !model.keepInMenuBar {
            side = was.side
            applyWindowFrame()
            updateTimer()
            rig.removeAllAnimations()
            if was.form == .compact { rig.morph(from: was, to: target, base: base, reduce: reduce) }
            else { rig.apply(target); if !reduce { rig.swapText(from: was.text, base: base) } }
        } else {
            present(at: pointer, state: target)
            reduce ? rig.crossfadeIn(base: base) : rig.enter(Motion.Pill.appear, rise: Motion.Pill.appearRise, base: base)
        }
        busy(Motion.Pill.expand.dur)
        scheduleSettle(Motion.Pill.expand.dur + (model.keepInMenuBar ? Motion.Behavior.flashHold : Motion.Behavior.settleAfter))
    }

    /// The count changed without a gesture (panel, remove, clear): keep the pill honest without ceremony.
    func countChanged(_ n: Int) {
        guard model.count != n else { return }
        let wasOnScreen = onScreen
        interrupt()
        model.setCount(n)
        if model.isVisible { showResting() }
        else if wasOnScreen && n == 0 { leaveToBar(Motion.Pill.vanishFly, tail: Motion.Pill.vanishFade) } // Clear bucket: it goes to the bar
        else { hide() }
    }

    /// With the panel open the companion steps aside and comes back when it closes.
    var panelOpen: Bool {
        get { model.panelOpen }
        set {
            guard newValue != model.panelOpen else { return }
            let wasOnScreen = onScreen
            interrupt()
            model.panelOpen = newValue
            if model.isVisible { showResting(); return }
            // Opening: the pill fades in 120 ms instead of vanishing; Reduce Motion and capture just hide it.
            guard newValue, wasOnScreen, !reduceMotion else { hide(); return }
            let step = Motion.Pill.panelOpenFade
            CATransaction.begin(); CATransaction.setDisableActions(true)
            rig.group.opacity = 0
            CATransaction.commit()
            rig.groupTrack("out") { _ in Anim.basic("opacity", from: 1, to: 0, step, base: mediaNow) }
            later(step.dur) { [self] in hide() }
        }
    }

    // MARK: Schedule

    private func scheduleSettle(_ ms: Double) { later(ms) { [self] in settleNow() } }

    /// 1500 ms after the last event: compact if there is load; otherwise it goes to the bar.
    private func settleNow() {
        let was = rig.state
        model.settle()
        if model.isVisible {
            let to = state(form: .compact)
            rig.removeAllAnimations()
            rig.morph(from: was, to: to, base: mediaNow, reduce: reduceMotion)
            busy(Motion.Pill.compact.dur)
        } else {
            leaveToBar(model.keepInMenuBar ? Motion.Pill.flyToBarRest : Motion.Pill.vanishFly,
                       tail: model.keepInMenuBar ? nil : Motion.Pill.vanishFade)
        }
    }

    /// The glyph flies to the status item, the pill fades, the bar bounces when it lands.
    private func leaveToBar(_ step: Motion.Step, tail: Motion.Step?) {
        let base = mediaNow
        model.settle()
        guard !reduceMotion, let bar = statusFrame() else { fadeAway(base: base); return }
        let box = rig.glyphBox()
        flight.fly(rig.state.glyph, palette: rig.palette, from: screenPoint(box.center), fromSize: box.size,
                   to: CGPoint(x: bar.midX, y: bar.midY), toSize: CGFloat(Motion.Pill.flightGlyphSize), step: step, base: base)
        rig.flightOut(step, tail: tail, base: base)
        busy(step.dur + (tail?.dur ?? 0))
        later(step.dur) { [self] in arriveAtBar() }
        later(step.dur + (tail?.dur ?? 0)) { [self] in hide() }
    }

    /// The pill fades and shrinks a little where it is (`step.start` is when this runs; the track starts now); the bar turns empty (with its bounce) as it goes.
    private func leaveInPlace(_ step: Motion.Step) {
        model.settle()
        rig.exitInPlace(Motion.Step(0, step.dur, step.curve), scale: Motion.Release.exitScale, base: mediaNow)
        busy(step.dur)
        arriveAtBar()
        later(step.dur) { [self] in hide() }
    }

    /// Reduce Motion: crossfade 160 and out.
    private func fadeAway(base: CFTimeInterval) {
        model.settle()
        let fade = Motion.Reduced.crossfade
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rig.group.opacity = 0
        CATransaction.commit()
        rig.groupTrack("out") { _ in Anim.basic("opacity", from: 1, to: 0, fade, base: base) }
        later(fade.dur) { [self] in releaseBar(bounce: false); hide() }
    }

    // MARK: Bar hand-off

    /// Called by the controller before the bucket changes, so the bar icon does not jump ahead of the animation.
    func holdBar() {
        guard !barHeld else { return }
        barHeld = true
        barHold(true)
        later(4000) { [self] in releaseBar(bounce: false) } // safety: never leave the bar frozen
    }

    private func releaseBar(bounce: Bool) {
        guard barHeld else { return }
        barHeld = false
        barHold(false)
        barShow(bounce && !reduceMotion)
    }

    /// The glyph landed on the bar (or the pill left after a paste): show the real icon and bounce it, whether or not the bar was being held.
    private func arriveAtBar() {
        if barHeld { releaseBar(bounce: true) } else { barShow(!reduceMotion) }
    }

    // MARK: Window

    private func state(form: CompanionModel.Form) -> PillState {
        let text: String
        switch model.activity {
        case .release(let n): text = CompanionCopy.pasted(n)
        case .feedback(let s): text = s
        case .none, .absorb: text = CompanionCopy.count(model.count)
        }
        return PillState(side: side, form: form, text: text, number: "\(model.count)", glyph: GlyphState(count: model.count))
    }

    /// Visible at rest (compact with load).
    private func showResting() {
        present(at: pointer, state: state(form: model.form))
    }

    /// Puts the window under the cursor with `state` as its still pose and starts following if the model says so.
    private func present(at cursor: CGPoint, state s: PillState) {
        refreshPalette()
        smoothed = cursor
        applied = CGPoint(x: CGFloat.nan, y: CGFloat.nan)
        let screen = screenOf(cursor)
        let visible = headless ? checkVisible ?? screen?.visibleFrame ?? .infinite : screen?.visibleFrame ?? .infinite
        var st = s
        st.side = PillSide()
        rig.removeAllAnimations()
        rig.apply(st)
        side = CompanionPlacement.side(cursor: cursor, visible: visible, size: CGSize(width: rig.expandedWidth, height: CompanionPlacement.expandedHeight), previous: PillSide())
        st.side = side
        rig.apply(st)
        applyWindowFrame()
        if !headless { panel.orderFrontRegardless() }
        onScreen = true
        updateTimer()
    }

    private func applyWindowFrame() {
        // The side only switches between events; in the meantime the cursor can reach an edge: the window slides so the capsule is never cut.
        var frame = CompanionPlacement.windowFrame(cursor: smoothed, side: side)
        if let screen = screenOf(smoothed) {
            frame = CompanionPlacement.fittedWindowFrame(cursor: smoothed, side: side, pill: rig.rect(for: rig.state), visible: screen.visibleFrame)
        }
        panel.setFrame(frame, display: false)
        applied = smoothed
    }

    func hide() {
        timer?.invalidate(); timer = nil
        rig.removeAllAnimations()
        panel.orderOut(nil)
        onScreen = false
    }

    /// Registered in `BucketWindows`: everything off screen, nothing kept running.
    private func hideForCapture() {
        flight.cancel()
        if onScreen { interrupt(); hide() }
    }

    private func refreshPalette() {
        let p = PillPalette(dark: isDark)
        rig.applyPalette(p) // the panel follows the system appearance; the host tells us when it changes
    }

    /// The screen under the point; on a seam or the far edge (NSMouseInRect is exclusive there) the nearest one, never just `main`.
    private func screenOf(_ p: CGPoint) -> NSScreen? {
        if let s = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) { return s }
        func dist(_ r: CGRect) -> CGFloat { hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY)) }
        return NSScreen.screens.min { dist($0.frame) < dist($1.frame) } ?? NSScreen.main
    }

    /// Canvas point (y-down) → screen point (y-up) under the current window frame.
    private func screenPoint(_ p: CGPoint) -> CGPoint {
        let f = panel.frame
        return CGPoint(x: f.minX + p.x, y: f.maxY - p.y)
    }

    // MARK: Interruption

    /// A new gesture arrives: whatever is running jumps to its final state and the schedule is dropped.
    private func interrupt() {
        work.forEach { $0.cancel() }
        work.removeAll()
        flight.cancel()
        rig.removeAllAnimations()
        busyUntil = 0
        prepared = false
        model.settle() // the event that was running is over; the next one begins its own
        releaseBar(bounce: false)
    }

    private func later(_ ms: Double, _ block: @escaping () -> Void) {
        let w = DispatchWorkItem(block: block)
        work.append(w)
        if headless { virtualSeq += 1; virtual.append((virtualNow + ms, virtualSeq, w)); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000, execute: w)
    }

    /// Headless only: runs every scheduled step (settle, compact, flight, hide) in order, with no waiting, until nothing is left.
    func drain() {
        while let next = virtual.min(by: { ($0.due, $0.seq) < ($1.due, $1.seq) }) {
            virtual.removeAll { $0.seq == next.seq }
            virtualNow = max(virtualNow, next.due)
            next.item.perform() // a cancelled item does nothing
        }
    }

    /// Headless only: runs the steps due up to `t` (virtual ms) and leaves the clock there, so the check can look at the tree between steps.
    func step(to t: Double) {
        while let next = virtual.filter({ $0.due <= t }).min(by: { ($0.due, $0.seq) < ($1.due, $1.seq) }) {
            virtual.removeAll { $0.seq == next.seq }
            virtualNow = max(virtualNow, next.due)
            next.item.perform()
        }
        virtualNow = max(virtualNow, t)
    }
    var checkClock: Double { virtualNow }
    /// Headless only: the appearance the pill is drawn in (the system's when nil).
    var checkDark: Bool?
    /// Headless only: the media time at virtual millisecond `ms`, where the tracks of an event started then are evaluated.
    func checkMedia(at ms: Double) -> CFTimeInterval { mediaOrigin + ms / 1000 }
    /// Headless only: where the check says the cursor is, and the screen's usable frame, to put the pill on either side of it.
    var checkPointer: CGPoint?
    var checkVisible: CGRect?
    private var pointer: CGPoint { headless ? checkPointer ?? NSEvent.mouseLocation : NSEvent.mouseLocation }
    /// Media time of the last release (`pasted`), the t = 0 of its tracks.
    private(set) var checkBase: CFTimeInterval = 0

    /// Headless only: the layer tree, for `companion-check` to read the final model.
    var checkRig: PillRig { rig }
    var checkOnScreen: Bool { onScreen }

    private func busy(_ ms: Double) { busyUntil = max(busyUntil, CACurrentMediaTime() + ms / 1000) }

    // MARK: Following

    private func updateTimer() {
        if model.tracksCursor && onScreen {
            guard timer == nil else { return }
            let t = Timer(timeInterval: 1 / Motion.Behavior.followHz, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else { timer?.invalidate(); timer = nil }
    }

    private func tick() {
        let m = NSEvent.mouseLocation
        let k = reduceMotion ? 1 : CGFloat(Motion.Behavior.followSmoothing)
        smoothed = CGPoint(x: smoothed.x + (m.x - smoothed.x) * k, y: smoothed.y + (m.y - smoothed.y) * k)
        guard !(abs(smoothed.x - applied.x) < Motion.Behavior.followEpsilon && abs(smoothed.y - applied.y) < Motion.Behavior.followEpsilon) else { return }

        // The side changes only while nothing is animating, so a flip never cuts an event in half.
        if CACurrentMediaTime() >= busyUntil, let screen = screenOf(m) {
            let size = CGSize(width: max(rig.expandedWidth, 124), height: CompanionPlacement.expandedHeight)
            let next = CompanionPlacement.side(cursor: smoothed, visible: screen.visibleFrame, size: size, previous: side)
            if next != side { switchSide(to: next); return }
        }
        applyWindowFrame()
    }

    /// The window jumps to the other side of the cursor in this frame; the pill slides over 160 ms from where it was.
    private func switchSide(to next: PillSide) {
        let oldFrame = panel.frame
        let oldRect = rig.rect(for: rig.state)
        var st = rig.state
        side = next
        st.side = next
        rig.removeAllAnimations()
        rig.apply(st)
        applyWindowFrame()
        let newRect = rig.rect(for: st)
        let newFrame = panel.frame
        let old = CGPoint(x: oldFrame.minX + oldRect.minX, y: oldFrame.maxY - oldRect.minY)
        let new = CGPoint(x: newFrame.minX + newRect.minX, y: newFrame.maxY - newRect.minY)
        if !reduceMotion { rig.slide(by: CGPoint(x: old.x - new.x, y: -(old.y - new.y)), base: mediaNow) }
        busy(Motion.Pill.sideSwitch.dur)
    }
}
