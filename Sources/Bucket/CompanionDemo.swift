import AppKit
import BucketCore
import QuartzCore

/// `Bucket companion-demo [outdir]`: drives the live companion (real windows, no status item, no hotkeys) through the
/// events for ~12 s so a human or a script can look at it, and logs presentation-layer samples to check the timeline.
/// Not part of the product. Never screenshot it: the pill lives on the user's real screen.
enum CompanionDemo {
    static func run() -> Never {
        BucketPanel.visibleToCapture = true
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let companion = Companion(count: 0)
        let keycaps = KeycapOverlay(policy: KeycapPolicy(defaults: UserDefaults(suiteName: "bucket-demo-\(UUID().uuidString)")!))
        let screen = NSScreen.main!
        companion.statusFrame = { CGRect(x: screen.frame.maxX - 120, y: screen.frame.maxY - 24, width: 28, height: 24) }
        companion.barHold = { print("bar hold \($0)") }
        companion.barShow = { print("bar show bounce=\($0)") }

        var count = 0
        func shot(_ tag: String) {
            let before = count; count += 1
            companion.prepare(); companion.absorbed(before: before, after: count)
            keycaps.show(.capture, captureSymbols: ["⌘", "⇧", "4"])
            print("t=\(String(format: "%.2f", CACurrentMediaTime() - t0)) absorb \(before)→\(count) \(tag)")
        }
        let t0 = CACurrentMediaTime()
        var at: [(Double, () -> Void)] = [
            (0.3, { shot("first") }), (2.5, { shot("second") }), (4.2, { shot("third") }),
            (6.5, {
                companion.prepare(); count = 0; companion.pasted(3); keycaps.show(.paste, captureSymbols: [])
                print("t=\(String(format: "%.2f", CACurrentMediaTime() - t0)) pasted 3")
            }),
            (10.0, { companion.recopied(3, bucketCount: 0) }), (12.5, { print("demo done"); exit(0) }),
        ]
        at.sort { $0.0 < $1.0 }
        for (delay, block) in at { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block) }
        app.run()
        exit(0)
    }
}
