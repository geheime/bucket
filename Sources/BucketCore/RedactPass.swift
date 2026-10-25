import Foundation

/// One-time pass: Redact only ran on new OCR, so sidecars written before 0.4 may still hold secrets in the clear.
/// Runs once per archive (marker `.state/redact-v1`, written only if every sidecar was handled, so a failure retries next launch).
public enum RedactPass {
    public static let markerName = "redact-v1"

    public static func markerURL(_ library: Library) -> URL { library.stateDir.appendingPathComponent(markerName) }

    /// nil = already done (marker present), nothing touched. Otherwise how many sidecars changed and how many lost their text.
    /// Each file goes through `Library.load`'s validation and `Library.update` (merge-safe); a symlinked sidecar is never followed.
    /// Fail closed: if the redactor cannot run, the text is dropped (status `failed`), never kept.
    @discardableResult
    public static func run(library: Library) -> (redacted: Int, dropped: Int)? {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: markerURL(library).path) else { return nil }
        var redacted = 0, dropped = 0, clean = true
        for path in library.allSidecars() {
            guard !Library.isSymlink(path), let shot = library.load(sidecar: path), let text = shot.ocr.text else { continue }
            if let r = Redact.redact(text), r.text == text { continue } // nothing to mask: the file is not rewritten
            do {
                try library.update(sidecar: path) { s in // re-reads from disk: judged on the text that is there now
                    guard let t = s.ocr.text else { return }
                    if let r = Redact.redact(t) {
                        guard r.text != t else { return }
                        s.ocr.text = r.text; redacted += 1
                    } else {
                        s.ocr = .init(status: "failed", text: nil, ms: s.ocr.ms); dropped += 1
                    }
                }
            } catch {
                clean = false
                NSLog("Bucket: redact pass could not update \((path as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }
        if clean {
            try? fm.createDirectory(at: library.stateDir, withIntermediateDirectories: true)
            try? Data(ISO8601DateFormatter().string(from: Date()).utf8).write(to: markerURL(library), options: .atomic)
        }
        if redacted + dropped > 0 { NSLog("Bucket: redact pass: \(redacted) redacted, \(dropped) dropped") }
        return (redacted, dropped)
    }
}
