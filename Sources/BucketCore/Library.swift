import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One screenshot in the archive. The sidecar JSON next to the PNG is the source of truth.
public struct Shot: Codable, Equatable {
    public struct OCR: Codable, Equatable {
        public var status: String // pending | done | failed
        public var text: String?
        public var ms: Int? // optional so sidecars written before OCR still decode
        public init(status: String, text: String?, ms: Int? = nil) { self.status = status; self.text = text; self.ms = ms }
    }

    public var id: String               // var only so the migration can rewrite it
    public let createdAt: String
    public var path: String             // optimized PNG — the only path ever delivered
    public var originalPath: String     // untouched capture, backup only
    public let width: Int
    public let height: Int
    public let bytes: Int
    public let originalBytes: Int
    public let frontApp: String?
    public let resizeMs: Int
    public var ocr: OCR
    public var batches: [String]

    public init(id: String, createdAt: String, path: String, originalPath: String, width: Int, height: Int,
                bytes: Int, originalBytes: Int, frontApp: String?, resizeMs: Int, ocr: OCR, batches: [String]) {
        self.id = id; self.createdAt = createdAt; self.path = path; self.originalPath = originalPath
        self.width = width; self.height = height; self.bytes = bytes; self.originalBytes = originalBytes
        self.frontApp = frontApp; self.resizeMs = resizeMs; self.ocr = ocr; self.batches = batches
    }

    public var sidecarPath: String { (path as NSString).deletingPathExtension + ".json" }
}

/// Library: owns the archive on disk. Decides nothing about what gets delivered.
/// It is the ONLY writer of sidecars: creation goes through `ingest`, every later change through `update`.
public final class Library {
    public let root: URL
    /// One queue for the whole process (not per instance), so two Library values on the same root still serialize.
    private static let sidecarQueue = DispatchQueue(label: "studio.bast.bucket.sidecars")
    /// Upper bound for the long edge, applied after scaling Retina down to 1x points.
    /// Placeholder until the legibility test in phase 1 picks a profile.
    public var maxLongEdge: Int {
        let v = UserDefaults.standard.integer(forKey: "maxLongEdge")
        return v > 0 ? v : 1568
    }

