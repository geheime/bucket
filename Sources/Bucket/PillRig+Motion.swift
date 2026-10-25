import AppKit
import BucketCore
import QuartzCore

/// The animated moves of the companion, one per gesture (absorb, transitions, release,
/// bordes). Every function leaves the model in the FINAL state of its move and adds tracks that show what comes
/// before it, so interrupting (`removeAllAnimations`) lands on the final state, as required.
/// `base` is the t = 0 of the event in media time.
extension PillRig {
    // MARK: Group tracks (the pill as a whole; mirrored on the live material)

    func groupTrack(_ key: String, _ make: (CGFloat) -> CAAnimation) {
        group.add(make(1), forKey: key)
        for m in mirrors { m.layer.add(make(m.flipY), forKey: key) }
    }

    /// opacity 0→1 and rise `rise` pt (starts below, moves up).
    func enter(_ step: Motion.Step, rise: Double, base: CFTimeInterval) {
        groupTrack("enter-o") { _ in Anim.basic("opacity", from: 0, to: 1, step, base: base) }
        if rise != 0 {
            groupTrack("enter-y") { s in Anim.basic("position.y", from: rise * Double(s), to: 0, step, base: base, additive: true) }
        }
    }

    /// Reduce Motion: every change of state is a linear crossfade of 160 ms.
    func crossfadeIn(base: CFTimeInterval) {
        groupTrack("enter-o") { _ in Anim.basic("opacity", from: 0, to: 1, Motion.Reduced.crossfade, base: base) }
    }

    func fadeIn(_ step: Motion.Step, base: CFTimeInterval) {
        groupTrack("enter-o") { _ in Anim.basic("opacity", from: 0, to: 1, step, base: base) }
    }

    /// The canvas jumped to the other side of the cursor in the same frame: slide the pill from where it was.
    func slide(by delta: CGPoint, base: CFTimeInterval) {
        groupTrack("slide") { s in Anim.basic("position", from: NSValue(point: CGPoint(x: delta.x, y: delta.y * s)), to: NSValue(point: .zero),
                                              Motion.Pill.sideSwitch, base: base, additive: true) }
    }

    // MARK: Shape + glyph tracks

    struct Frame {
        var at: Double                 // ms from t = 0
        var rect: CGRect
        var radius: CGFloat
        var glyphPos: CGPoint
        var glyphScale: CGFloat
        var curve: Motion.Curve        // easing of the segment that STARTS here
    }

    /// Frame of a resting state, for `shapeTrack`.
    func frame(_ s: PillState, at: Double, curve: Motion.Curve = .linear) -> Frame {
        let r = rect(for: s)
        return Frame(at: at, rect: r, radius: radius(for: s.form), glyphPos: CGPoint(x: r.minX + 4, y: r.midY),
                     glyphScale: s.form == .expanded ? 1 : CGFloat(Motion.Pill.compactGlyphScale), curve: curve)
    }

    /// Animates capsule + glyph box through `frames`. The model must already be the last frame.
    func shapeTrack(_ frames: [Frame], base: CFTimeInterval) {
        guard frames.count >= 2, let first = frames.first, let last = frames.last else { return }
        let total = last.at - first.at
        let times = frames.map { ($0.at - first.at) / total }
        let curves = frames.dropLast().map(\.curve)
        let sets = frames.map { shapeTargets(from: ($0.rect, $0.radius), to: ($0.rect, $0.radius)) }
        for (i, target) in sets[0].enumerated() {
            let values: [Any] = sets.map { $0[i].2 }
            let a = Anim.keyframes(target.1, values: values, times: times, start: first.at, dur: total, curves: curves, base: base)
            target.0.add(a, forKey: "shape")
        }
        place.add(Anim.keyframes("position", values: frames.map { NSValue(point: $0.glyphPos) }, times: times, start: first.at, dur: total,
                                 curves: curves, base: base), forKey: "place-pos")
        place.add(Anim.keyframes("transform.scale", values: frames.map { $0.glyphScale }, times: times, start: first.at, dur: total,
                                 curves: curves, base: base), forKey: "place-scale")
    }

    // MARK: Compact · expand

