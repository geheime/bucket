import AppKit
import BucketCore
import QuartzCore


/// Reads the layer tree at a given media time WITHOUT a window: evaluates the tracks that `PillRig` adds (opacity, position,
/// rotation/scale, transform, capsule path) the way Core Animation would, so the check can see every frame of a move, not only
/// the last one. Only the key paths the rig uses are understood.
struct TreeSampler {
    let time: CFTimeInterval

    private func active(_ a: CAAnimation) -> Double? {
        let d = a.duration
        guard d > 0 else { return nil }
        let p = (time - a.beginTime) / d
        if p < 0 { return a.fillMode == .backwards || a.fillMode == .both ? 0 : nil }
        if p > 1 { return a.fillMode == .forwards || a.fillMode == .both ? 1 : nil }
        return p
    }

    private func curve(_ f: CAMediaTimingFunction?) -> Motion.Curve {
        guard let f else { return .linear }
        var a = [Float](repeating: 0, count: 2), b = a, c = a, d = a
        f.getControlPoint(at: 0, values: &a); f.getControlPoint(at: 1, values: &b)
        f.getControlPoint(at: 2, values: &c); f.getControlPoint(at: 3, values: &d)
        return Motion.Curve(b[0], b[1], c[0], c[1])
    }

    private func norm(_ v: Any) -> Any {
        if CFGetTypeID(v as CFTypeRef) == CGPath.typeID { return NSValue(rect: (v as! CGPath).boundingBoxOfPath) }
        return v
    }

    private func mix(_ a: Any, _ b: Any, _ f: Double) -> Any {
        if let x = a as? NSNumber, let y = b as? NSNumber { return x.doubleValue + (y.doubleValue - x.doubleValue) * f }
        guard let x = a as? NSValue, let y = b as? NSValue else { return a }
        let t = String(cString: x.objCType)
        if t.hasPrefix("{CATransform3D") {
            let p = x.caTransform3DValue, q = y.caTransform3DValue
            func m(_ u: CGFloat, _ v: CGFloat) -> CGFloat { u + (v - u) * CGFloat(f) }
            return NSValue(caTransform3D: CATransform3D(m11: m(p.m11, q.m11), m12: m(p.m12, q.m12), m13: m(p.m13, q.m13), m14: m(p.m14, q.m14),
                                                       m21: m(p.m21, q.m21), m22: m(p.m22, q.m22), m23: m(p.m23, q.m23), m24: m(p.m24, q.m24),
                                                       m31: m(p.m31, q.m31), m32: m(p.m32, q.m32), m33: m(p.m33, q.m33), m34: m(p.m34, q.m34),
                                                       m41: m(p.m41, q.m41), m42: m(p.m42, q.m42), m43: m(p.m43, q.m43), m44: m(p.m44, q.m44)))
        }
        if t.hasPrefix("{CGRect") {
            let p = x.rectValue, q = y.rectValue
            func m(_ u: CGFloat, _ v: CGFloat) -> CGFloat { u + (v - u) * CGFloat(f) }
            return NSValue(rect: CGRect(x: m(p.minX, q.minX), y: m(p.minY, q.minY), width: m(p.width, q.width), height: m(p.height, q.height)))
        }
        let p = x.pointValue, q = y.pointValue
        return NSValue(point: CGPoint(x: p.x + (q.x - p.x) * CGFloat(f), y: p.y + (q.y - p.y) * CGFloat(f)))
    }

    private func value(of a: CAAnimation, at p: Double) -> Any? {
        if let b = a as? CABasicAnimation, let f = b.fromValue, let t = b.toValue {
            return mix(norm(f), norm(t), curve(b.timingFunction).ease(p))
        }
        if let k = a as? CAKeyframeAnimation, let vals = k.values?.map(norm), vals.count >= 2 {
            let times = k.keyTimes?.map(\.doubleValue) ?? (0 ..< vals.count).map { Double($0) / Double(vals.count - 1) }
            var i = 0
            while i < times.count - 2 && p > times[i + 1] { i += 1 }
            let span = times[i + 1] - times[i]
            let f = span <= 0 ? 1 : min(1, max(0, (p - times[i]) / span))
            let fn = k.timingFunctions.flatMap { i < $0.count ? $0[i] : nil }
            return mix(vals[i], vals[i + 1], fn.map { curve($0).ease(f) } ?? f)
        }
        return nil
    }

