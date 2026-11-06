import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Background circuit of a recording: the .mov goes into the archive, the frames "where the screen changed" are picked with
/// AVFoundation, each one is saved (original at full size under `originals/`, deliverable at 640 px), read with Vision on
/// the FULL-size frame and redacted like a photo, and the sidecar JSON is written last (it is what makes the item exist).
/// Never call it on the main thread.
public enum RecordingProcessor {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// One sample of the first pass: a small gray picture and the time AVFoundation really gave us.
    struct Sample { let t: Double; let gray: [UInt8] }

    /// - Parameters:
    ///   - tmp: the finished .mov. It is moved into the archive only once everything else worked.
    ///   - ocr: read text (the "Read text in screenshots" switch AND no password manager in front).
    /// - Returns: the item as the bucket will hold it.
    public static func process(captured tmp: URL, region: RecordingSidecar.Region, startedAt: Date, ocr: Bool,
                               library: Library) throws -> Shot {
        let id = Library.makeID(startedAt)
        let day = Library.dayPath(startedAt)
        let fm = FileManager.default
        let dayDir = library.root.appendingPathComponent(day)
        let framesDir = RecordingNames.framesDir(day: dayDir, id: id)
        let originalsDir = library.root.appendingPathComponent("originals").appendingPathComponent(day)
            .appendingPathComponent(id, isDirectory: true)
        let video = RecordingNames.video(day: dayDir, id: id)
        let sidecar = RecordingNames.sidecar(day: dayDir, id: id)
        for u in [library.root.appendingPathComponent("originals"), originalsDir.deletingLastPathComponent(), originalsDir, dayDir, framesDir, video, sidecar] {
            try Library.rejectSymlink(u)
        }
        try fm.createDirectory(at: framesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: originalsDir, withIntermediateDirectories: true)
        func cleanup() { try? fm.removeItem(at: framesDir); try? fm.removeItem(at: originalsDir) }

        do {
            let asset = AVURLAsset(url: tmp)
            let duration = try blocking { try await asset.load(.duration).seconds }
            guard duration.isFinite, duration > 0 else { throw Failure(message: "The recording has no duration") }

            // Pass 1: small gray samples, to decide WHERE it changes.
            let samples = try sample(asset, duration: duration)
            guard !samples.isEmpty else { throw Failure(message: "No frame could be read from the recording") }
            let picked = FramePicker.pick(count: samples.count,
                                          distance: { meanDifference(samples[$0].gray, samples[$1].gray) },
                                          threshold: RecordingConfig.changeThreshold, cap: RecordingConfig.maxFrames)

            // Pass 2: only the chosen ones, at full size.
            let generator = makeGenerator(asset, maxSize: .zero)
            var frames: [RecordingSidecar.Frame] = []
            var previousText: [String] = []
            for index in picked {
                let s = samples[index]
                let (cg, actual) = try blocking { try await generator.image(at: CMTime(seconds: s.t, preferredTimescale: 600)) }
                let t = actual.seconds.isFinite ? actual.seconds : s.t
                let name = RecordingNames.frameFile(id: id, t: t)
                let original = originalsDir.appendingPathComponent(name), delivered = framesDir.appendingPathComponent(name)
                try writePNG(cg, to: original)
                try shrink(original, to: delivered, width: cg.width, maxWidth: RecordingConfig.deliveredWidth)
                chmod(original.path, 0o600); chmod(delivered.path, 0o600)
                // The text comes from the full-size frame. Fail closed: if the redactor cannot run, no text is kept.
                var text: [String] = []
                if ocr, let raw = OCRQueue.recognize(original), let safe = Redact.redact(raw)?.text { text = RecordingText.lines(safe) }
                frames.append(.init(t: t, path: delivered.path, text: text, appeared: RecordingText.appeared(previous: previousText, current: text)))
                previousText = text
            }

            // The video goes in, then the json: the json is the commit.
            try fm.moveItem(at: tmp, to: video)
            chmod(video.path, 0o600)
            let json = RecordingSidecar(video: video.path, durationS: duration, region: region, frames: frames, ocr: ocr)
            try json.encoded().write(to: sidecar, options: .atomic)
            chmod(sidecar.path, 0o600)
        } catch {
            cleanup()
            throw error
        }
        guard let shot = library.loadRecording(sidecar: sidecar.path) else { throw Failure(message: "The recording was written but does not load") }
        return shot
    }

    // MARK: Sampling

    static func makeGenerator(_ asset: AVAsset, maxSize: CGSize) -> AVAssetImageGenerator {
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        g.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        g.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        g.maximumSize = maxSize
        return g
    }

    /// Times to look at: every 1/fps, and the very end.
    static func sampleTimes(duration: Double, fps: Double = RecordingConfig.sampleFPS) -> [Double] {
        var times = Array(stride(from: 0, to: duration, by: 1 / fps))
        let end = max(0, duration - 0.05)
        if times.last.map({ end - $0 > 0.02 }) ?? true { times.append(end) }
        return times
    }

    static func sample(_ asset: AVAsset, duration: Double) throws -> [Sample] {
        let side = CGFloat(RecordingConfig.diffSide)
        let generator = makeGenerator(asset, maxSize: CGSize(width: side * 2, height: side * 2))
        var out: [Sample] = []
        for t in sampleTimes(duration: duration) {
            // A sample that cannot be decoded is skipped; the rest still tell where it changed.
            guard let (cg, actual) = try? blocking({ try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) }) else { continue }
            out.append(Sample(t: actual.seconds.isFinite ? actual.seconds : t, gray: grayThumbnail(cg)))
        }
        return out
    }

    static func grayThumbnail(_ image: CGImage) -> [UInt8] {
        let n = RecordingConfig.diffSide
        var bytes = [UInt8](repeating: 0, count: n * n)
        bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        }
        return bytes
    }

    /// Mean absolute difference of two gray thumbnails, 0 (equal) ... 1.
    public static func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var sum = 0
        for i in 0 ..< a.count { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count * 255)
    }

    // MARK: Images

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(message: "Could not create \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure(message: "Could not write \(url.lastPathComponent)") }
    }

    /// The deliverable: at most `maxWidth` wide (never enlarged), same aspect.
    static func shrink(_ src: URL, to dst: URL, width: Int, maxWidth: Int) throws {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else {
            throw Failure(message: "Unreadable frame")
        }
        let scale = min(1, Double(maxWidth) / Double(max(w, 1)))
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: max(1, Int((Double(max(w, h)) * scale).rounded()))]
        guard let small = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { throw Failure(message: "Resize failed") }
        try writePNG(small, to: dst)
    }

    // MARK: Async bridge

    private final class Box<T> { var result: Result<T, Error>? }

    /// AVFoundation's loaders are async-only now; this circuit already runs off the main thread, so it waits here.
    static func blocking<T>(_ op: @escaping () async throws -> T) throws -> T {
        let box = Box<T>(), done = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await op()) } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }
}