    /// Applies `to` as the model and animates from `from`. Used for compact (240) and expand (200).
    func morph(from: PillState, to: PillState, base: CFTimeInterval, reduce: Bool) {
        apply(to)
        if reduce { crossfadeIn(base: base); return }
        let compacting = to.form == .compact
        let step = compacting ? Motion.Pill.compact : Motion.Pill.expand
        shapeTrack([frame(from, at: 0, curve: step.curve), frame(to, at: step.dur)], base: base)
        // Texts: compact fades the words out (0–120) then the number in (120–240); expand brings the words in 80–200
        // after the number is gone.
        let d = step.dur
        if compacting {
            let t = Motion.Pill.compactTextFade.to / d, n = Motion.Pill.compactNumberFade.from / d
            textNew.add(Anim.keyframes("opacity", values: [1, 0, 0], times: [0, t, 1], dur: d, base: base), forKey: "morph")
            number.add(Anim.keyframes("opacity", values: [0, 0, 1], times: [0, n, 1], dur: d, base: base), forKey: "morph")
        } else {
            let t = Motion.Pill.expandTextFade.from / d
            textNew.add(Anim.keyframes("opacity", values: [0, 0, 1], times: [0, t, 1], dur: d, base: base), forKey: "morph")
            number.add(Anim.keyframes("opacity", values: [1, 0, 0], times: [0, t, 1], dur: d, base: base), forKey: "morph")
        }
    }

    // MARK: Absorb

    /// A shot lands in the bucket. `before`/`after` are the counts around it. Everything happens inside the pill:
    /// the glyph squashes, the new stripe grows and the words crossfade to the new count. The model is expanded with the new count.
    func absorb(before: Int, after: Int, base: CFTimeInterval, reduce: Bool) {
        let side = state.side
        apply(PillState(side: side, form: .expanded, text: CompanionCopy.count(after), number: "\(after)", glyph: GlyphState(count: after)))
        if reduce { crossfadeIn(base: base); return }
        let A = Motion.Absorb.self
        enter(A.pillEnter, rise: A.pillEnterRise, base: base)

        // 5 · the count crossfades: the old words stay until the crossfade starts, the new ones are the model.
        textOld.string = CompanionCopy.count(before)
        textOld.frame.size.width = PillFont.width(CompanionCopy.count(before), PillFont.pill) + 2
        let x = A.countCrossfade, u = x.start / x.end
        textOld.add(Anim.keyframes("opacity", values: [1, 1, 0], times: [0, u, 1], dur: x.end, base: base), forKey: "cut")
        textNew.add(Anim.keyframes("opacity", values: [0, 0, 1], times: [0, u, 1], dur: x.end, base: base), forKey: "cut")

        // 3 · squash of the bucket, anchored 50 % · 92 % of the glyph.
        setAnchor(squash, CGFloat(A.squashAnchor.x), CGFloat(A.squashAnchor.y), in: place)
        let keys = A.squashKeys
        let times = keys.map(\.at)
        squash.add(Anim.keyframes("transform.scale.x", values: keys.map(\.x), times: times, start: A.squash.start, dur: A.squash.dur, base: base), forKey: "squash-x")
        squash.add(Anim.keyframes("transform.scale.y", values: keys.map(\.y), times: times, start: A.squash.start, dur: A.squash.dur, base: base), forKey: "squash-y")

        // 4 · the new stripe grows from its bottom (or the block, when the bucket goes from 3 to 4).
        let g = A.stripeGrow
        func grow(_ l: CAShapeLayer, overshoot: Double) {
            let at = A.stripeOvershootAt
            l.add(Anim.keyframes("transform.scale.y", values: [0, overshoot, 1], times: [0, at, 1], start: g.start, dur: g.dur,
                                 curves: [g.curve, g.curve], base: base), forKey: "grow")
            l.add(Anim.keyframes("opacity", values: [A.stripeOpacityFrom, 1], times: [0, 1], start: g.start, dur: g.dur, curves: [g.curve], base: base), forKey: "grow-o")
        }
        if after >= 1 && after <= 3 && after > before { grow(stripes[after - 1], overshoot: A.stripeOvershoot) }
        else if after >= 4 && before <= 3 {
            grow(full, overshoot: A.stripeOvershoot)
            for i in 0 ..< 3 where i < before {          // the old stripes stay until the block takes over
                stripes[i].isHidden = false
                stripes[i].opacity = 0
                stripes[i].add(Anim.hold("opacity", 1, until: g.start, base: base), forKey: "old")
            }
        }
    }

    // MARK: Release

