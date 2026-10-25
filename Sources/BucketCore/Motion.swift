import QuartzCore

/// Every motion constant of the companion, keyboard overlay and bar, in one place.
/// One block per gesture (absorb, pill, release, keycaps, edges, panel); names map to the steps of each one.
/// Durations and starts are milliseconds from `t = 0`, the start of the gesture.
/// Sign convention: words win over numbers ("rises" = moves up on screen), because the design spec mixed CSS and AppKit signs.
public enum Motion {
    /// Cubic-bezier control points.
    public struct Curve: Equatable, Sendable {
        public let c1x: Float, c1y: Float, c2x: Float, c2y: Float
        public init(_ c1x: Float, _ c1y: Float, _ c2x: Float, _ c2y: Float) {
            self.c1x = c1x; self.c1y = c1y; self.c2x = c2x; self.c2y = c2y
        }
        public var timing: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: c1x, c1y, c2x, c2y) }

        // Named curves
        public static let outStrong = Curve(0.16, 1, 0.3, 1)
        public static let outQuart = Curve(0.25, 1, 0.5, 1)
        public static let inOutQuart = Curve(0.76, 0, 0.24, 1)
        public static let inQuart = Curve(0.5, 0, 0.75, 0)
        public static let fall = Curve(0.55, 0, 0.85, 0.35)
        public static let glide = Curve(0.45, 0, 0.25, 1)
        public static let springSoft = Curve(0.34, 1.56, 0.64, 1) // overshoot comes from the curve itself
        public static let linear = Curve(0, 0, 1, 1)

        /// Eased progress for a linear progress `t` in 0…1 (what a CSS/CA cubic-bezier does). Used to pre-sample keyframes
        /// whose easing applies to the whole timeline, since CA only eases per segment.
        public func ease(_ t: Double) -> Double {
            if t <= 0 { return 0 }
            if t >= 1 { return 1 }
            func bez(_ a: Double, _ b: Double, _ u: Double) -> Double { 3 * a * u * (1 - u) * (1 - u) + 3 * b * u * u * (1 - u) + u * u * u }
            func dbez(_ a: Double, _ b: Double, _ u: Double) -> Double { 3 * a * (1 - u) * (1 - u) + 6 * (b - a) * u * (1 - u) + 3 * (1 - b) * u * u }
            let x1 = Double(c1x), y1 = Double(c1y), x2 = Double(c2x), y2 = Double(c2y)
            var u = t
            for _ in 0 ..< 8 { // Newton on x(u) = t
                let d = dbez(x1, x2, u)
                if abs(d) < 1e-9 { break }
                u -= (bez(x1, x2, u) - t) / d
            }
            if !(0 ... 1).contains(u) || abs(bez(x1, x2, u) - t) > 1e-5 { // fall back to bisection
                var lo = 0.0, hi = 1.0
                u = t
                for _ in 0 ..< 40 { u = (lo + hi) / 2; if bez(x1, x2, u) < t { lo = u } else { hi = u } }
            }
            return bez(y1, y2, u)
        }
    }

    /// One step of a motion: when it starts, how long it lasts, which curve.
    public struct Step: Equatable, Sendable {
        public let start: Double, dur: Double, curve: Curve
        public init(_ start: Double, _ dur: Double, _ curve: Curve) { self.start = start; self.dur = dur; self.curve = curve }
        public var end: Double { start + dur }
        public var seconds: CFTimeInterval { dur / 1000 }
        public var delay: CFTimeInterval { start / 1000 }
    }

    /// Scale keyframes: (fraction of the duration, x, y).
    public struct ScaleKey: Equatable, Sendable {
        public let at: Double, x: Double, y: Double
        public init(_ at: Double, _ x: Double, _ y: Double) { self.at = at; self.x = x; self.y = y }
    }

    // Reduce Motion: no travel, squash, tilt or shake; every change is a linear crossfade
    public enum Reduced {
        public static let crossfade = Step(0, 160, .linear)
        public static let keycapsTotal = 1200.0
        public static let keycapsEdge = 0.15           // enters in the first 15 %, leaves in the last 15 %
        public static let pastedHold = 700.0           // "Pasted N" stays 700, then fades 160
    }

    // Absorb. t = 0: screencapture ended with a file. Everything happens INSIDE the pill.
    public enum Absorb {
        public static let pillEnter = Step(0, 180, .outStrong)         // pill fades in
        public static let pillEnterRise: Double = 4                    // opacity 0→1 · rises 4 pt
        public static let squash = Step(120, 420, .linear)             // glyph squash · linear keyframes
        public static let squashKeys = [ScaleKey(0, 1, 1), ScaleKey(0.20, 1.08, 0.90), ScaleKey(0.48, 0.97, 1.04),
                                        ScaleKey(0.74, 1.01, 0.99), ScaleKey(1, 1, 1)]
        public static let squashAnchor = (x: 0.50, y: 0.92)            // of the glyph
        public static let stripeGrow = Step(180, 260, .outStrong)      // new stripe grows · scaleY 0→1.25 @60 % →1 · opacity .4→1
        public static let stripeOvershoot: Double = 1.25
        public static let stripeOvershootAt: Double = 0.60
        public static let stripeOpacityFrom: Double = 0.4
        public static let countCrossfade = Step(180, 160, .linear)     // "N in bucket" → "N+1 in bucket"
        public static let barBounce = Step(440, 260, .springSoft)      // bar icon bounce · the image changes at the start (the stripe has already grown)
        public static let barBounceScale: Double = 1.25
        public static let compactAfter: Double = 1500                  // compacts 1500 ms after the bounce starts (440 + 1500), 240 ms long
        public static var compactStart: Double { barBounce.start + compactAfter }
        public static let cancelReturn = Step(0, 120, .outQuart)       // ESC: only the pill fade, if there was load
    }

    // Appear · compact · expand · switch side · fly to the bar
    public enum Pill {
        public static let appear = Step(0, 180, .outStrong)            // 0 → 1 shot: opacity · rises 4
        public static let appearRise: Double = 4
        public static let returnAfterEsc = Step(0, 120, .outQuart)     // coming back after ESC: opacity
        public static let compact = Step(0, 240, .inOutQuart)          // bounds 124×38 → 50×32, radius 19→16, glyph ×.8
        public static let compactGlyphScale: Double = 0.8
        public static let compactTextFade = (from: 0.0, to: 120.0)     // text opacity 1→0 (0–120)
        public static let compactNumberFade = (from: 120.0, to: 240.0) // number opacity 0→1 (120–240)
        public static let expand = Step(0, 200, .outStrong)            // inverse of compact; text enters 80–200
        public static let expandTextFade = (from: 80.0, to: 200.0)
        public static let sideSwitch = Step(0, 160, .outStrong)        // switching side: the pill's position in the canvas
        public static let vanishFly = Step(0, 260, .inQuart)           // vanishing (empty bucket): flight + opacity in 60
        public static let vanishFade = Step(260, 60, .linear)
        public static let flyToBarRest = Step(0, 420, .inOutQuart)     // flight to the bar (Keep in menu bar)
        public static let flyTextFadeUntil: Double = 0.5               // the text fades out in the first half
        public static let barArrival = Step(0, 260, .springSoft)       // arrival: the template glyph bounces 1→1.25→1
        public static let dropFromBar = Step(0, 340, .outStrong)       // dropping from the bar (⌘V with Keep in menu bar)
        public static let flightGlyphSize: Double = 18                 // the glyph lands at 18 pt (travels 30 → 18)
        public static let panelOpenFade = Step(0, 120, .linear)        // with the panel open, fade 120
    }

    // Behavior timings (not animations themselves, but they live next to them)
    public enum Behavior {
        public static let settleAfter: Double = 1500                   // compacts 1500 ms after the last event
        public static let flashHold: Double = 700                      // Keep in menu bar: waits 700, then flies to the bar
        public static let followSmoothing: Double = 0.5                // pos += (target − pos) × 0.5
        public static let followHz: Double = 60
        public static let followEpsilon: Double = 0.5                  // Δ < 0.5 pt does not touch the frame
        public static let edgeHysteresis: Double = 24
        public static let edgeMargin: Double = 8
        public static let cursorOffset: Double = 18                    // below-right of the hotspot
    }

    // Release. t = 0: the clipboard promise is collected. Everything happens INSIDE the pill.
    public enum Release {
        public static let expand = Step(0, 200, .outStrong)            // only if it was compact
        public static let textOff = Step(0, 120, .linear)              // the text turns off (opacity 1→0)
        public static let slide = Step(200, 200, .outQuart)            // the glyph slides to the center of the capsule
        public static let tilt = Step(slide.end, 220, .inOutQuart)     // 0 → tiltDegrees toward the cursor, centered
        public static let tiltDegrees: Double = 45
        public static let tiltAnchor = (x: 0.50, y: 0.90)              // bottom-center of the glyph
        public static let pourTop = Step(tilt.end, 160, .outStrong)    // the top stripe pours into the glyph
        public static let pourStagger: Double = 115                    // the next ones, top to bottom
        public static let pourScaleY: Double = 0.4                     // scaleY 1→.4 (anchored at the bottom) while opacity 1→0
        public static let untilt = Step(1040, 240, .inOutQuart)        // upright and empty (30 ms after the last stripe)
        public static let slideBack = Step(untilt.start + 120, 200, .outQuart) // back to its place on the left; the pill narrows
        public static let textBack = Step(slideBack.start, 160, .linear) // "Pasted N" (160 crossfade, the same as Reduce Motion)
        public static let relief = Step(untilt.end, 300, .outStrong)   // relief: a small settle once it is empty
        public static let reliefRise: Double = 3                       // translateY −3 (rises)
        public static let reliefKeys = [ScaleKey(0, 1, 1), ScaleKey(0.40, 1.03, 0.98), ScaleKey(0.75, 0.99, 1.01), ScaleKey(1, 1, 1)]
        public static let reliefAnchor = (x: 0.50, y: 1.0)             // bottom-center of the glyph
        public static let pastedHold: Double = 900                     // "Pasted N" stays readable (counted from when it starts entering)
        public static let exit = Step(textBack.start + pastedHold, 200, .inOutQuart) // the pill leaves in place
        public static let exitScale: Double = 0.92                     // scale 1→.92 + opacity 1→0, no flight to the bar
        public static let maxPouring = 3                               // with N > 3, 3 stripes always pour
        public static func pour(_ i: Int) -> Step {
            Step(pourTop.start + Double(min(max(i, 0), maxPouring - 1)) * pourStagger, pourTop.dur, pourTop.curve)
        }
    }

    // Keycaps
    public enum Keycaps {
        public static let total: Double = 1150
        public static let enter = Step(0, 138, .outStrong)             // 12 % of 1150: opacity · rises 6 · scale .96→1
        public static let enterRise: Double = 6
        public static let enterScaleFrom: Double = 0.96
        public static let press = Step(150, 150, .outQuart)            // scale 1→.92 (and drops 1 pt)→1, all together
        public static let pressScale: Double = 0.92
        public static let pressDrop: Double = 1
        public static let hold = (from: 138.0, to: 966.0)              // hold
        public static let exit = Step(966, 184, .outStrong)            // last 16 %: opacity→0 · drops 2 · scale→.98
        public static let exitDrop: Double = 2
        public static let exitScaleTo: Double = 0.98
    }

    // Edge cases: re-copy, send to Desktop, missing permission
    public enum Edges {
        public static let recopyFill = Step(180, 220, .outStrong)      // empty bucket: refills · stagger 70, anchored at the bottom
        public static let recopyFillStagger: Double = 70
        public static let recopyStripeOvershoot: Double = 1.2          // scaleY 0→1.2 @60 % →1
        public static let recopyGo = Step(180 + 1100, 260, .inQuart)   // empty bucket: leaves (flight + fade 60)
        public static let recopyHoldAfterFill: Double = 1100
        public static let sentStripeOff = Step(0, 160, .linear)        // Send last to Desktop: the top stripe turns off
        public static let permissionErrorAppear = Step(480, 180, .outStrong) // error pill: opacity · rises 4 · does not leave by itself
        public static let permissionShake = Step(160, 320, .linear)    // macOS-style "no" shake of the bar glyph · relative position.x
        public static let permissionShakeValues: [Double] = [0, -3, 3, -2, 2, -1, 0]
        public static let permissionSlash = Step(480, 120, .linear)    // the glyph becomes bucket.slash · opacity .3→1
        public static let permissionSlashFrom: Double = 0.3
    }

    // Panel and removal
    public enum Panel {
        public static let open = Step(0, 180, .outStrong)              // opacity 0→1 · scale .98→1 · translateY +4→0
        public static let openScaleFrom: Double = 0.98
        public static let openRise: Double = 4                         // comes down from the bar
        public static let close = Step(0, 120, .outQuart)              // opacity →0
        public static let hoverIn = Step(0, 120, .outQuart)            // × y "Show in Finder"
        public static let hoverOut = Step(0, 80, .outQuart)
        public static let copied = (fade: 120.0, hold: 1200.0)         // "Copy now" → "Copied" → "Copy now", crossfades linear
        public static let ocrFade = Step(0, 160, .linear)              // "Reading 2 shots…" ↔ "All shots searchable"
        public static let removeOut = Step(0, 200, .inQuart)           // removal: opacity 1→0 · scale 1→.96
        public static let removeScaleTo: Double = 0.96
        public static let reflow = Step(200, 220, .outStrong)          // the following ones reflow (FLIP)
        public static let sentFlash: Double = 1500                     // footer "Sent to Desktop", then it goes back
        public static let sentFade: Double = 120
    }
}
