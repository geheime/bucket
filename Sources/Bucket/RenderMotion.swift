import AppKit
import BucketCore
import QuartzCore

/// `Bucket render-motion <anim> <out-dir> [--dark] [--fps 60] [--scale 2] [--canvas WxH] [--bg #RRGGBB]`
///
/// Exports a motion frame by frame as `frame-00001.png…`. It is not an approximation: the REAL companion runs headless
/// on the virtual clock of `companion-check`, and at every frame the tracks it left on the layer tree are evaluated
/// (`TreeSampler`) and written onto the layers just long enough to rasterize them. What you see is what the user sees.
/// Core Animation is never asked to present anything: no window is created, shown or captured.
enum MotionRender {
    static let anims = ["absorb-1", "absorb-3", "compact", "release-3", "keycaps-capture", "keycaps-paste", "sequence"]
    /// Air before and after the motion, in milliseconds.
    static let lead = 300.0, tail = 300.0
    /// Defaults: a canvas that holds the cursor, the widest pill and its shadow; the background reads against the pill material.
    static let defaultCanvas = CGSize(width: 220, height: 80)
    static let lightBackground = "#E4E7EE", darkBackground = "#15171B"

    struct Options {
        var anim: String
        var dark = false
        var fps = 60.0
        var scale = 2.0
        var canvas = defaultCanvas
        var background: String?
    }

    struct Summary {
        var frames: Int
        var durationMs: Double
        var pixelSize: (width: Int, height: Int)
    }

    // MARK: CLI

    static func run(_ args: [String]) -> Int32 {
        func fail(_ m: String) -> Int32 {
            FileHandle.standardError.write(Data("bucket: \(m)\n".utf8))
            return 2
        }
        let usage = "usage: render-motion <\(anims.joined(separator: "|"))> <out-dir> [--dark] [--fps 60] [--scale 2] [--canvas WxH] [--bg #RRGGBB]"
        var positional: [String] = [], o = Options(anim: "")
        var i = 0
        while i < args.count {
            let a = args[i]
            func value() -> String? { i += 1; return i < args.count ? args[i] : nil }
            switch a {
            case "--dark": o.dark = true
            case "--fps": guard let v = value().flatMap(Double.init), v > 0, v <= 240 else { return fail("--fps needs a number in 1…240") }; o.fps = v
            case "--scale": guard let v = value().flatMap(Double.init), v > 0, v <= 16 else { return fail("--scale needs a number in (0, 16]") }; o.scale = v
            case "--canvas":
                let p = value()?.lowercased().split(separator: "x").compactMap { Double($0) } ?? []
                guard p.count == 2, p[0] >= 100, p[1] >= 60 else { return fail("--canvas needs WxH in points, at least 100x60") }
                o.canvas = CGSize(width: p[0], height: p[1])
            case "--bg":
                guard let v = value(), parseHex(v) != nil else { return fail("--bg needs #RRGGBB") }
                o.background = v
            default:
                if a.hasPrefix("--") { return fail("unknown option '\(a)'. \(usage)") }
                positional.append(a)
            }
            i += 1
        }
        guard positional.count == 2, anims.contains(positional[0]) else { return fail(usage) }
        o.anim = positional[0]
        let dir = URL(fileURLWithPath: (positional[1] as NSString).expandingTildeInPath)
        guard let s = export(o, to: dir) else { return fail("could not write the frames to \(dir.path)") }
        print("render-motion: \(o.anim)\(o.dark ? " (dark)" : ""): \(s.frames) frames of \(s.pixelSize.width)×\(s.pixelSize.height) px, "
              + "\(Int(s.durationMs)) ms at \(o.fps.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(o.fps)) : String(o.fps)) fps → \(dir.path)")
        return 0
    }

