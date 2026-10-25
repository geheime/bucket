import Foundation
import ImageIO
import Vision

/// Background circuit: reads the text of each shot with Vision, one shot at a time, off the capture path.
/// Results go through `Library.update`, so they merge with whatever else touched the sidecar meanwhile.
public final class OCRQueue {
    public static let shared = OCRQueue()
    /// Posted on the main queue whenever `pendingCount` changes (for the panel footer).
    public static let didChange = Notification.Name("studio.bast.bucket.ocrDidChange")

    /// Same as the notification, for a direct subscriber. Called on the main queue with the new pending count.
    public var onChange: ((Int) -> Void)?

    private let work = DispatchQueue(label: "studio.bast.bucket.ocr", qos: .utility)
    private let idle = DispatchGroup()
    private let lock = NSLock()
    private var queued = Set<String>() // sidecar paths waiting or running: backfill never double-enqueues
    private var doneCount = 0
    private var failedCount = 0

    public var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return queued.count }
    /// Finished since the last `resetCounts()` (the CLI prints these).
    public var counts: (done: Int, failed: Int) { lock.lock(); defer { lock.unlock() }; return (doneCount, failedCount) }
    public func resetCounts() { lock.lock(); doneCount = 0; failedCount = 0; lock.unlock() }

    /// Spanish + English, filtered by what this macOS actually accepts (codes differ between releases).
    static func languages() -> [String] {
        let probe = VNRecognizeTextRequest()
        probe.recognitionLevel = .accurate
        let supported = (try? probe.supportedRecognitionLanguages()) ?? []
        let wanted = ["es-ES", "en-US"].filter(supported.contains)
        return wanted.isEmpty ? ["en-US"] : wanted
    }

    /// Returns immediately: the immediate circuit never waits for this.
    public func enqueue(sidecar path: String, library: Library) {
        lock.lock()
        let isNew = queued.insert(path).inserted
        lock.unlock()
        guard isNew else { return }
        idle.enter()
        notify()
        work.async { [self] in
            autoreleasepool { process(path, library: library) }
            lock.lock(); queued.remove(path); lock.unlock()
            notify()
            idle.leave()
        }
    }

    /// Every sidecar that is still `pending`, or has no text (failed earlier). `skipped` is terminal and never queued. Returns how many were queued.
    @discardableResult
    public func backfill(library: Library) -> Int {
        var n = 0
        for path in library.allSidecars() {
            guard let shot = library.load(sidecar: path), shot.ocr.status != "skipped", shot.ocr.status == "pending" || shot.ocr.text == nil else { continue }
            enqueue(sidecar: path, library: library)
            n += 1
        }
        return n
    }

    /// Blocks until everything queued so far has finished. For the CLI and the checks, never for the app.
    public func waitUntilIdle() { idle.wait() }

    private func notify() {
        let n = pendingCount
        DispatchQueue.main.async {
            self.onChange?(n)
            NotificationCenter.default.post(name: OCRQueue.didChange, object: self, userInfo: ["pending": n])
        }
    }

    private func process(_ path: String, library: Library) {
        guard let shot = library.load(sidecar: path) else { return } // gone (moved or deleted by hand)
        // Terminal: a password manager was in front (or a racing run already decided). Also closes shots captured
        // while OCR was off: pending, but from a manager.
        if shot.ocr.status == "skipped" { return }
        if PasswordManagers.contains(shot.frontBundleId) {
            try? library.update(sidecar: path) { $0.ocr = .init(status: "skipped", text: nil) }
            return
        }
        // Already read by a racing run: leave it alone.
        if shot.ocr.status == "done", shot.ocr.text != nil { return }
        let start = DispatchTime.now()
        // Fail closed: the raw text only ever lives in this scope. No redactor result → no text stored.
        let text = OCRQueue.recognize(URL(fileURLWithPath: shot.path)).flatMap { Redact.redact($0)?.text }
        let ms = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        let ok = text != nil
        do {
            try library.update(sidecar: path) {
                if $0.ocr.status == "skipped" { return } // never overwrite a terminal state
                $0.ocr = .init(status: ok ? "done" : "failed", text: text, ms: ms)
            }
        } catch {
            NSLog("Bucket: could not save OCR for \(path): \(error.localizedDescription)")
        }
        lock.lock(); if ok { doneCount += 1 } else { failedCount += 1 }; lock.unlock()
    }

    /// nil = could not read the image or Vision failed; "" = readable image with no text.
    static func recognize(_ image: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(image as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages()
        do { try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request]) } catch { return nil }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