    /// `create: false` is for read-only callers (search): the archive is never created, and if it is missing the
    /// library is simply empty.
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Bucket"), create: Bool = true) {
        self.root = root
        guard create else { return }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let existed = fm.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
        let hadState = fm.fileExists(atPath: root.appendingPathComponent(".state").path)
        try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        // The archive holds OCR text in the clear: the root is 0700 even when it already existed with 0755 (0.2 users).
        // Closing the root is enough to block traversal, whatever the children's modes are.
        // Only a folder Bucket made, or one that already holds `.state`, is tightened: `--root ~/Documents` must not
        // change the permissions of a folder that is not ours.
        if !existed || hadState { chmod(root.path, 0o700) }
    }

    /// When on, `ingest` queues the shot for OCR (background, returns at once). The app and the CLI turn it on; checks opt in.
    public var ocrOnIngest = false

    public var stateDir: URL { root.appendingPathComponent(".state") }

    // MARK: Ingest (immediate circuit)

    public func ingest(captured tmp: URL, frontApp: String?) throws -> Shot {
        let now = Date()
        let id = Library.makeID(now)
        let day = Library.dayPath(now)
        let fm = FileManager.default

        let dir = root.appendingPathComponent(day)
        let originalsDir = root.appendingPathComponent("originals").appendingPathComponent(day)
        let original = originalsDir.appendingPathComponent("\(id).png")
        let optimized = dir.appendingPathComponent("\(id).png")
        // Nothing below the root may be a symlink (a planted ~/Bucket/<day> would send the capture elsewhere).
        for u in [root.appendingPathComponent("originals"), originalsDir, dir, original, optimized] { try Library.rejectSymlink(u) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: originalsDir, withIntermediateDirectories: true)
        try fm.moveItem(at: tmp, to: original)
        chmod(original.path, 0o600) // a moved file keeps the mode it had (the capture's, or a copy's): never wider than the owner

        let start = DispatchTime.now()
        let (w, h) = try Library.optimize(from: original, to: optimized, maxLongEdge: maxLongEdge)
        let ms = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)

        let shot = Shot(
            id: id,
            createdAt: ISO8601DateFormatter().string(from: now),
            path: optimized.path,
            originalPath: original.path,
            width: w, height: h,
            bytes: Library.fileSize(optimized),
            originalBytes: Library.fileSize(original),
            frontApp: frontApp,
            resizeMs: ms,
            ocr: .init(status: "pending", text: nil),
            batches: []
        )
        try Library.sidecarQueue.sync { try Library.write(shot, to: shot.sidecarPath) }
        if ocrOnIngest { OCRQueue.shared.enqueue(sidecar: shot.sidecarPath, library: self) }
        return shot
    }

    /// Read-modify-write of one sidecar, serialized: re-reads the file from disk, applies `change`, saves atomically.
    /// Nobody writes a `Shot` they hold in memory over a newer one. Do not call `update` from inside `change` (deadlock).
    @discardableResult
    public func update(sidecar path: String, _ change: (inout Shot) -> Void) throws -> Shot {
        guard sidecarLocation(path) != nil else {
            throw NSError(domain: "Bucket", code: 7, userInfo: [NSLocalizedDescriptionKey: "Not a sidecar of this archive: \(path)"])
        }
        return try Library.sidecarQueue.sync {
            var shot = try JSONDecoder().decode(Shot.self, from: try Data(contentsOf: URL(fileURLWithPath: path)))
            change(&shot)
            try Library.write(shot, to: path) // back to the file we read, even if `change` rewrote shot.path
            return shot
        }
    }

    @discardableResult
    public func update(id: String, _ change: (inout Shot) -> Void) throws -> Shot {
        guard let day = Library.day(of: id) else {
            throw NSError(domain: "Bucket", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unknown id format: \(id)"])
        }
        return try update(sidecar: root.appendingPathComponent(day).appendingPathComponent("\(id).json").path, change)
    }

    private static func write(_ shot: Shot, to path: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(shot).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// The one door every reader goes through. A sidecar is data, not a promise: it is accepted only if it really sits at
    /// `<root>/<yyyy-MM-dd>/<id>.json` (resolved, symlinks followed, still under the root), and then `id`, `path` and
    /// `originalPath` are overwritten with what that location says, whatever the JSON claimed. A file copied from another
    /// machine therefore works, and a hand-edited one cannot point the app at /etc/passwd.
    public func load(sidecar path: String) -> Shot? {
        guard let loc = sidecarLocation(path), var shot = loadRaw(sidecar: path) else { return nil }
        shot.id = loc.id
        shot.path = loc.dir.appendingPathComponent("\(loc.id).png").path
        shot.originalPath = root.appendingPathComponent("originals").appendingPathComponent(loc.rel)
            .appendingPathComponent("\(loc.id).png").path
        // A symlink planted where the png or the original should be would make us read or deliver some other file.
        for file in [shot.path, shot.originalPath] where Library.isSymlink(file) {
            NSLog("Bucket: ignoring \(loc.id): \((file as NSString).lastPathComponent) is a symlink")
            return nil
        }
        return shot
    }

    /// True if `path` itself is a symlink (lstat: the link, not its target). A missing path is not one.
    static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// The JSON exactly as written, location unchecked. Only the migration uses it: it exists to find and repair
    /// sidecars whose id/path are stale, which `load` would silently hide.
    func loadRaw(sidecar path: String) -> Shot? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Shot.self, from: data)
    }

    /// Throws if `url` exists and is a symlink (lstat: the link itself, not its target).
    static func rejectSymlink(_ url: URL) throws {
        var st = stat()
        if lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
            throw NSError(domain: "Bucket", code: 6, userInfo: [NSLocalizedDescriptionKey: "Refusing to write through a symlink: \(url.lastPathComponent)"])
        }
    }

    /// The png a sidecar belongs to, derived from the sidecar's own location: `<root>/<day>/<id>.png`.
    /// nil unless the sidecar sits where `sidecarLocation` accepts it, the png exists, and it resolves (symlinks followed) under the root.
    public func derivedPNG(ofSidecar sidecar: String) -> String? {
        guard let loc = sidecarLocation(sidecar) else { return nil }
        let png = loc.dir.appendingPathComponent("\(loc.id).png")
        let expected = root.resolvingSymlinksInPath().appendingPathComponent(loc.rel).appendingPathComponent("\(loc.id).png")
        guard png.resolvingSymlinksInPath().path == expected.path, FileManager.default.fileExists(atPath: expected.path) else { return nil }
        return png.path
    }

    /// Where a sidecar really is. Valid only for `<root>/yyyy-MM-dd/<id>.json` (or, for a v0.1 archive not migrated yet,
    /// `<root>/yyyy/MM/dd/<legacy id>.json`) with real (non-symlink) folders and file, a well-formed id, and the id's own day.
    /// `dir` and `rel` are built from `root` as given, never from the sidecar path the caller passed.
    func sidecarLocation(_ sidecar: String) -> (id: String, rel: String, dir: URL)? {
        let url = URL(fileURLWithPath: sidecar)
        let id = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension == "json" else { return nil }
        let rel: String
        if Library.isID(id), let day = Library.day(of: id) { rel = day }
        else if Library.isLegacyID(id), let day = Library.day(of: id) { rel = day.replacingOccurrences(of: "-", with: "/") }
        else { return nil }
        let expected = root.resolvingSymlinksInPath().appendingPathComponent(rel).appendingPathComponent("\(id).json")
        guard url.resolvingSymlinksInPath().path == expected.path else { return nil }
        return (id, rel, root.appendingPathComponent(rel))
    }

    // MARK: Helpers

    private static let idLock = NSLock()
    private static var idSecond = ""
    private static var idsIssued = Set<String>()

    /// yyyy-MM-dd_HH-mm-ss_xxxx — the random suffix keeps two captures in the same second apart.
    /// 16 bits alone collide by birthday odds (~7 in 1000 draws), so ids already issued this second are redrawn.
    public static func makeID(_ date: Date) -> String {
        let stamp = formatted(date, "yyyy-MM-dd_HH-mm-ss")
        idLock.lock(); defer { idLock.unlock() }
        if stamp != idSecond { idSecond = stamp; idsIssued.removeAll() }
        // 65536 suffixes per second; past that, a unique id is impossible, so fail loudly instead of looping.
        precondition(idsIssued.count < 65536, "makeID: suffix space exhausted for \(stamp)")
        var suffix: String
        repeat { suffix = String(format: "%04x", UInt16.random(in: .min ... .max)) } while idsIssued.contains(suffix)
        idsIssued.insert(suffix)
        return "\(stamp)_\(suffix)"
    }

    /// Day folder of a capture: yyyy-MM-dd.
    public static func dayPath(_ date: Date) -> String { formatted(date, "yyyy-MM-dd") }

    static let idPattern = #"\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_[0-9a-f]{4}"#
    /// Pre-v0.2 ids (yyyyMMdd-HHmmss-xxxx), only recognized so the migration and the menu can read old archives.
    static let legacyIDPattern = #"\d{8}-\d{6}-[0-9a-f]{4}"#

    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) == s.startIndex ..< s.endIndex
    }

    public static func isID(_ s: String) -> Bool { matches(s, idPattern) }
    public static func isLegacyID(_ s: String) -> Bool { matches(s, legacyIDPattern) }

    /// 20261024-174619-a3f2 → 2026-10-24_17-46-19_a3f2 (same instant, same suffix).
    public static func newID(fromLegacy old: String) -> String? {
        guard isLegacyID(old) else { return nil }
        let c = Array(old)
        func s(_ r: ClosedRange<Int>) -> String { String(c[r]) }
        return "\(s(0 ... 3))-\(s(4 ... 5))-\(s(6 ... 7))_\(s(9 ... 10))-\(s(11 ... 12))-\(s(13 ... 14))_\(s(16 ... 19))"
    }

    /// Day folder an id lives in (`2026-10-24`); also accepts legacy ids.
    public static func day(of id: String) -> String? {
        guard let new = isID(id) ? id : newID(fromLegacy: id) else { return nil }
        return String(new.prefix(10))
    }

    /// "17:46:19" for either id format; nil if it is neither.
    public static func timeLabel(of id: String) -> String? {
        guard let new = isID(id) ? id : newID(fromLegacy: id) else { return nil }
        return new.split(separator: "_")[1].replacingOccurrences(of: "-", with: ":")
    }

    private static func formatted(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: date)
    }

    static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    }

    /// Scales a Retina capture down to 1x points (using its DPI metadata), capped at maxLongEdge.
    static func optimize(from src: URL, to dst: URL, maxLongEdge: Int) throws -> (Int, Int) {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int,
              let ph = props[kCGImagePropertyPixelHeight] as? Int
        else { throw NSError(domain: "Bucket", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unreadable image"]) }

        let dpi = (props[kCGImagePropertyDPIWidth] as? Double) ?? 72
        let scale = max(1, dpi / 72)
        let target = min(Int(Double(max(pw, ph)) / scale), maxLongEdge)

        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target, 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary),
              let dest = CGImageDestinationCreateWithURL(dst as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw NSError(domain: "Bucket", code: 2, userInfo: [NSLocalizedDescriptionKey: "Resize failed"]) }

        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: 72] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Bucket", code: 3, userInfo: [NSLocalizedDescriptionKey: "Write failed"])
        }
        return (image.width, image.height)
    }
}
