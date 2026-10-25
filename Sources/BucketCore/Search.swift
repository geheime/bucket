import Foundation

extension Library {
    /// Every sidecar of the archive: `yyyy-MM-dd/*.json` only. `originals/` and `.state/` are not day folders.
    public func allSidecars() -> [String] {
        let fm = FileManager.default
        let days = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { Library.matches($0, #"\d{4}-\d{2}-\d{2}"#) }
        var out: [String] = []
        for day in days.sorted() {
            let dir = root.appendingPathComponent(day)
            for name in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() where name.hasSuffix(".json") {
                out.append(dir.appendingPathComponent(name).path)
            }
        }
        return out
    }
}

/// Search over the sidecars themselves: they ARE the index, there is no database to keep in sync.
public enum Search {
    public struct Result: Equatable {
        public let path: String
        public let id: String
        public let createdAt: String
        public let frontApp: String?
        public let snippet: String
        public let ocrStatus: String
    }

    static let fold: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// All words must appear (AND) in `ocr.text` + `frontApp`, ignoring case and accents. Newest first.
    /// `unread` counts shots whose OCR has not finished, so the caller can say the answer may be incomplete.
    public static func run(library: Library, query: String, limit: Int = 10) -> (results: [Result], unread: Int) {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var shots: [Shot] = []
        var unread = 0
        for path in library.allSidecars() {
            guard var shot = library.load(sidecar: path) else { continue }
            // The sidecar is data anyone could have written: the path we hand to an agent is derived from where the
            // sidecar sits (root/<day>/<id>.png), never read from its JSON. No such png under the root -> not a result.
            guard let png = library.derivedPNG(ofSidecar: path), let loc = library.sidecarLocation(path) else { continue }
            shot.id = loc.id
            shot.path = png
            if shot.ocr.status == "pending" { unread += 1 }
            shots.append(shot)
        }
        shots.sort { $0.id > $1.id } // ids start with the timestamp
        var results: [Result] = []
        for shot in shots where !words.isEmpty && limit > 0 { // --limit 0 asks for nothing: it gets nothing
            let text = flatten(shot.ocr.text ?? "")
            let haystack = text + "\n" + (shot.frontApp ?? "")
            guard words.allSatisfy({ haystack.range(of: $0, options: fold) != nil }) else { continue }
            results.append(Result(path: shot.path, id: shot.id, createdAt: clean(shot.createdAt, max: 40),
                                  frontApp: shot.frontApp.map { clean($0, max: maxFrontApp) },
                                  snippet: clean(snippet(of: text, words: words), max: 90), ocrStatus: clean(shot.ocr.status, max: 16)))
            if results.count >= limit { break }
        }
        return (results, unread)
    }

    /// Hard cap for the app name: it is shown to an agent, so it cannot be a paragraph.
    public static let maxFrontApp = 100

    /// Text that came out of a screenshot (or a hand-edited sidecar) is shown to people and agents: no control characters
    /// (terminal escapes, newlines), no bidi overrides, and a hard length cap.
    static func clean(_ s: String, max: Int) -> String {
        let kept = s.unicodeScalars.filter { u in
            switch u.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: return false
            default: return !(0x202A ... 0x202E).contains(u.value) && !(0x2066 ... 0x2069).contains(u.value)
            }
        }
        var out = String(String.UnicodeScalarView(kept))
        if out.count > max { out = String(out.prefix(max)) + "…" }
        return out
    }

    /// One line: newlines and runs of whitespace become single spaces.
    static func flatten(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// About 80 characters around the first match found in the text (start of the text if only the app matched).
    static func snippet(of text: String, words: [String], width: Int = 80) -> String {
        guard !text.isEmpty else { return "" }
        let hit = words.compactMap { text.range(of: $0, options: fold) }.min { $0.lowerBound < $1.lowerBound }
        let chars = text
        let center = hit.map { chars.distance(from: chars.startIndex, to: $0.lowerBound) } ?? 0
        let start = max(0, min(center - width / 4, chars.count - width))
        let a = chars.index(chars.startIndex, offsetBy: start)
        let b = chars.index(a, offsetBy: min(width, chars.count - start))
        return (start > 0 ? "…" : "") + String(chars[a ..< b]) + (b < chars.endIndex ? "…" : "")
    }

    /// The `--json` payload: an array (empty = `[]`) with path, id, createdAt, frontApp, snippet, ocrStatus.
    public static func json(_ results: [Result]) -> String {
        if results.isEmpty { return "[]" } // JSONSerialization would print "[\n\n]"
        let rows: [[String: Any]] = results.map {
            ["path": $0.path, "id": $0.id, "createdAt": $0.createdAt, "frontApp": $0.frontApp ?? NSNull(),
             "snippet": $0.snippet, "ocrStatus": $0.ocrStatus]
        }
        let data = (try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// `2026-10-24 17:46` in local time; falls back to the id's own stamp.
    public static func display(_ r: Result) -> String {
        if let d = ISO8601DateFormatter().date(from: r.createdAt) {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"
            return f.string(from: d)
        }
        let p = r.id.split(separator: "_")
        return p.count >= 2 ? "\(p[0]) \(p[1].prefix(5).replacingOccurrences(of: "-", with: ":"))" : r.id
    }
}
