import AppKit

/// How a batch is written into the clipboard.
/// `bare` is the default: Claude Code turns every space-separated image path into an attachment,
/// while in `numbered` only the last path became an image (observed 3/3, 2026-10-24).
public enum PasteFormat: String, CaseIterable {
    case bare, numbered, atPaths, lines

    public var title: String {
        switch self {
        case .numbered: return "Numbered with prompt"
        case .bare: return "Bare paths (recommended)"
        case .atPaths: return "@paths"
        case .lines: return "One path per line"
        }
    }

    public static var current: PasteFormat {
        get { PasteFormat(rawValue: UserDefaults.standard.string(forKey: "pasteFormat") ?? "") ?? .bare }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "pasteFormat") }
    }
}

/// How a path is written into text a shell may read. Three levels, so ordinary paths stay exactly as they were
/// (Claude Code turns bare and double-quoted paths into image attachments) and only odd ones change:
///  1. only plain characters            -> as is
///  2. plain characters plus spaces     -> "double quoted" (as before)
///  3. anything else (`$`, backtick, `"`, `'`, `;`, `&`, parentheses, backslash...) -> every special character gets a backslash, the form Finder produces when
///     you drag a file into a terminal. Not verified against Claude Code yet (see the security notes).
/// Control characters (newline, CR, NUL...) have no safe spelling: the path is not delivered (nil).
public enum ShellQuote {
    private static let plain = CharacterSet.alphanumerics.union(.init(charactersIn: "/._-+@,:%="))

    public static func hasControl(_ p: String) -> Bool {
        p.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    public static func path(_ p: String) -> String? {
        if hasControl(p) { return nil }
        let scalars = p.unicodeScalars
        if scalars.allSatisfy(plain.contains) { return p }
        if scalars.allSatisfy(plain.union(.init(charactersIn: " ")).contains) { return "\"\(p)\"" }
        var out = ""
        for u in scalars {
            if !plain.contains(u) { out.append("\\") }
            out.unicodeScalars.append(u)
        }
        return out
    }
}

/// Fires `onPasted` at most once. Only a request for text or PNG data counts as a paste: desktop apps read the
/// file URL right after activation, before any paste, to validate their Paste menu.
private final class PasteGate {
    private let onPasted: () -> Void
    private var fired = false
    init(_ onPasted: @escaping () -> Void) { self.onPasted = onPasted }
    func requested(_ type: NSPasteboard.PasteboardType) {
        guard type != .fileURL, !fired else { return }
        fired = true
        DispatchQueue.main.async(execute: onPasted)
    }
}

/// Lazy data for one pasteboard item.
private final class PastePromise: NSObject, NSPasteboardItemDataProvider {
    private let text: String?
    private let path: String
    private let gate: PasteGate

    init(text: String?, path: String, gate: PasteGate) {
        self.text = text
        self.path = path
        self.gate = gate
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        Exporter.fill(item, type: type, text: text, path: path)
        gate.requested(type)
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}
}

/// Exporter: turns a batch into text and puts it on the clipboard. Never moves or deletes anything.
public final class Exporter {
    private let library: Library
    private let pasteboard: NSPasteboard
    private var staged = false
    /// Pasteboard generation right after our promise went in: if it changed, the clipboard is no longer ours.
    private var stagedChange = -1
    /// The shots of the last batch we put on the clipboard (stage, restage or copy) and the pasteboard generation right after
    /// that write. While the generation is unchanged the clipboard is still ours and the batch can follow the front app.
    private var lastShots: [Shot] = []
    private var lastChange = -1

    /// `pasteboard` is injectable so checks never touch the real clipboard.
    public init(library: Library, pasteboard: NSPasteboard = .general) {
        self.library = library
        self.pasteboard = pasteboard
    }

    /// Only shots whose png is still on disk: a path that does not exist is never handed to the clipboard (logged, nothing deleted).
    public static func deliverable(_ shots: [Shot]) -> [Shot] {
        shots.filter { shot in
            if ShellQuote.hasControl(shot.path) {
                NSLog("Bucket: skipped \(shot.id) from the clipboard (its path has control characters)")
                return false
            }
            let there = FileManager.default.fileExists(atPath: shot.path)
            if !there { NSLog("Bucket: skipped \(shot.id) from the clipboard (png missing at \(shot.path))") }
            return there
        }
    }

    public static func render(_ shots: [Shot], format: PasteFormat) -> String {
        // A path that cannot be written safely (control characters) never reaches the clipboard, in any format.
        let shots = shots.filter { shot in
            let ok = ShellQuote.path(shot.path) != nil
            if !ok { NSLog("Bucket: skipped \(shot.id) from the clipboard (its path has control characters)") }
            return ok
        }
        let quoted = shots.compactMap { ShellQuote.path($0.path) }
        switch format {
        case .numbered:
            let noun = shots.count == 1 ? "this screenshot" : "these screenshots in order"
            let list = quoted.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            return "Read \(noun):\n\(list)\n"
        case .bare: return quoted.joined(separator: " ") + " "
        case .atPaths: return quoted.map { "@\($0)" }.joined(separator: " ") + " "
        case .lines: return quoted.joined(separator: "\n") + "\n"
        }
    }

    /// The pasteboard types offered for each mode.
    public static func types(for mode: PasteMode) -> [NSPasteboard.PasteboardType] {
        switch mode {
        case .terminal: return [.string]
        case .browser: return [.png]
        case .app: return [.fileURL, .png]
        }
    }