    /// x, in the glyph box, of the center of the glyph's ink once the box is rotated by `theta` about its base-center.
    /// The slide of the release ends where this lands on the middle of the capsule.
    func inkCenterX(rotatedBy theta: CGFloat) -> CGFloat {
        let G = PillRig.expandedGlyph, k = G / 64
        let ax = G * CGFloat(Motion.Release.tiltAnchor.x), ay = G * CGFloat(Motion.Release.tiltAnchor.y)
        var t = master.affineTransform()
            .concatenating(CGAffineTransform(translationX: -ax, y: -ay))
            .concatenating(CGAffineTransform(rotationAngle: theta))
            .concatenating(CGAffineTransform(translationX: ax, y: ay))
        var ink = CGRect.null
        for l in [handle, body, lip] {
            if let p = l.path?.copy(using: &t) { ink = ink.union(p.boundingBox.insetBy(dx: -l.lineWidth * k / 2, dy: 0)) }
        }
        return ink.isNull ? G / 2 : ink.midX
    }

    /// The promise was cashed. `from` is the pill as it was (compact or expanded, with `n` in the bucket); the model ends as
    /// the expanded pill saying "Pasted n" with an empty glyph. Everything happens inside the capsule: the words go,
    /// the glyph slides to the middle and tilts toward the cursor, the stripes empty into it one by one, it comes back upright
    /// and slides home while the words change.
    func release(shots n: Int, from: PillState, base: CFTimeInterval, reduce: Bool) {
        let side = from.side
        let R = Motion.Release.self
        let startText = CompanionCopy.count(n)
        let initial = PillState(side: side, form: .expanded, text: startText, number: "\(n)", glyph: GlyphState(count: n))
        let final = PillState(side: side, form: .expanded, text: CompanionCopy.pasted(n), number: "\(n)", glyph: .empty)
        let pouring = min(n, R.maxPouring)

        apply(final)
        // The stripes that empty must exist (opacity animates; `isHidden` would not).
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, s) in stripes.enumerated() { s.isHidden = i >= pouring; s.opacity = 0 }
        full.isHidden = n <= 3 ? true : false
        full.opacity = 0
        CATransaction.commit()

        if reduce {
            // "Pasted N" by crossfade 160, wait 700, off 160 (the caller does the last two).
            textOld.string = startText
            textOld.add(Anim.basic("opacity", from: 1, to: 0, Motion.Reduced.crossfade, base: base), forKey: "rm")
            textNew.add(Anim.basic("opacity", from: 0, to: 1, Motion.Reduced.crossfade, base: base), forKey: "rm")
            for s in stripes where !s.isHidden { s.add(Anim.basic("opacity", from: 1, to: 0, Motion.Reduced.crossfade, base: base), forKey: "rm") }
            if !full.isHidden { full.add(Anim.basic("opacity", from: 1, to: 0, Motion.Reduced.crossfade, base: base), forKey: "rm") }
            return
        }

        // 2 · expand if it was resting compact. 3 · the glyph slides to the horizontal center of the capsule, placed so that the
        // glyph TILTED toward the cursor is the thing centered (the tilt pivots about the base, which would push it sideways).
        // 9 · back upright, it slides home to the left while the pill narrows to fit "Pasted n".
        let wasCompact = from.form == .compact
        let theta = (side.h == .right ? -1.0 : 1.0) * R.tiltDegrees * .pi / 180 // + = clockwise; the cursor is on the left of a right pill
        let ci = frame(PillState(side: side, form: .compact, text: startText, number: "\(n)", glyph: .empty), at: 0, curve: R.expand.curve)
        var ini = frame(initial, at: 0)
        ini.glyphPos = CGPoint(x: ini.rect.midX - inkCenterX(rotatedBy: CGFloat(theta)), y: ini.rect.midY)
        let centered = ini.glyphPos
        var frames: [Frame] = []
        if wasCompact { frames.append(ci) } else { frames.append(frame(initial, at: 0)) }
        frames[0].curve = wasCompact ? R.expand.curve : .linear
        frames.append(frame(initial, at: R.slide.start, curve: R.slide.curve)) // resting, then slides
        var there = frame(initial, at: R.slide.end); there.glyphPos = centered // arrived: stays until it turns back
        frames.append(there)
        var back = frame(initial, at: R.slideBack.start, curve: R.slideBack.curve); back.glyphPos = centered
        frames.append(back)
        frames.append(frame(final, at: R.slideBack.end))
        shapeTrack(frames, base: base)

