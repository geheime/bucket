import AppKit
import BucketCore

/// Screen recording: pick a region, run `screencapture -v -R… -k -x`, show the pill, stop or cancel, and hand the .mov to the
/// background circuit. Knows nothing about the bucket: it reports through the closures.
///
/// Measured (spike E, 06/11): `-R` records exactly that rect to our path; SIGINT is a clean stop (exit 0, playable file);
/// SIGTERM loses the file, so it is never sent. Without Screen Recording permission the child dies silently, with no file.
final class Recorder {
    enum Phase { case idle, picking, recording, reading }

    enum Outcome {
        /// Nothing was recorded (Esc or a click in the picker, or ✕).
        case cancelled
        /// No Screen Recording permission (checked up front, or the child died without a file).
        case permissionMissing
        case failed(String)
        /// `stoppedAtLimit`: the limit cut it (seconds), not the user.
        case recorded(Shot, stoppedAtLimit: Int?)
    }

    private(set) var phase = Phase.idle
    var isActive: Bool { phase != .idle }
    var isRecording: Bool { phase == .recording }

    private let library: Library
    private let picker = RegionPicker()
    private let border = RegionBorder()
    private let pill = RecPillPanel()
    private let reading = RecPillPanel()

    // Hooks set by the StatusController.
    /// Before anything shows: every other Bucket window goes off screen, the companion steps aside.
    var willPick: () -> Void = {}
    /// The picker is gone (picked or cancelled): windows that stayed may close on focus loss again.
    var pickerEnded: () -> Void = {}
    var permissionGranted: () -> Bool = { true }
    var finished: (Outcome) -> Void = { _ in }
    /// Recording started / ended: the menu title changes with it.
    var onPhase: () -> Void = {}

    // The run in progress.
    private var process: Process?
    private var tmp: URL?
    private var region = RecordingSidecar.Region(x: 0, y: 0, w: 0, h: 0)
    private var startedAt = Date()
    private var limit: Int?
    private var frontBundleId: String?
    private var timer: Timer?
    private var stopping = false
    private var cancelling = false
    private var stoppedByLimit = false
    private var elapsedAtStop: Double = 0

