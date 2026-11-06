import Foundation

/// Screen recording: everything that can be decided without a window or a video. The app drives `screencapture`;
/// this file holds the constants, the arithmetic and the shapes the checks pin.
public enum RecordingConfig {
    /// Sampling rate of the "where it changes" pass.
    public static let sampleFPS = 4.0
    /// Mean absolute difference (0...1) of two small gray thumbnails above which a sample counts as a new moment.
    /// Not measured against real screens yet: the spike's ffmpeg `scene 0.02` is a different metric.
    public static let changeThreshold = 0.01
    /// A recording never hands the agent more frames than this.
    public static let maxFrames = 12
    /// Width cap of the delivered frame; the original is kept at full size and is what OCR reads.
    public static let deliveredWidth = 640
    /// Side of the gray thumbnail used to compare two samples.
    public static let diffSide = 48
    /// A drag smaller than this (either side, points) is a click: it cancels, it never records the whole screen.
    public static let minRegionSide: CGFloat = 16
    /// SIGINT sent before screencapture has installed its handler would lose the file: a stop waits until the run is this old.
    public static let stopGrace: TimeInterval = 1.0
}

/// "Recording limit" setting: default 2 min, persisted like the other settings.
public enum RecordingLimit: Int, CaseIterable {
    case oneMinute = 60, twoMinutes = 120, fiveMinutes = 300, tenMinutes = 600, none = 0

    public static let key = "recordingLimitSeconds"
    public static let standard = RecordingLimit.twoMinutes

    public var title: String {
        switch self {
        case .oneMinute: return "1 min"
        case .twoMinutes: return "2 min"
        case .fiveMinutes: return "5 min"
        case .tenMinutes: return "10 min"
        case .none: return "No limit"
        }
    }

    /// nil = no limit.
    public var seconds: Int? { self == .none ? nil : rawValue }

    public static func current(in defaults: UserDefaults = .standard) -> RecordingLimit {
        guard let v = defaults.object(forKey: key) as? Int, let l = RecordingLimit(rawValue: v) else { return standard }
        return l
    }

    public static func set(_ l: RecordingLimit, in defaults: UserDefaults = .standard) { defaults.set(l.rawValue, forKey: key) }

    public static let helpLine = "Longer recordings take more space"
}

/// What the pill's clock says.
public enum RecordingClock {
    /// The last seconds count down.
    public static let countdownWindow = 10.0

    /// `m:ss`, whole seconds, never negative.
    public static func format(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// Elapsed time, or `-m:ss` once the limit is within the countdown window. No limit: always elapsed.
    public static func display(elapsed: Double, limit: Int?) -> (text: String, countdown: Bool) {
        guard let limit else { return (format(elapsed), false) }
        let remaining = Double(limit) - elapsed
        if remaining <= countdownWindow { return ("-" + format(max(0, remaining).rounded(.up)), true) }
        return (format(elapsed), false)
    }

    public static func reachedLimit(elapsed: Double, limit: Int?) -> Bool {
        guard let limit else { return false }
        return elapsed >= Double(limit)
    }

    /// "Reading 0:14…" while the frames and the text are being read.
    public static func reading(_ seconds: Double) -> String { "Reading \(format(seconds))…" }
    /// The companion says it before "1 in bucket" when the limit cut the recording.
    public static func stoppedAt(_ limit: Int) -> String { "Stopped at \(format(Double(limit)))" }
}

/// The region the user drags, and how screencapture wants it.
public enum RecordingRegion {
    /// Normalized rect between two corners (any drag direction).
    public static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    public static func isClick(_ r: CGRect) -> Bool { r.width < RecordingConfig.minRegionSide || r.height < RecordingConfig.minRegionSide }

    /// Whole points, origin top-left of the MAIN screen, the box that contains the selection. `region` is in AppKit global
    /// coordinates (y up, main screen origin at 0,0); `mainHeight` is the main screen's height.
    public static func screencaptureRect(_ region: CGRect, mainHeight: CGFloat) -> RecordingSidecar.Region {
        let x = Int(region.minX.rounded(.down)), top = Int((mainHeight - region.maxY).rounded(.down))
        let right = Int(region.maxX.rounded(.up)), bottom = Int((mainHeight - region.minY).rounded(.up))
        return .init(x: x, y: top, w: max(1, right - x), h: max(1, bottom - top))
    }