        // Texts: the count goes out (0–120) before anything moves; "Pasted n" comes in as the glyph heads home.
        textOld.string = startText
        textOld.frame = CGRect(x: ini.rect.minX + 40, y: ini.rect.midY - 8, width: PillFont.width(startText, PillFont.pill) + 2, height: 16)
        if wasCompact {
            number.frame.origin.x = ci.rect.minX + 32
            number.frame.origin.y = ci.rect.midY - 8
            number.add(Anim.keyframes("opacity", values: [1, 0, 0], times: [0, 80 / 200.0, 1], dur: R.expand.dur, base: base), forKey: "n")
        } else {
            textOld.add(Anim.basic("opacity", from: 1, to: 0, R.textOff, base: base), forKey: "old")
        }
        let back2 = R.textBack
        textNew.add(Anim.keyframes("opacity", values: [0, 0, 1], times: [0, back2.start / back2.end, 1], dur: back2.end, base: base), forKey: "new")

        // 4 · tilt toward the cursor, already centered, about the bottom-center of the glyph, by an angle at which the rotated
        // bucket still fits in the capsule (companion-check). 8 · back upright.
        let tl = R.tilt, un = R.untilt
        tilt.add(Anim.keyframes("transform.rotation.z", values: [0, 0, theta, theta, 0],
                                times: [0, tl.start / un.end, tl.end / un.end, un.start / un.end, 1],
                                dur: un.end, curves: [.linear, tl.curve, .linear, un.curve], base: base), forKey: "tilt")

        // 5–7 · the stripes empty into the glyph one by one, top first (fade + shrink toward their base). The block (N > 3)
        // is swapped for the three stripes under cover of the tilt.
        if n > 3 {
            full.add(Anim.keyframes("opacity", values: [1, 1, 0], times: [0, tl.start / (tl.start + 1), 1], dur: tl.start + 1, base: base), forKey: "block")
        }
        for j in 0 ..< pouring {
            let i = pouring - 1 - j                      // top stripe first
            let step = R.pour(j)
            let s = stripes[i]
            var vals: [Double] = [1, 1, 0]
            var tms: [Double] = [0, step.start / step.end, 1]
            if n > 3 { // the block is on screen until the tilt starts; the stripes take over under the turn
                vals = [0, 0, 1, 1, 0]
                tms = [0, tl.start / step.end, (tl.start + 1) / step.end, step.start / step.end, 1]
            }
            s.add(Anim.keyframes("opacity", values: vals, times: tms, dur: step.end, base: base), forKey: "pour-o")
            s.add(Anim.keyframes("transform.scale.y", values: [1, 1, R.pourScaleY], times: [0, step.start / step.end, 1], dur: step.end,
                                 curves: [.linear, step.curve], base: base), forKey: "pour-s")
        }