    /// The animated tracks of `key` on `l`, in the order they were added.
    private func tracks(_ l: CALayer, _ key: String) -> [(Any, Bool)] {
        (l.animationKeys() ?? []).compactMap { k in
            guard let a = l.animation(forKey: k), (a as? CAPropertyAnimation)?.keyPath == key,
                  let p = active(a), let v = value(of: a, at: p) else { return nil }
            return (v, (a as? CAPropertyAnimation)?.isAdditive ?? false)
        }
    }

    func opacity(_ l: CALayer) -> Double {
        var v = Double(l.opacity)
        for (x, add) in tracks(l, "opacity") { let n = (x as? NSNumber)?.doubleValue ?? v; v = add ? v + n : n }
        return v
    }

    func effectiveOpacity(_ l: CALayer) -> Double {
        var o = opacity(l), p = l.superlayer
        while let q = p { o *= opacity(q); p = q.superlayer }
        return o
    }

    func position(_ l: CALayer) -> CGPoint {
        var v = l.position
        for (x, add) in tracks(l, "position") { if let pt = (x as? NSValue)?.pointValue { v = add ? CGPoint(x: v.x + pt.x, y: v.y + pt.y) : pt } }
        for (x, add) in tracks(l, "position.y") { if let n = (x as? NSNumber)?.doubleValue { v.y = add ? v.y + n : n } }
        for (x, add) in tracks(l, "position.x") { if let n = (x as? NSNumber)?.doubleValue { v.x = add ? v.x + n : n } }
        return v
    }

    /// The layer's transform: the model's, with the animated components on top.
    func transform(_ l: CALayer) -> CGAffineTransform {
        var t = l.affineTransform()
        if let (x, _) = tracks(l, "transform").last, let v = x as? NSValue { return CATransform3DGetAffineTransform(v.caTransform3DValue) }
        var rot = 0.0, sx = Double(t.a), sy = Double(t.d)
        var any = false
        if let (x, _) = tracks(l, "transform.rotation.z").last { rot = (x as? NSNumber)?.doubleValue ?? 0; any = true }
        if let (x, _) = tracks(l, "transform.scale").last { sx = (x as? NSNumber)?.doubleValue ?? sx; sy = sx; any = true }
        if let (x, _) = tracks(l, "transform.scale.x").last { sx = (x as? NSNumber)?.doubleValue ?? sx; any = true }
        if let (x, _) = tracks(l, "transform.scale.y").last { sy = (x as? NSNumber)?.doubleValue ?? sy; any = true }
        if any { t = CGAffineTransform(rotationAngle: CGFloat(rot)).scaledBy(x: CGFloat(sx), y: CGFloat(sy)); t.tx = l.affineTransform().tx; t.ty = l.affineTransform().ty }
        return t
    }

    /// Layer point → canvas point, through the animated transforms of the whole chain.
    func toCanvas(_ pt: CGPoint, from l: CALayer, canvas: CALayer) -> CGPoint { // `canvas`: the layer whose space we stop at

        var p = pt, cur: CALayer? = l
        while let x = cur, x !== canvas {
            let t = transform(x), pos = position(x)
            let q = CGPoint(x: p.x - x.anchorPoint.x * x.bounds.width, y: p.y - x.anchorPoint.y * x.bounds.height)
            p = CGPoint(x: pos.x + t.a * q.x + t.c * q.y + t.tx, y: pos.y + t.b * q.x + t.d * q.y + t.ty)
            cur = x.superlayer
        }
        return p
    }

    /// The capsule (the `edge` stroke is inset 0.25 pt from it).
    func capsule(_ edge: CAShapeLayer) -> CGRect {
        var r = edge.path?.boundingBoxOfPath ?? .zero
        if let (x, _) = tracks(edge, "path").last, let v = x as? NSValue { r = v.rectValue }
        return r.insetBy(dx: -0.25, dy: -0.25)
    }

