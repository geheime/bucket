import AppKit
import BucketCore
import QuartzCore

/// Builders of Core Animation tracks from the `Motion` tables. Every track starts at `base + step.start`
/// and, with `backwards`, shows its first value while it waits, so a model that is already in its final state
/// still looks like the "before" until its turn.
enum Anim {
    static var now: CFTimeInterval { CACurrentMediaTime() }

    static func basic(_ key: String, from: Any?, to: Any?, _ step: Motion.Step, base: CFTimeInterval,
                      backwards: Bool = true, additive: Bool = false) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from; a.toValue = to
        a.duration = step.seconds
        a.timingFunction = step.curve.timing
        a.beginTime = base + step.delay
        a.fillMode = backwards ? .backwards : .removed
        a.isAdditive = additive
        return a
    }

    /// Keyframes over `[start, start + dur]` ms. `times` are fractions of `dur`; `curves` ease each segment
    /// (count = values − 1), linear when nil.
    static func keyframes(_ key: String, values: [Any], times: [Double], start: Double = 0, dur: Double,
                          curves: [Motion.Curve]? = nil, base: CFTimeInterval, backwards: Bool = true,
                          additive: Bool = false) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: key)
        a.values = values
        a.keyTimes = times.map { NSNumber(value: $0) }
        a.duration = dur / 1000
        a.beginTime = base + start / 1000
        a.fillMode = backwards ? .backwards : .removed
        a.isAdditive = additive
        a.calculationMode = .linear
        if let curves { a.timingFunctions = curves.map(\.timing) }
        return a
    }

    /// A track whose easing covers the whole timeline (CSS `easing` on a keyframed animation): sampled so CA only
    /// interpolates linearly between close samples. `value(u)` gets the eased progress in 0…1.
    static func sampled(_ key: String, _ step: Motion.Step, base: CFTimeInterval, samples: Int = 24, backwards: Bool = true,
                        additive: Bool = false, value: (Double) -> Any) -> CAKeyframeAnimation {
        var values: [Any] = [], times: [Double] = []
        for i in 0 ... samples {
            let t = Double(i) / Double(samples)
            values.append(value(step.curve.ease(t)))
            times.append(t)
        }
        return keyframes(key, values: values, times: times, start: step.start, dur: step.dur, base: base,
                         backwards: backwards, additive: additive)
    }

    /// Keeps `value` for `ms` from `start` (the "before" of something whose model is already final).
    static func hold(_ key: String, _ value: Any, until ms: Double, base: CFTimeInterval) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = value; a.toValue = value
        a.duration = ms / 1000
        a.beginTime = base
        a.fillMode = .backwards
        return a
    }

    /// Piecewise-linear lookup in (fraction, value) keyframes at progress `u`.
    static func lerp(_ keys: [(Double, Double)], _ u: Double) -> Double {
        guard let first = keys.first else { return 0 }
        if u <= first.0 { return first.1 }
        for i in 1 ..< keys.count where u <= keys[i].0 {
            let (a, b) = (keys[i - 1], keys[i])
            let f = b.0 == a.0 ? 1 : (u - a.0) / (b.0 - a.0)
            return a.1 + (b.1 - a.1) * f
        }
        return keys.last!.1
    }

    static func add(_ a: CAAnimation, to l: CALayer, _ key: String) { l.add(a, forKey: key) }
}

/// A panel that goes where it is told, even under the menu bar or over the Dock, never takes focus and (unless it is
/// the error pill) never takes the mouse. Shared by the companion, the keycaps and the flight window.
final class BucketPanel: NSPanel {
    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }
    var acceptsKey = false
    /// Only `companion-demo` flips this, so a screenshot can see the pill. In the product it is always off.
    static var visibleToCapture = false
    /// The default pushes borderless windows below the menu bar and inside the screen; the companion lives at the edges.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    init(size: CGSize, ignoresMouse: Bool = true) {
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                      // the pill draws its own shadow
        ignoresMouseEvents = ignoresMouse
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        sharingType = BucketPanel.visibleToCapture ? .readOnly : Recordable.sharingType // belt and braces: the law is to order out before capturing
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

/// Every Bucket window registers how to go off screen. `capture()` calls `hideAll()` BEFORE launching screencapture
/// A window that exists when it starts could end up in the shot, so every Bucket window registers here (the panel too).
enum BucketWindows {
    private static var hiders: [(hide: () -> Void, staysIfVisible: Bool)] = []
    /// True from `hideAll()` until the capture ends: windows that stay (the panel) must not close on focus loss meanwhile.
    private(set) static var isCapturing = false
    /// `staysIfVisible`: the user opened it, so it is content they may want to capture: it is not hidden.
    static func register(staysIfVisible: Bool = false, _ hide: @escaping () -> Void) { hiders.append((hide, staysIfVisible)) }
    static func hideAll() { isCapturing = true; hiders.filter { !$0.staysIfVisible }.forEach { $0.hide() } }
    static func captureEnded() { isCapturing = false }
}
