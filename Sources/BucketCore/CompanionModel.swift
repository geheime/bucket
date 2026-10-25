import Foundation

/// Copy of the companion. One place so the view, the renders and the checks read the same words.
public enum CompanionCopy {
    public static func count(_ n: Int) -> String { n <= 0 ? "Empty bucket" : "\(n) in bucket" }
    public static func pasted(_ n: Int) -> String { "Pasted \(n)" }
    public static func recopied(_ n: Int) -> String { "Re-copied \(n)" }
    public static func copied(_ n: Int) -> String { "Copied \(n)" }
    public static let sentToDesktop = "Sent to Desktop"
    public static let couldNotSend = "Could not send"
    public static let captureFailed = "Capture failed"
    public static let couldNotSave = "Could not save"
    public static let shortcutTaken = "Shortcut taken"
    public static let permissionNeeded = "Screen Recording needed"
    public static let openSettings = "Open Settings…"
}

/// What the companion is doing for the user right now. Pure state: no windows, no timers, so the checks can drive it.
/// The controller feeds it events and schedules the 1500 ms `settle`; the view only draws what this says.
public struct CompanionModel: Equatable {
    public enum Activity: Equatable {
        case none
        case absorb
        case release(Int)       // N pasted
        case feedback(String)   // Re-copied N · Sent to Desktop · a message
    }
    public enum Form: Equatable { case expanded, compact }

    public private(set) var count: Int
    public var keepInMenuBar: Bool
    /// The panel already shows the same thing, so the companion steps aside.
    public var panelOpen = false
    public private(set) var capturing = false
    public private(set) var activity: Activity = .none

    public init(count: Int = 0, keepInMenuBar: Bool = false) {
        self.count = count
        self.keepInMenuBar = keepInMenuBar
    }

    public mutating func setCount(_ n: Int) { count = max(0, n) }

    /// ⌘⇧4: everything goes off screen before `screencapture` starts.
    public mutating func beginCapture() { capturing = true; activity = .none }
    /// ESC (or a capture that left no file): the companion returns only if there is load.
    public mutating func endCapture() { capturing = false }

    public mutating func begin(_ a: Activity) { activity = a }

    /// Re-copy of the last batch (`n` shots). The pill keeps the bucket's REAL count: with load it stays as "N in bucket"
    /// once the words are gone, with none it is the refill and then the bar. Never zero by default.
    public mutating func recopied(_ n: Int, bucketCount: Int) {
        endCapture()
        setCount(bucketCount)
        begin(.feedback(CompanionCopy.recopied(n)))
    }
    /// 1500 ms after the last event: back to rest (compact while there is load, gone otherwise).
    public mutating func settle() { activity = .none }

    /// Is a window on screen? Load keeps it up at rest; events bring it up even with an empty bucket
    /// ("Pasted 3", "Re-copied 3") and, in Keep in menu bar, are the only thing that does.
    public var isVisible: Bool {
        if capturing || panelOpen { return false }
        if activity != .none { return true }
        return !keepInMenuBar && count >= 1
    }

    public var form: Form { activity == .none ? .compact : .expanded }

    /// The 60 Hz cursor timer runs only while this is true. Keep in menu bar never follows.
    public var tracksCursor: Bool { isVisible && !keepInMenuBar }

    /// Text of the pill for the current form.
    public var text: String {
        switch form {
        case .compact: return "\(count)"
        case .expanded:
            switch activity {
            case .release(let n): return CompanionCopy.pasted(n)
            case .feedback(let s): return s
            case .none, .absorb: return CompanionCopy.count(count)
            }
        }
    }
}

/// Which side of the cursor the pill sits on. Defaults: right and below.
public struct PillSide: Equatable, Sendable {
    public enum H: Sendable { case right, left }
    public enum V: Sendable { case below, above }
    public var h: H = .right
    public var v: V = .below
    public init(h: H = .right, v: V = .below) { self.h = h; self.v = v }
}

public enum CompanionPlacement {
    /// Fixed window canvas: 200 × 64 with the cursor drawn at (8, 8) and the pill at (26, 26).
    public static let canvas = CGSize(width: 200, height: 64)
    public static let cursorInCanvas = CGPoint(x: 8, y: 8)
    /// The live window adds room around the reference canvas for the shadow, the shot that is born at the cursor and the flying
    /// stripes; the reference canvas sits at (bleed, bleed) inside it. The window still never changes size.
    public static let bleed: CGFloat = 32
    public static var window: CGSize { CGSize(width: canvas.width + 2 * bleed, height: canvas.height + 2 * bleed) }

    public static let expandedHeight: CGFloat = 38
    public static let compactHeight: CGFloat = 32