    /// Writes `frame-00001.png…` into `dir` (created if needed; stale frames of a previous run are removed first).
    static func export(_ o: Options, to dir: URL) -> Summary? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in try fm.contentsOfDirectory(atPath: dir.path) where f.hasPrefix("frame-") && f.hasSuffix(".png") {
                try fm.removeItem(at: dir.appendingPathComponent(f))
            }
        } catch { return nil }
        var ok = true
        let summary = render(o) { index, png in
            do { try png.write(to: dir.appendingPathComponent(String(format: "frame-%05d.png", index + 1))) } catch { ok = false }
            return ok
        }
        return ok ? summary : nil
    }

    // MARK: Engine

    static func parseHex(_ s: String) -> CGColor? {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        return PillPalette.hex(v)
    }

    /// Plays `o.anim` and hands each frame (0-based index, PNG) to `frame`; it returns false to stop.
    static func render(_ o: Options, frame: (Int, Data) -> Bool) -> Summary? {
        _ = NSApplication.shared
        guard let bg = parseHex(o.background ?? (o.dark ? darkBackground : lightBackground)) else { return nil }
        let W = o.canvas.width, H = o.canvas.height
        let pw = Int((W * o.scale).rounded()), ph = Int((H * o.scale).rounded())

        let root = CALayer()
        root.bounds = CGRect(origin: .zero, size: o.canvas)
        root.anchorPoint = .zero
        root.backgroundColor = bg
        root.masksToBounds = true

        let timeline: Timeline
        var sampled: (Double) -> Void        // moves the world to virtual millisecond t
        var freeze: (Double) -> () -> Void   // writes the tracks live at t onto the layers; returns the undo

        if o.anim.hasPrefix("keycaps-") {
            let symbols = o.anim == "keycaps-capture" ? ["⌘", "⇧", "4"] : ["⌘", "V"]
            let row = KeycapRow(symbols: symbols, palette: PillPalette(dark: o.dark), opaqueMaterial: true)
            row.layer.position = CGPoint(x: ((W - row.layer.bounds.width) / 2).rounded(), y: ((H - row.layer.bounds.height) / 2).rounded())
            root.addSublayer(row.layer)
            let t0 = CACurrentMediaTime()
            KeycapRow.animate(row, base: t0 + lead / 1000, reduceMotion: false)
            timeline = Timeline(start: 0, duration: lead + Motion.Keycaps.total + tail, events: [])
            sampled = { _ in }
            freeze = { t in freezeTree(row.layer, at: t0 + t / 1000, rig: nil) }
        } else {
            let scene = PillScene(dark: o.dark)
            guard let tl = scene.timeline(for: o.anim) else { return nil }
            timeline = tl
            // Cursor and pill centered together: the group spans from the hotspot to 18 pt + the widest pill (124) and 18 pt + its height.
            let hx = ((W - 142) / 2).rounded(), hy = ((H - 56) / 2).rounded()
            let k = CompanionPlacement.cursorInWindow(PillSide()), bleed = CompanionPlacement.bleed
            let rig = scene.c.checkRig
            rig.canvas.position = CGPoint(x: hx - k.x, y: H - hy - CompanionPlacement.window.height + k.y)
            root.addSublayer(rig.canvas)
            root.addSublayer(PillRender.cursorLayer(at: CGPoint(x: hx + bleed, y: hy + bleed), rig: rig, canvasHeight: H))
            sampled = { t in
                scene.advance(to: t, events: tl.events)
                rig.canvas.isHidden = !scene.c.checkOnScreen
            }
            freeze = { t in freezeTree(rig.canvas, at: scene.c.checkMedia(at: t), rig: rig) }
        }

        var n = 0
        let total = max(1, Int((timeline.duration * o.fps / 1000).rounded(.up)))
        while n < total {
            let t = timeline.start + Double(n) * 1000 / o.fps
            sampled(t)
            let undo = freeze(t)
            let png = rasterize(root, pixels: (pw, ph), size: o.canvas)
            undo()
            guard let png, frame(n, png) else { return nil }
            n += 1
        }
        return Summary(frames: n, durationMs: timeline.duration, pixelSize: (pw, ph))
    }

    struct Timeline {
        var start: Double       // virtual ms of the first frame
        var duration: Double
        var events: [(at: Double, run: () -> Void)]
    }

    /// The real companion, headless, with a cursor parked where the pill sits right and below it.
    final class PillScene {
        let c = Companion(count: 0, headless: true)
        private var count = 0
        private var next = 0   // index of the next event to fire

        init(dark: Bool) {
            c.checkDark = dark
            c.checkPointer = CGPoint(x: 700, y: 450)
            c.checkVisible = CGRect(x: 0, y: 0, width: 1440, height: 900)
            c.statusFrame = { CGRect(x: 1320, y: 876, width: 28, height: 24) }
        }

        func shot() {
            let before = count; count += 1
            c.prepare(); c.absorbed(before: before, after: count)
        }

        func paste(_ n: Int) {
            c.prepare(); count = 0
            c.pasted(n)
        }

        /// Fires every event due up to `t` at its own virtual time, then leaves the clock at `t`.
        func advance(to t: Double, events: [(at: Double, run: () -> Void)]) {
            while next < events.count && events[next].at <= t {
                c.step(to: events[next].at)
                events[next].run()
                next += 1
            }
            c.step(to: t)
        }

        func timeline(for anim: String) -> Timeline? {
            let A = Motion.Absorb.self, R = Motion.Release.self
            let landed = A.barBounce.end                              // a shot has fully landed
            let compacted = A.compactStart + Motion.Pill.compact.dur  // from the last shot to the compact pill at rest
            let gap = 900.0                                           // between captures
            switch anim {
            case "absorb-1":
                return Timeline(start: 0, duration: lead + landed + tail, events: [(lead, shot)])
            case "absorb-3":
                let start = gap + landed
                return Timeline(start: start, duration: lead + landed + tail, events: [(0, shot), (gap, shot), (start + lead, shot)])
            case "compact":
                let start = 2 * gap + A.compactStart - lead
                return Timeline(start: start, duration: lead + Motion.Pill.compact.dur + tail, events: [(0, shot), (gap, shot), (2 * gap, shot)])
            case "release-3":
                let start = 2 * gap + compacted
                return Timeline(start: start, duration: lead + R.exit.end + tail,
                                events: [(0, shot), (gap, shot), (2 * gap, shot), (start + lead, { self.paste(3) })])
            case "sequence":
                let pasteAt = lead + 2 * gap + compacted + 600
                return Timeline(start: 0, duration: pasteAt + R.exit.end + tail,
                                events: [(lead, shot), (lead + gap, shot), (lead + 2 * gap, shot), (pasteAt, { self.paste(3) })])
            default:
                return nil
            }
        }
    }

    // MARK: Freeze and rasterize

    /// Writes onto the layers of `root` the value every running track has at media time `time` (opacity, position, transform,
    /// and the capsule paths of the pill), so a plain render shows the frame Core Animation would present. Returns the undo.
    static func freezeTree(_ root: CALayer, at time: CFTimeInterval, rig: PillRig?) -> () -> Void {
        let s = TreeSampler(time: time)
        var undo: [() -> Void] = []
        CATransaction.begin(); CATransaction.setDisableActions(true)
        func visit(_ l: CALayer) {
            let keyPaths = (l.animationKeys() ?? []).compactMap { (l.animation(forKey: $0) as? CAPropertyAnimation)?.keyPath }
            if keyPaths.contains("opacity") {
                let was = l.opacity
                l.opacity = Float(s.opacity(l))
                undo.append { l.opacity = was }
            }
            if keyPaths.contains(where: { $0.hasPrefix("position") }) {
                let was = l.position
                l.position = s.position(l)
                undo.append { l.position = was }
            }
            if keyPaths.contains(where: { $0.hasPrefix("transform") }) {
                let was = l.transform
                l.setAffineTransform(s.transform(l))
                undo.append { l.transform = was }
            }
            l.sublayers?.forEach(visit)
        }
        visit(root)
        if let rig, !(rig.edge.animationKeys() ?? []).isEmpty {
            // The capsule animates as one path on four layers; rebuild it from the edge's sampled rect (radius = half the height).
            let r = s.capsule(rig.edge)
            let p = PillRig.paths(rect: r, radius: r.height / 2, canvas: rig.canvas.bounds)
            let was = (rig.shadow.shadowPath, rig.shadowMask.path, rig.fillMask.path, rig.edge.path)
            rig.shadow.shadowPath = p.capsule; rig.shadowMask.path = p.hole; rig.fillMask.path = p.capsule; rig.edge.path = p.edge
            undo.append { rig.shadow.shadowPath = was.0; rig.shadowMask.path = was.1; rig.fillMask.path = was.2; rig.edge.path = was.3 }
        }
        CATransaction.commit()
        return {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            undo.reversed().forEach { $0() }
            CATransaction.commit()
        }
    }

    static func rasterize(_ root: CALayer, pixels: (Int, Int), size: CGSize) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels.0, pixelsHigh: pixels.1, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.layoutIfNeeded()
        root.render(in: gc.cgContext)
        CATransaction.commit()
        gc.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }
}