    /// Points that outline what a visible leaf draws (flattened path, text/plain boxes), with half the stroke to add.
    static func outline(_ l: CALayer) -> (points: [CGPoint], margin: CGFloat)? {
        if let s = l as? CAShapeLayer {
            guard let path = s.path else { return nil }
            var pts: [CGPoint] = [], cur = CGPoint.zero
            func bez(_ ps: [CGPoint], _ u: CGFloat) -> CGPoint {
                var q = ps
                while q.count > 1 { q = (0 ..< q.count - 1).map { i in CGPoint(x: q[i].x + (q[i + 1].x - q[i].x) * u, y: q[i].y + (q[i + 1].y - q[i].y) * u) } }
                return q[0]
            }
            path.applyWithBlock { e in
                let q = e.pointee.points
                switch e.pointee.type {
                case .moveToPoint, .addLineToPoint: cur = q[0]; pts.append(cur)
                case .addQuadCurveToPoint:
                    let ps = [cur, q[0], q[1]]
                    for i in 1 ... 8 { pts.append(bez(ps, CGFloat(i) / 8)) }
                    cur = q[1]
                case .addCurveToPoint:
                    let ps = [cur, q[0], q[1], q[2]]
                    for i in 1 ... 12 { pts.append(bez(ps, CGFloat(i) / 12)) }
                    cur = q[2]
                default: break
                }
            }
            return (pts, s.strokeColor != nil && s.lineWidth > 0 ? s.lineWidth / 2 : 0)
        }
        guard l.bounds.width > 0, l.bounds.height > 0, l is CATextLayer || l.backgroundColor != nil || l.contents != nil else { return nil }
        let b = l.bounds
        return ([CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)], 0)
    }
}

/// How far a point (with `margin` of ink around it) is inside a capsule: positive = inside, negative = sticks out by that much.
func capsuleSlack(_ p: CGPoint, margin: CGFloat, in r: CGRect) -> CGFloat {
    let rad = r.height / 2
    let cx = min(max(p.x, r.minX + rad), r.maxX - rad)
    return rad - margin - hypot(p.x - cx, p.y - r.midY)
}