    /// Side decision with 24 pt of hysteresis, on `visibleFrame` of the cursor's screen (margin 8).
    /// `size` is the expanded pill, so compacting never flips the side. Coordinates: screen, y up.
    public static func side(cursor c: CGPoint, visible f: CGRect, size: CGSize, previous p: PillSide) -> PillSide {
        let off = CGFloat(Motion.Behavior.cursorOffset), m = CGFloat(Motion.Behavior.edgeMargin), hy = CGFloat(Motion.Behavior.edgeHysteresis)
        var s = p
        let rightSlack = f.maxX - (c.x + off + size.width + m)       // < 0: does not fit on the right
        switch p.h {
        case .right: if rightSlack < 0 { s.h = .left }
        case .left: if rightSlack >= hy { s.h = .right }
        }
        let belowSlack = (c.y - off - size.height - m) - f.minY       // < 0: does not fit below
        switch p.v {
        case .below: if belowSlack < 0 { s.v = .above }
        case .above: if belowSlack >= hy { s.v = .below }
        }
        return s
    }

    /// Where the cursor sits inside the window (y down, window coordinates) for a side.
    public static func cursorInWindow(_ s: PillSide) -> CGPoint {
        let c = cursorInCanvas
        return CGPoint(x: bleed + (s.h == .right ? c.x : canvas.width - c.x),
                       y: bleed + (s.v == .below ? c.y : canvas.height - c.y))
    }

    /// Window frame (screen, y up) that puts `cursorInWindow` exactly under the cursor.
    public static func windowFrame(cursor: CGPoint, side: PillSide) -> CGRect {
        let k = cursorInWindow(side), w = window
        return CGRect(x: cursor.x - k.x, y: cursor.y + k.y - w.height, width: w.width, height: w.height)
    }

    /// `windowFrame`, slid just enough that the capsule `pill` (window coordinates, y down) lies ENTIRELY inside `visible`
    /// (the window may stick out with its transparent margin). Side switching is deferred while an event animates, and the
    /// cursor can reach any edge in that time: this is the guarantee that the capsule is never cut, on any screen.
    public static func fittedWindowFrame(cursor: CGPoint, side: PillSide, pill: CGRect, visible: CGRect) -> CGRect {
        var f = windowFrame(cursor: cursor, side: side)
        let w = f.width, h = f.height
        // Capsule in screen coordinates (y up); the window's left/top edge is f.minX / f.maxY.
        var c = CGRect(x: f.minX + pill.minX, y: f.maxY - pill.maxY, width: pill.width, height: pill.height)
        if c.maxX > visible.maxX { f.origin.x -= c.maxX - visible.maxX; c.origin.x -= c.maxX - visible.maxX }
        if c.minX < visible.minX { f.origin.x += visible.minX - c.minX }      // the near edge wins if it cannot fit at all
        if c.maxY > visible.maxY { f.origin.y -= c.maxY - visible.maxY; c.origin.y -= c.maxY - visible.maxY }
        if c.minY < visible.minY { f.origin.y += visible.minY - c.minY }
        f.size = CGSize(width: w, height: h)
        return f
    }

    /// Expanded pill rect inside the window (y down). Right/below: 18 off the hotspot; left/above: 8 (the arrow body
    /// is to the right of and below the hotspot, hence the asymmetry).
    public static func expandedRect(side s: PillSide, width: CGFloat) -> CGRect {
        let k = cursorInWindow(s), off = CGFloat(Motion.Behavior.cursorOffset), gap = CGFloat(Motion.Behavior.edgeMargin)
        let h = expandedHeight
        let x = s.h == .right ? k.x + off : k.x - gap - width
        let y = s.v == .below ? k.y + off : k.y - gap - h
        return CGRect(x: x, y: y, width: width, height: h)
    }

    /// Compact pill rect: keeps the edge on the cursor's side and the vertical center of the expanded one (same anchor).
    public static func compactRect(side s: PillSide, expanded e: CGRect, width: CGFloat) -> CGRect {
        let x = s.h == .right ? e.minX : e.maxX - width
        return CGRect(x: x, y: e.midY - compactHeight / 2, width: width, height: compactHeight)
    }
}

/// The keyboard overlay teaches a gesture the first 10 times, then gets out of the way.
/// ⌥⇧V is rare and nobody remembers it, so it always shows.
public struct KeycapPolicy {
    public enum Gesture: String, CaseIterable { case capture, paste, recopy }
    public static let limit = 10

    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public static func key(_ g: Gesture) -> String { "keycaps.\(g.rawValue).count" }

    public func shownCount(_ g: Gesture) -> Int { defaults.integer(forKey: KeycapPolicy.key(g)) }

    /// Counts the gesture and says whether the overlay shows this time.
    public func consume(_ g: Gesture) -> Bool {
        if g == .recopy { return true }
        let n = shownCount(g)
        guard n < KeycapPolicy.limit else { return false }
        defaults.set(n + 1, forKey: KeycapPolicy.key(g))
        return true
    }
}

public enum Keycap {
    /// Symbols of a gesture; the capture shortcut is user-configurable, so the caller passes its own.
    public static func symbols(_ g: KeycapPolicy.Gesture, capture: [String] = ["⌘", "⇧", "4"]) -> [String] {
        switch g {
        case .capture: return capture
        case .paste: return ["⌘", "V"]
        case .recopy: return ["⌥", "⇧", "V"]
        }
    }
}