    public static func argument(_ r: RecordingSidecar.Region) -> String { "\(r.x),\(r.y),\(r.w),\(r.h)" }
}

/// Where the recording pill sits. AppKit coordinates (y up), all rects on the region's screen.
public enum RecPillPlacement {
    public enum Place: Equatable { case below, above, inside }
    public static let gap: CGFloat = 8
    /// Region ≈ the whole screen: the pill sits on the content, this far above the bottom of the visible frame.
    public static let insideMargin: CGFloat = 24

    /// Below the region, right edges aligned, `gap` of air. If that does not fit in `visible`, above. If neither, bottom center
    /// of the screen, on top of the content (it is then inside the recorded rect: the window is excluded from capture).
    public static func place(region: CGRect, pill: CGSize, visible: CGRect) -> (frame: CGRect, place: Place) {
        func x() -> CGFloat { min(max(region.maxX - pill.width, visible.minX), max(visible.minX, visible.maxX - pill.width)) }
        let below = region.minY - gap - pill.height
        if below >= visible.minY { return (CGRect(x: x(), y: below, width: pill.width, height: pill.height), .below) }
        let above = region.maxY + gap
        if above + pill.height <= visible.maxY { return (CGRect(x: x(), y: above, width: pill.width, height: pill.height), .above) }
        return (CGRect(x: visible.midX - pill.width / 2, y: visible.minY + insideMargin, width: pill.width, height: pill.height), .inside)
    }
}

/// File names of a recording, same convention as the photos: `<id>.mov`, `<id>.json`, a sibling folder `<id>/` of frames.
public enum RecordingNames {
    /// `…_xxxx_t003.2s`: the time in the name, zero-padded so a listing sorts in order.
    public static func frameStem(id: String, t: Double) -> String { "\(id)_t" + String(format: "%05.1f", max(0, t)) + "s" }
    public static func frameFile(id: String, t: Double) -> String { frameStem(id: id, t: t) + ".png" }

    public static func video(day: URL, id: String) -> URL { day.appendingPathComponent("\(id).mov") }
    public static func sidecar(day: URL, id: String) -> URL { day.appendingPathComponent("\(id).json") }
    public static func framesDir(day: URL, id: String) -> URL { day.appendingPathComponent(id, isDirectory: true) }
}

/// The text of a frame as lines, and what is new against the frame before.
public enum RecordingText {
    public static func lines(_ s: String) -> [String] {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    /// Lines of `current` that were not on screen in `previous`, in reading order.
    public static func appeared(previous: [String], current: [String]) -> [String] {
        let before = Set(previous)
        var seen = Set<String>()
        return current.filter { !before.contains($0) && seen.insert($0).inserted }
    }
}

/// "Where it changes": picks frames out of an ordered list of samples.
public enum FramePicker {
    /// - Parameters:
    ///   - count: samples, in time order.
    ///   - distance: how different sample `j` is from sample `i` (0...1).
    /// Walks forward comparing each sample with the last one chosen; a sample at or above `threshold` is chosen. The first and
    /// the last sample are always in. Past `cap`, the first and the last stay and the rest are the ones that changed the most.
    /// Returns sample indices in time order.
    public static func pick(count: Int, distance: (Int, Int) -> Double, threshold: Double, cap: Int) -> [Int] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [0] }
        var chosen = [0], scores = [Double.infinity]
        var last = 0
        for i in 1 ..< count - 1 {
            let d = distance(last, i)
            if d >= threshold { chosen.append(i); scores.append(d); last = i }
        }
        chosen.append(count - 1); scores.append(distance(last, count - 1))
        let cap = max(2, cap)
        guard chosen.count > cap else { return chosen }
        let middle = (1 ..< chosen.count - 1).sorted { (scores[$0], -$0) > (scores[$1], -$1) }.prefix(cap - 2)
        return ([0] + middle.sorted() + [chosen.count - 1]).map { chosen[$0] }
    }
}