/// `Bucket companion-check`: drives the REAL companion (same class the app uses, not the render) through the whole
/// sequence with no window on screen and no waiting, and asserts the FINAL layer model after each step. The renders
/// draw a still pose and never see what a previous event left behind (a layer left at opacity 0 by the flight to
/// the bar, for example); this does. Exit 1 on any failed assertion.
enum CompanionCheck {
    static func run() -> Int32 {
        _ = NSApplication.shared
        var failed = 0, total = 0
        func check(_ name: String, _ ok: Bool) {
            total += 1
            if !ok { failed += 1 }
            print("\(ok ? "PASS" : "FAIL")  \(name)")
        }

        /// Opacity a layer really has on screen: its own times every ancestor's.
        func effective(_ l: CALayer) -> Float {
            var o = l.opacity, p = l.superlayer
            while let q = p { o *= q.opacity; p = q.superlayer }
            return o
        }
        func words(_ rig: PillRig, _ expected: String, _ label: String) {
            let t = rig.textNew
            check("\(label): text says \"\(expected)\"", (t.string as? String) == expected)
            check("\(label): text is visible (effective opacity 1, got \(effective(t)))", effective(t) == 1)
            check("\(label): text frame inside the canvas", rig.canvas.bounds.contains(t.frame) && t.frame.width > 0 && t.frame.height > 0)
            check("\(label): font size > 0", t.fontSize > 0)
            check("\(label): material and glyph visible", effective(rig.place) == 1 && effective(rig.bgGroup) == 1)
        }

        let c = Companion(count: 0, headless: true)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        c.statusFrame = { CGRect(x: screen.maxX - 120, y: screen.maxY - 24, width: 28, height: 24) }
        let rig = c.checkRig
        var count = 0
        func shot() {
            let before = count; count += 1
            c.prepare(); c.absorbed(before: before, after: count)
        }

        /// Plays a release from the current state sampling the tree every 16 ms of virtual time. Everything visible must stay
        /// inside the capsule the whole way, nothing may fly to the bar, no window may open, and the pill ends gone.
        func pour(_ label: String, shots n: Int) {
            let names: [(CALayer, String)] = [(rig.handle, "handle"), (rig.body, "body"), (rig.lip, "lip"), (rig.textOld, "old words"), (rig.textNew, "new words"), (rig.number, "number"), (rig.full, "block")]
                + rig.stripes.enumerated().map { ($1, "stripe\($0)") }
            c.prepare(); count = 0
            let side = rig.state.side
            let t0 = c.checkClock, launches = BarFlight.launches, windows = NSApp.windows.count
            c.pasted(n)
            let R = Motion.Release.self
            var t = t0, worst = CGFloat.infinity, worstAt = "", maxTilt = 0.0, minScale = 1.0, seen = Set<String>(), samples = 0
            var peak = (angle: 0.0, off: CGFloat.infinity, lean: CGFloat(0)) // at the sample of the largest tilt: ink center vs capsule middle, lean vs base
            var home: (dx: CGFloat, text: Float)?                             // once the glyph should be back: how far from rest, and the words
            while t < t0 + 6000 && c.checkOnScreen {
                let s = TreeSampler(time: c.checkBase + (t - t0) / 1000)
                let cap = s.capsule(rig.edge)
                let angle = abs(atan2(Double(s.transform(rig.tilt).b), Double(s.transform(rig.tilt).a))) * 180 / .pi
                maxTilt = max(maxTilt, angle)
                if angle > peak.angle + 1e-9 {
                    var lo = CGFloat.infinity, hi = -CGFloat.infinity
                    for l in [rig.handle, rig.body, rig.lip] {
                        guard let o = TreeSampler.outline(l) else { continue }
                        for q in o.points.map({ s.toCanvas($0, from: l, canvas: rig.group) }) { lo = min(lo, q.x - o.margin); hi = max(hi, q.x + o.margin) }
                    }
                    let base = s.toCanvas(CGPoint(x: PillRig.expandedGlyph * 0.5, y: PillRig.expandedGlyph * 0.9), from: rig.tilt, canvas: rig.group)
                    peak = (angle, abs((lo + hi) / 2 - cap.midX), (lo + hi) / 2 - base.x)
                }
                if home == nil && t - t0 >= R.slideBack.end + 16 {
                    home = (abs(s.position(rig.place).x - (cap.minX + 4)), Float(s.effectiveOpacity(rig.textNew)))
                }
                minScale = min(minScale, Double(s.transform(rig.group).a))
                func walk(_ l: CALayer) {
                    if l === rig.bgGroup || l.isHidden { return }
                    if let o = TreeSampler.outline(l), s.effectiveOpacity(l) > 0.02 {
                        let pts = o.points.map { s.toCanvas($0, from: l, canvas: rig.group) }
                        let slack = pts.map { capsuleSlack($0, margin: o.margin, in: cap) }.min() ?? .infinity
                        seen.insert(names.first { $0.0 === l }?.1 ?? "other")
                        if slack < worst { worst = slack; worstAt = "\(names.first { $0.0 === l }?.1 ?? "a stray layer") at \(Int(t - t0)) ms" }
                    }
                    l.sublayers?.forEach(walk)
                }
                walk(rig.group)
                samples += 1
                t += 16; c.step(to: t)
            }
            check("\(label): sampled \(samples) frames, glyph visible and tilted up to \(String(format: "%.0f", maxTilt))° (the check sees the move)", samples > 100 && seen.contains("stripe0") && maxTilt > 10)
            check("\(label): at the peak tilt the glyph is centered in the capsule (\(String(format: "%.2f", peak.off)) pt off the middle, ≤ 2)", peak.off <= 2)
            let cursorSide: CGFloat = (side.h == .right) ? -1 : 1 // cursor on the left of a right pill: it leans left
            check("\(label): it leans toward the cursor (pill \(side.h == .right ? "right" : "left") of it, lean \(String(format: "%+.1f", peak.lean)) pt from its base)", peak.lean * cursorSide > 1)
            check("\(label): back home the glyph is at its rest x (off \(String(format: "%.2f", home?.dx ?? 99)) pt) and the next words are on (opacity \(home?.text ?? 0))", (home?.dx ?? 99) < 0.5 && (home?.text ?? 0) == 1)
            check("\(label): everything visible stays inside the capsule (worst slack \(String(format: "%.2f", worst)) pt: \(worstAt))", worst >= -0.01)
            check("\(label): no flight to the bar and no extra window (flights \(BarFlight.launches - launches), windows \(NSApp.windows.count - windows))",
                  BarFlight.launches == launches && NSApp.windows.count == windows)
            check("\(label): the pill leaves in place (scale down to \(String(format: "%.2f", minScale))) and is gone", abs(minScale - Motion.Release.exitScale) < 0.02 && !c.checkOnScreen && rig.transient.isEmpty)
            c.drain()
        }

        /// Both sides of the cursor, from compact and from expanded: the lean points at the cursor, the glyph is centered at the
        /// peak and the next cycle starts with the glyph at rest and its words on.
        func bothSides() {
            for (name, at) in [("pill right of the cursor", CGPoint(x: 400, y: 450)), ("pill left of the cursor", CGPoint(x: 1430, y: 450))] {
                c.checkPointer = at; c.checkVisible = screen
                shot(); shot(); shot()
                check("\(name): the pill is on the side the check asked for (\(rig.state.side.h))", rig.state.side.h == (at.x < 700 ? .right : .left))
                pour("\(name), release 3 (still expanded)", shots: 3)
                shot(); shot(); shot(); c.drain()
                pour("\(name), release 3 from compact", shots: 3)
                shot()
                let r = rig.rect(for: rig.state)
                check("\(name): next cycle, the glyph rests at its x and the words are on (\(rig.place.position.x) vs \(r.minX + 4))",
                      abs(rig.place.position.x - (r.minX + 4)) < 0.01 && effective(rig.textNew) == 1 && (rig.textNew.string as? String) == "1 in bucket")
                c.drain()
            }
            c.checkPointer = nil; c.checkVisible = nil
        }

        c.checkPointer = CGPoint(x: 400, y: 450); c.checkVisible = screen
        for round in 1 ... 2 {
            let r = "round \(round)"
            shot(); words(rig, "1 in bucket", "\(r) shot 1")
            check("\(r) absorb: nothing flies outside the pill (no drop, no shot at the cursor; transient layers: \(rig.transient.count))", rig.transient.isEmpty)
            shot(); words(rig, "2 in bucket", "\(r) shot 2")
            c.drain() // 1500 ms later: it compacts
            check("\(r) compact: number says \"2\" and is visible", (rig.number.string as? String) == "2" && effective(rig.number) == 1)
            check("\(r) compact: the words are gone, the pill stays", effective(rig.textNew) == 0 && c.checkOnScreen)
            pour("\(r) release 2 from compact", shots: 2)
        }
        // The bug lived between rounds: the flight to the bar left `texts` at opacity 0 for the next event.
        check("texts layer back at opacity 1 after the pill left (got \(rig.texts.opacity))", rig.texts.opacity == 1)
        // The next cycle starts clean: the words are back.
        shot(); words(rig, "1 in bucket", "next cycle shot 1")
        for _ in 0 ..< 4 { shot() }
        c.drain()
        pour("release 5 (block) from compact", shots: 5)
        shot(); shot(); shot()
        pour("release 3 right after the shots (still expanded)", shots: 3)
        shot()
        c.drain()
        pour("release 1 from compact", shots: 1)

        bothSides()

        // render-motion: the exporter plays the real companion and writes one PNG per frame.
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("bucket-render-motion-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: dir) }
            var o = MotionRender.Options(anim: "absorb-1")
            o.fps = 30; o.scale = 1
            let summary = MotionRender.export(o, to: dir)
            let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("frame-") && $0.hasSuffix(".png") }.sorted()
            let expected = (Motion.Absorb.barBounce.end + MotionRender.lead + MotionRender.tail) / 1000 * o.fps
            check("render-motion absorb-1: \(files.count) frames = duration × fps (\(String(format: "%.1f", expected)) ± 1)",
                  summary != nil && abs(Double(files.count) - expected) <= 1 && summary?.frames == files.count)
            // Pixels that differ from the background (the corner pixel), per frame.
            func ink(_ name: String) -> Int {
                guard let rep = NSBitmapImageRep(data: (try? Data(contentsOf: dir.appendingPathComponent(name))) ?? Data()), let px = rep.bitmapData else { return 0 }
                let bpp = rep.bitsPerPixel / 8, row = rep.bytesPerRow
                let bg = (px[0], px[1], px[2]) // the corner is always background
                var n = 0
                for y in 0 ..< rep.pixelsHigh { for x in 0 ..< rep.pixelsWide {
                    let q = px + y * row + x * bpp
                    if abs(Int(q[0]) - Int(bg.0)) + abs(Int(q[1]) - Int(bg.1)) + abs(Int(q[2]) - Int(bg.2)) > 6 { n += 1 }
                } }
                return n
            }
            let inks = files.map(ink)
            check("render-motion absorb-1: no frame is empty (the cursor is always drawn; fewest ink pixels \(inks.min() ?? 0))", !inks.isEmpty && inks.allSatisfy { $0 > 0 })
            let first = files.first.flatMap { try? Data(contentsOf: dir.appendingPathComponent($0)) }
            let last = files.last.flatMap { try? Data(contentsOf: dir.appendingPathComponent($0)) }
            check("render-motion absorb-1: the first and the last frame differ, the pill is only in the last (ink \(inks.first ?? 0) → \(inks.last ?? 0))",
                  first != nil && last != nil && first != last && (inks.last ?? 0) > (inks.first ?? 0) * 3)
        }

        print("companion-check: \(total - failed)/\(total) passed")
        return failed == 0 ? 0 : 1
    }
}