    init(library: Library) {
        self.library = library
        pill.onStop = { [weak self] in self?.stop() }
        pill.onCancel = { [weak self] in self?.cancel() }
        Recorder.sweepLeftovers()
        // Quitting Bucket must not leave a recording nobody can stop.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            if let pid = self?.process?.processIdentifier, self?.process?.isRunning == true { kill(pid, SIGINT) }
        }
    }

    private func set(_ p: Phase) { phase = p; onPhase() }

    /// Raw recordings a dead Bucket left in the temporary folder (unredacted screen content). Only older than the longest
    /// possible recording, so another Bucket recording right now is never touched.
    static func sweepLeftovers() {
        let fm = FileManager.default, dir = fm.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-Double(RecordingLimit.hardCapNoLimit + 600))
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix("bucket-rec-") && name.hasSuffix(".mov") {
            let url = dir.appendingPathComponent(name)
            if let m = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, m < cutoff { try? fm.removeItem(at: url) }
        }
    }

    // MARK: ⌘⇧6

    /// The shortcut: idle → pick a region and record; recording → stop. While picking or reading it does nothing (Esc cancels the pick).
    func toggle() {
        switch phase {
        case .idle: begin()
        case .recording: stop()
        case .picking, .reading: break
        }
    }

    private func begin() {
        guard permissionGranted() else { finished(.permissionMissing); return }
        frontBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        set(.picking)
        willPick()
        CATransaction.flush()
        DispatchQueue.main.async { [weak self] in
            self?.picker.begin { rect, screen in self?.picked(rect, on: screen) }
        }
    }

    private func picked(_ rect: CGRect?, on screen: NSScreen?) {
        pickerEnded()
        guard let rect, let screen else { set(.idle); finished(.cancelled); return }
        // The overlay is already out; one more turn so the window server has really removed it before screencapture looks.
        CATransaction.flush()
        DispatchQueue.main.async { [weak self] in self?.launch(rect, on: screen) }
    }

    // MARK: Recording

    private func launch(_ rect: CGRect, on screen: NSScreen) {
        let mainHeight = (NSScreen.screens.first ?? screen).frame.height
        region = RecordingRegion.screencaptureRect(rect, mainHeight: mainHeight)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bucket-rec-\(UUID().uuidString).mov")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // No -V: with -v -R it broke the recording (hand-test 06/11, no file). A hard cap for a dead Bucket is still owed.
        p.arguments = ["-v", "-R" + RecordingRegion.argument(region), "-k", "-x", file.path]
        let err = Pipe()
        p.standardError = err
        p.terminationHandler = { [weak self] proc in
            let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async { self?.ended(status: proc.terminationStatus, stderr: text) }
        }
        do { try p.run() } catch {
            set(.idle)
            finished(.failed(error.localizedDescription))
            return
        }
        process = p; tmp = file
        startedAt = Date(); limit = RecordingLimit.current().seconds
        stopping = false; cancelling = false; stoppedByLimit = false
        set(.recording)

        border.show(region: rect, screen: screen)
        let visible = screen.visibleFrame
        pill.show(kind: .recording, text: RecordingClock.format(0)) { size in
            let placed = RecPillPlacement.place(region: rect, pill: size, visible: visible)
            if placed.place == .inside { NSLog("Bucket: the region fills the screen; the pill sits on the content (sharingType none keeps it out of the video)") }
            return placed.frame
        }
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var elapsed: Double { Date().timeIntervalSince(startedAt) }

    private func tick() {
        guard phase == .recording, !stopping else { return }
        if RecordingClock.reachedLimit(elapsed: elapsed, limit: limit) { stoppedByLimit = true; stop(); return }
        pill.setTime(RecordingClock.display(elapsed: elapsed, limit: limit).text)
    }

    /// The pill's stop, ⌘⇧6 again, or the limit: cut cleanly and process what was recorded.
    func stop() {
        guard phase == .recording, !stopping else { return }
        stopping = true
        elapsedAtStop = elapsed
        interruptWhenReady { [weak self] in
            guard let self else { return }
            self.dismissRecordingUI()
            self.showReading(seconds: self.elapsedAtStop)
        }
    }

    /// ✕: cut, wait for the end, throw the file away. Nothing reaches the bucket. Esc does NOT do this: registering Esc globally
    /// would take it from the app being recorded.
    func cancel() {
        guard phase == .recording, !stopping else { return }
        stopping = true; cancelling = true
        interruptWhenReady { [weak self] in self?.dismissRecordingUI() }
    }

    /// SIGINT, never SIGTERM. Too early (before screencapture has its handler) it would lose the file, so a stop in the first
    /// second waits for the rest of it.
    private func interruptWhenReady(_ then: @escaping () -> Void) {
        let wait = max(0, RecordingConfig.stopGrace - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, let pid = self.process?.processIdentifier, self.process?.isRunning == true else { return }
            kill(pid, SIGINT)
            then()
        }
    }

    private func dismissRecordingUI() {
        timer?.invalidate(); timer = nil
        pill.close()
        border.close()
    }

    private func showReading(seconds: Double) {
        let mouse = NSEvent.mouseLocation
        let off = CGFloat(Motion.Behavior.cursorOffset)
        reading.show(kind: .reading, text: RecordingClock.reading(seconds)) { size in
            CGRect(x: mouse.x + off, y: mouse.y - off - size.height, width: size.width, height: size.height)
        }
    }

    // MARK: End of the child

    private func ended(status: Int32, stderr: String) {
        process = nil
        dismissRecordingUI()
        let file = tmp
        tmp = nil
        let size = (file.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] } as? Int) ?? 0
        if cancelling {
            if let file { try? FileManager.default.removeItem(at: file) }
            reading.close(); set(.idle); finished(.cancelled)
            return
        }
        guard let file, size > 0 else {
            if let file { try? FileManager.default.removeItem(at: file) }
            // The process ended and left no file (or an empty one): with no Screen Recording permission that is exactly what it does.
            NSLog("Bucket: recording ended without a file (status \(status), stderr \"\(stderr.trimmingCharacters(in: .whitespacesAndNewlines))\"): treating it as missing permission")
            reading.close(); set(.idle); finished(.permissionMissing)
            return
        }
        // Died on its own (nobody asked it to stop) but left a file: it is still a recording.
        if !stopping { elapsedAtStop = elapsed; showReading(seconds: elapsedAtStop) }
        set(.reading)
        let region = region, startedAt = startedAt, limit = limit, byLimit = stoppedByLimit
        let ocr = OCRSetting.enabled && !PasswordManagers.contains(frontBundleId)
        let library = library
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try RecordingProcessor.process(captured: file, region: region, startedAt: startedAt, ocr: ocr, library: library) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading.close()
                self.set(.idle)
                switch result {
                case .success(let shot): self.finished(.recorded(shot, stoppedAtLimit: byLimit ? limit : nil))
                case .failure(let error):
                    // The raw video is unredacted screen content: it does not stay behind in the temporary folder.
                    try? FileManager.default.removeItem(at: file)
                    NSLog("Bucket: could not process the recording: \(error.localizedDescription)")
                    self.finished(.failed(error.localizedDescription))
                }
            }
        }
    }
}