        // 10 · relief of the bucket: rises 3, squashes and settles, anchored bottom-center.
        let rl = R.relief
        setAnchor(relief, CGFloat(R.reliefAnchor.x), CGFloat(R.reliefAnchor.y), in: tilt)
        let rk = R.reliefKeys
        relief.add(Anim.sampled("transform.scale.x", rl, base: base, backwards: false) { Anim.lerp(rk.map { ($0.at, $0.x) }, $0) }, forKey: "relief-x")
        relief.add(Anim.sampled("transform.scale.y", rl, base: base, backwards: false) { Anim.lerp(rk.map { ($0.at, $0.y) }, $0) }, forKey: "relief-y")
        let rise = Double(R.reliefRise)
        relief.add(Anim.sampled("position.y", rl, base: base, backwards: false, additive: true) { u in
            -rise * Anim.lerp([(0, 0), (0.40, 1), (0.75, 0), (1, 0)], u)
        }, forKey: "relief-up")
    }

    /// The whole pill goes where it is, opacity 1→0 and scale 1→`scale` about its own center. No flight.
    /// The model ends invisible; `hide()` (which resets every layer) comes right after.
    func exitInPlace(_ step: Motion.Step, scale: Double, base: CFTimeInterval) {
        let r = rect(for: state)
        let h = canvas.bounds.height
        CATransaction.begin(); CATransaction.setDisableActions(true)
        group.opacity = 0
        for m in mirrors { m.layer.opacity = 0 }
        CATransaction.commit()
        groupTrack("exit-o") { _ in Anim.basic("opacity", from: 1, to: 0, step, base: base) }
        groupTrack("exit-s") { s in
            let c = CGPoint(x: r.midX, y: s == 1 ? r.midY : h - r.midY) // the live mirrors are y-up
            var t = CATransform3DMakeTranslation(c.x, c.y, 0)
            t = CATransform3DScale(t, CGFloat(scale), CGFloat(scale), 1)
            t = CATransform3DTranslate(t, -c.x, -c.y, 0)
            return Anim.basic("transform", from: NSValue(caTransform3D: CATransform3DIdentity), to: NSValue(caTransform3D: t), step, base: base)
        }
    }

    // MARK: Re-copy with an empty bucket

    /// Empty bucket re-copied: the pill appears at the cursor with an empty glyph and refills one stripe at a time.
    func refill(count n: Int, base: CFTimeInterval, reduce: Bool) {
        let side = state.side
        apply(PillState(side: side, form: .expanded, text: CompanionCopy.recopied(n), number: "\(n)", glyph: GlyphState(count: n)))
        if reduce { crossfadeIn(base: base); return }
        enter(Motion.Pill.appear, rise: Motion.Pill.appearRise, base: base)
        let E = Motion.Edges.self
        let layers: [CAShapeLayer] = n >= 4 ? [full] : Array(stripes.prefix(n))
        for (i, l) in layers.enumerated() {
            let st = Motion.Step(E.recopyFill.start + Double(i) * E.recopyFillStagger, E.recopyFill.dur, E.recopyFill.curve)
            l.add(Anim.keyframes("transform.scale.y", values: [0, E.recopyStripeOvershoot, 1], times: [0, 0.6, 1], start: st.start, dur: st.dur,
                                 curves: [st.curve, st.curve], base: base), forKey: "refill")
            l.add(Anim.keyframes("opacity", values: [0, 1], times: [0, 1], start: st.start, dur: st.dur, curves: [st.curve], base: base), forKey: "refill-o")
        }
    }

    // MARK: Words changing in place (feedback while already expanded)

    func swapText(from old: String, base: CFTimeInterval) {
        textOld.string = old
        textOld.frame.size.width = PillFont.width(old, PillFont.pill) + 2
        textOld.add(Anim.basic("opacity", from: 1, to: 0, Motion.Reduced.crossfade, base: base), forKey: "swap")
        textNew.add(Anim.basic("opacity", from: 0, to: 1, Motion.Reduced.crossfade, base: base), forKey: "swap")
    }

    /// Top stripe goes out in 160 ms linear ("Send last to Desktop", quitar): the glyph is already at its new count.
    func dropTopStripe(previousCount: Int, base: CFTimeInterval) {
        guard previousCount >= 1, previousCount <= 3 else { return }
        let s = stripes[previousCount - 1]
        s.isHidden = false
        s.opacity = 0
        s.add(Anim.basic("opacity", from: 1, to: 0, Motion.Edges.sentStripeOff, base: base), forKey: "off")
    }
}

// MARK: Flight to the bar (the glyph itself travels in `BarFlight`; this is what the pill does meanwhile)

extension PillRig {
    /// Center (canvas, y-down) and side in pt of the glyph as it is now.
    func glyphBox() -> (center: CGPoint, size: CGFloat) {
        let c = place.convert(CGPoint(x: PillRig.expandedGlyph / 2, y: PillRig.expandedGlyph / 2), to: canvas)
        return (c, PillRig.expandedGlyph * place.affineTransform().a)
    }

    /// The pill leaves: its glyph is handed to the flight window, the words go out in the first half, material and shadow
    /// fade out (over the flight, plus `tail` ms when there is a separate fade, as after releasing).
    func flightOut(_ step: Motion.Step, tail: Motion.Step?, base: CFTimeInterval) {
        let total = step.dur + (tail?.dur ?? 0)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        place.opacity = 0
        texts.opacity = 0
        bgGroup.opacity = 0
        for m in mirrors { m.layer.opacity = 0 }
        CATransaction.commit()
        texts.add(Anim.keyframes("opacity", values: [1, 0, 0], times: [0, Motion.Pill.flyTextFadeUntil * step.dur / total, 1], dur: total, base: base), forKey: "fly")
        let fade = Anim.keyframes("opacity", values: [1, 1, 0], times: [0, step.dur / total, 1], dur: total, base: base)
        bgGroup.add(fade, forKey: "fly")
        for m in mirrors { m.layer.add(fade.copy() as! CAAnimation, forKey: "fly") }
    }

    /// Inverse: the pill arrives from the bar ("drop from the bar").
    func flightIn(_ step: Motion.Step, base: CFTimeInterval) {
        texts.add(Anim.keyframes("opacity", values: [0, 0, 1], times: [0, Motion.Pill.flyTextFadeUntil, 1], dur: step.dur, base: base), forKey: "fly")
        let fade = Anim.basic("opacity", from: 0, to: 1, step, base: base)
        bgGroup.add(fade, forKey: "fly")
        for m in mirrors { m.layer.add(fade.copy() as! CAAnimation, forKey: "fly") }
        place.add(Anim.hold("opacity", 0, until: step.dur, base: base), forKey: "fly")
    }
}