/// The recording's sidecar JSON: what the agent reads after the frames.
public struct RecordingSidecar: Codable, Equatable {
    public struct Region: Codable, Equatable {
        public var x: Int, y: Int, w: Int, h: Int
        public init(x: Int, y: Int, w: Int, h: Int) { self.x = x; self.y = y; self.w = w; self.h = h }
    }
    public struct Frame: Codable, Equatable {
        public var t: Double
        public var path: String
        public var text: [String]
        public var appeared: [String]
        public init(t: Double, path: String, text: [String], appeared: [String]) { self.t = t; self.path = path; self.text = text; self.appeared = appeared }
    }

    public static let kind = "bucket.recording"
    /// Sent to the agent as the first field of the JSON. English, fixed.
    public static let note = "Screen recording captured with Bucket. Frames are the moments where the screen changed, in order; 'text' is on-screen text read locally (OCR). No audio. The user's message says what to do with it."
    public static let noteOCROff = note + " Text reading was off for this recording, so 'text' is empty."

    public var kind: String
    public var note: String
    public var video: String
    public var durationS: Double
    public var region: Region
    public var frames: [Frame]

    enum CodingKeys: String, CodingKey { case kind, note, video, durationS = "duration_s", region, frames }

    public init(video: String, durationS: Double, region: Region, frames: [Frame], ocr: Bool) {
        self.kind = RecordingSidecar.kind
        self.note = ocr ? RecordingSidecar.note : RecordingSidecar.noteOCROff
        self.video = video
        self.durationS = (durationS * 10).rounded() / 10
        self.region = region
        self.frames = frames.map { var f = $0; f.t = (f.t * 10).rounded() / 10; return f }
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }
}

/// What a bucket item that is a recording knows. Everything is derived from where the sidecar sits, never from its JSON.
public struct RecordingRef: Codable, Equatable {
    public var sidecar: String
    public var video: String
    public var duration: Double
    /// Delivered (640 px) frames, in order.
    public var frames: [String]
    public init(sidecar: String, video: String, duration: Double, frames: [String]) {
        self.sidecar = sidecar; self.video = video; self.duration = duration; self.frames = frames
    }
    /// "0:14" for the panel thumbnail.
    public var durationLabel: String { RecordingClock.format(duration) }
}

extension Library {
    /// A bucket item: a photo's sidecar (`load`) or a recording's. A recording comes back as a `Shot` whose `path` is its first
    /// frame (so thumbnails and the menu work unchanged), whose `originalPath` is the .mov (Send to Desktop hands that over)
    /// and whose `recording` holds what the paste expands. Nil if the sidecar is not at its place, is not a recording, or its
    /// frames are not where the id says they are.
    public func loadItem(sidecar path: String) -> Shot? {
        load(sidecar: path) ?? loadRecording(sidecar: path)
    }

    func loadRecording(sidecar path: String) -> Shot? {
        guard let loc = sidecarLocation(path), Library.isID(loc.id),
              let data = FileManager.default.contents(atPath: path),
              let rec = try? JSONDecoder().decode(RecordingSidecar.self, from: data),
              rec.kind == RecordingSidecar.kind, !rec.frames.isEmpty else { return nil }
        let dir = RecordingNames.framesDir(day: loc.dir, id: loc.id)
        let video = RecordingNames.video(day: loc.dir, id: loc.id)
        var frames: [String] = []
        for f in rec.frames {
            let name = (f.path as NSString).lastPathComponent
            guard name.hasPrefix("\(loc.id)_t"), name.hasSuffix(".png") else { return nil } // a hand-edited path cannot point elsewhere
            frames.append(dir.appendingPathComponent(name).path)
        }
        for p in frames + [video.path, dir.path, path] where Library.isSymlink(p) {
            NSLog("Bucket: ignoring \(loc.id): \((p as NSString).lastPathComponent) is a symlink")
            return nil
        }
        let ref = RecordingRef(sidecar: loc.dir.appendingPathComponent("\(loc.id).json").path, video: video.path, duration: rec.durationS, frames: frames)
        let f = ISO8601DateFormatter()
        let created = DateFormatter(); created.locale = Locale(identifier: "en_US_POSIX"); created.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return Shot(id: loc.id, createdAt: created.date(from: String(loc.id.prefix(19))).map(f.string(from:)) ?? "",
                    path: frames[0], originalPath: video.path, width: rec.region.w, height: rec.region.h, bytes: 0, originalBytes: 0,
                    frontApp: nil, resizeMs: 0, ocr: .init(status: "skipped", text: nil), batches: [], recording: ref)
    }
}
