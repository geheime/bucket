import AppKit
import BucketCore
import QuartzCore

/// `Bucket motion-smoke`: builds every animated move of the companion on detached layers and validates the tracks
/// (Core Animation drops a malformed keyframe animation silently, so a typo here would only show up as "nothing moves").
/// Headless: no window, no Screen Recording. Exit 1 on any malformed track.
enum MotionSmoke {
    static func run() -> Int32 {
        _ = NSApplication.shared
        var problems: [String] = []
        var tracks = 0

        func walk(_ l: CALayer, _ name: String) {
            for key in l.animationKeys() ?? [] {
                guard let a = l.animation(forKey: key) else { continue }
                tracks += 1
                if a.duration <= 0 { problems.append("\(name).\(key): duration \(a.duration)") }
                if let k = a as? CAKeyframeAnimation, k.path == nil {
                    let n = k.values?.count ?? 0
                    if n < 2 { problems.append("\(name).\(key): \(n) values") }
                    if let t = k.keyTimes {
                        if t.count != n { problems.append("\(name).\(key): \(n) values vs \(t.count) keyTimes") }
                        let d = t.map(\.doubleValue)
                        if d.first != 0 || d.last != 1 { problems.append("\(name).\(key): keyTimes must span 0…1 (\(d))") }
                        if zip(d, d.dropFirst()).contains(where: { $1 < $0 }) { problems.append("\(name).\(key): keyTimes not sorted \(d)") }
                    }
                    if let f = k.timingFunctions, f.count != n - 1 { problems.append("\(name).\(key): \(f.count) timing functions for \(n) values") }
                }
            }
            for s in l.sublayers ?? [] { walk(s, name) }
            if let m = l.mask { walk(m, name + ".mask") }
        }
        func check(_ name: String, _ rig: PillRig) {
            walk(rig.canvas, name)
            rig.mirrors.forEach { walk($0.layer, name + ".mirror") }
            if let m = rig.liveMask { walk(m, name + ".liveMask") }
        }

        for h in [PillSide.H.right, .left] {
            let side = PillSide(h: h, v: .below)
            func fresh() -> PillRig {
                let rig = PillRig(dark: false, opaqueMaterial: false)
                let live = CAShapeLayer(); rig.liveMask = live
                rig.mirrors = [(CALayer(), -1)]
                return rig
            }
            for (b, a) in [(0, 1), (1, 2), (2, 3), (3, 4), (4, 5)] {
                let rig = fresh()
                rig.apply(PillState(side: side, form: .expanded, text: "", number: "", glyph: GlyphState(count: b)))
                rig.absorb(before: b, after: a, base: Anim.now, reduce: false)
                check("absorb \(b)→\(a) \(h)", rig)
            }
            for n in [1, 2, 3, 4, 9] {
                for form in [CompanionModel.Form.compact, .expanded] {
                    let rig = fresh()
                    let from = PillState(side: side, form: form, text: CompanionCopy.count(n), number: "\(n)", glyph: GlyphState(count: n))
                    rig.apply(from)
                    rig.release(shots: n, from: from, base: Anim.now, reduce: false)
                    check("release \(n) \(form) \(h)", rig)
                }
            }
            for n in [1, 3, 5] {
                let rig = fresh()
                rig.refill(count: n, base: Anim.now, reduce: false)
                check("refill \(n) \(h)", rig)
            }
            let rig = fresh()
            let a = PillState(side: side, form: .expanded, text: "3 in bucket", number: "3", glyph: .three)
            var c = a; c.form = .compact
            rig.morph(from: a, to: c, base: Anim.now, reduce: false); check("compact \(h)", rig)
            let r2 = fresh(); r2.morph(from: c, to: a, base: Anim.now, reduce: false); check("expand \(h)", r2)
            let r3 = fresh(); r3.apply(a); r3.flightOut(Motion.Pill.vanishFly, tail: Motion.Pill.vanishFade, base: Anim.now); check("flightOut \(h)", r3)
            let r6 = fresh(); r6.apply(a); r6.exitInPlace(Motion.Release.exit, scale: Motion.Release.exitScale, base: Anim.now); check("exitInPlace \(h)", r6)
            let r4 = fresh(); r4.apply(a); r4.flightIn(Motion.Pill.dropFromBar, base: Anim.now); check("flightIn \(h)", r4)
            let r5 = fresh(); r5.apply(a); r5.slide(by: CGPoint(x: 40, y: 3), base: Anim.now); check("slide \(h)", r5)
        }
        problems.forEach { print("problem: \($0)") }
        print("motion-smoke: \(tracks) tracks, \(problems.count) problems")
        return problems.isEmpty ? 0 : 1
    }
}