    static let transientMarker = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let autoGeneratedMarker = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")

    fileprivate static func fill(_ item: NSPasteboardItem, type: NSPasteboard.PasteboardType, text: String?, path: String) {
        switch type {
        case .string: if let text { item.setString(text, forType: .string) }
        case .fileURL: item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
        case .png: if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) { item.setData(data, forType: .png) }
        default: break
        }
    }

    /// The pasteboard items for a batch (already filtered with `deliverable`). Terminal: one item with the rendered text.
    /// Browser and app: one item per screenshot. With a `gate` the data is lazy; without, it is written now.
    /// Lazy items also carry the clipboard-manager markers, so history tools skip our churn.
    private func items(for shots: [Shot], mode: PasteMode, gate: PasteGate?) -> [NSPasteboardItem] {
        let types = Exporter.types(for: mode)
        let units: [(text: String?, path: String)] = mode == .terminal
            ? [(Exporter.render(shots, format: .current), shots[0].path)]
            : shots.map { (nil, $0.path) }
        return units.map { unit in
            let item = NSPasteboardItem()
            if let gate {
                item.setDataProvider(PastePromise(text: unit.text, path: unit.path, gate: gate), forTypes: types)
                item.setData(Data(), forType: Exporter.transientMarker)
                item.setData(Data(), forType: Exporter.autoGeneratedMarker)
            } else {
                for type in types { Exporter.fill(item, type: type, text: unit.text, path: unit.path) }
            }
            return item
        }
    }

    /// Puts the whole bucket on the clipboard as a promise. `onPasted` fires once, the first time something
    /// asks for the text or the PNG (normally your ⌘V); asking for the file URL alone does not count.
    public func stage(_ all: [Shot], mode: PasteMode = .terminal, onPasted: @escaping () -> Void) {
        let shots = Exporter.deliverable(all)
        guard !shots.isEmpty else { return }
        let pb = pasteboard
        pb.clearContents()
        pb.writeObjects(items(for: shots, mode: mode, gate: PasteGate(onPasted)))
        staged = true
        stagedChange = pb.changeCount
        lastShots = shots
        lastChange = pb.changeCount
    }

    /// Lays the last batch out again for another front app while the clipboard is still our last write (nobody copied
    /// anything since). Lazy like `stage`, with the same items and markers, but no paste action: the batch was already
    /// pasted or recorded, so `onPasted` must not fire again. Returns whether it wrote.
    @discardableResult
    public func relayout(mode: PasteMode) -> Bool {
        guard !lastShots.isEmpty, pasteboard.changeCount == lastChange else { return false }
        let shots = Exporter.deliverable(lastShots)
        guard !shots.isEmpty else { return false }
        let pb = pasteboard
        pb.clearContents()
        pb.writeObjects(items(for: shots, mode: mode, gate: PasteGate({})))
        lastChange = pb.changeCount
        return true
    }

    /// Stages again for another front app, but only while our promise is still what the clipboard holds:
    /// something the user copied in the meantime is never replaced. Returns whether it re-staged.
    @discardableResult
    public func restage(_ all: [Shot], mode: PasteMode, onPasted: @escaping () -> Void) -> Bool {
        guard isStaged else { return false }
        stage(all, mode: mode, onPasted: onPasted)
        return true
    }

    /// True while the clipboard still holds the promise we made (nobody copied anything since).
    public var isStaged: Bool { staged && pasteboard.changeCount == stagedChange }

    /// The bucket lost shots (removed, cleared, sent to the Desktop): a promise made for the old content must not
    /// paste them. Clears the clipboard only if our promise is still what it holds; anything the user copied since stays.
    public func unstage() {
        defer { staged = false; lastShots = [] }
        guard isStaged else { return }
        pasteboard.clearContents()
    }

    /// Copies eagerly (no promise) and records the batch.
    public func copy(_ all: [Shot], mode: PasteMode = .terminal, recopy: Bool = false) {
        let shots = Exporter.deliverable(all)
        guard !shots.isEmpty else { return }
        staged = false
        let pb = pasteboard
        pb.clearContents()
        pb.writeObjects(items(for: shots, mode: mode, gate: nil))
        lastShots = shots
        lastChange = pb.changeCount
        record(shots, via: recopy ? "recopy" : "copy")
    }

    /// `copiedAt`, not `sentAt`: we know the text left the clipboard, not that the agent read it.
    public func record(_ shots: [Shot], via: String) {
        let batchID = UUID().uuidString.prefix(8).lowercased()
        let record: [String: Any] = [
            "batchId": String(batchID),
            "copiedAt": ISO8601DateFormatter().string(from: Date()),
            "via": via,
            "format": PasteFormat.current.rawValue,
            "ids": shots.map(\.id),
        ]
        appendLine(record, to: library.root.appendingPathComponent("batches.jsonl"))

        // Read-modify-write on the disk copy: the Shot we hold may be stale (OCR can have written since).
        for shot in shots {
            do { try library.update(sidecar: shot.sidecarPath) { $0.batches.append(String(batchID)) } }
            catch { NSLog("Bucket: could not record batch \(batchID) on \(shot.id): \(error.localizedDescription)") }
        }
    }

    private func appendLine(_ object: [String: Any], to url: URL) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return }
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
