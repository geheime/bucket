import Foundation

/// Bucket: the ordered queue of shots waiting to be copied. Persistent, but feels temporary.
/// Never deletes files — removing only drops a shot from the next batch.
public final class BucketStore {
    private struct State: Codable {
        public var items: [String] = []      // sidecar paths, in capture order
        public var lastBatch: [String] = []
    }

    private let library: Library
    private let file: URL
    private var state = State()

    public var onChange: (() -> Void)?

    public init(library: Library) {
        self.library = library
        self.file = library.stateDir.appendingPathComponent("bucket.json")
        if FileManager.default.fileExists(atPath: file.path) {
            if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(State.self, from: data) {
                state = saved
            } else {
                setAsideCorruptState() // never rewrite over a file we could not read: that would lose the queue silently
            }
        }
        _ = items; _ = lastBatch // drops paths that no longer load, so count and items agree from the first call
    }

    /// Shots of the bucket that load. A path whose sidecar is gone or unreadable is dropped from the state (the files stay).
    public var items: [Shot] {
        let (shots, kept) = loadable(state.items)
        if kept.count != state.items.count { state.items = kept; persistQuietly(); notifyPruned() }
        return shots
    }

    public var lastBatch: [Shot] {
        let (shots, kept) = loadable(state.lastBatch)
        if kept.count != state.lastBatch.count { state.lastBatch = kept; persistQuietly(); notifyPruned() }
        return shots
    }

    public var count: Int { items.count }

    /// Pruning happens inside getters the UI is reading from: tell it on the next runloop turn, never re-entrantly.
    private func notifyPruned() {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    private func loadable(_ paths: [String]) -> (shots: [Shot], kept: [String]) {
        var shots: [Shot] = [], kept: [String] = []
        for path in paths {
            if let shot = library.load(sidecar: path) { shots.append(shot); kept.append(path) }
            else { NSLog("Bucket: dropped \(path) from the bucket state (sidecar missing or unreadable; no file was touched)") }
        }
        return (shots, kept)
    }

    private func setAsideCorruptState() {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmssSSS"
        let aside = file.deletingLastPathComponent().appendingPathComponent("bucket.json.corrupt-\(f.string(from: Date()))")
        do {
            try FileManager.default.moveItem(at: file, to: aside)
            NSLog("Bucket: bucket.json was unreadable, moved to \(aside.lastPathComponent); starting with an empty bucket")
        } catch {
            NSLog("Bucket: bucket.json is unreadable and could not be moved aside (\(error.localizedDescription))")
        }
    }

    public func add(_ shot: Shot) {
        state.items.append(shot.sidecarPath)
        persist()
    }

    public func remove(id: String) {
        state.items.removeAll { ($0 as NSString).lastPathComponent.hasPrefix(id) }
        persist()
    }

    public func clear() {
        state.items.removeAll()
        persist()
    }

    /// Empties the active bucket and keeps what was in it as the last batch.
    public func takeBatch() -> [Shot] {
        let hadEntries = !state.items.isEmpty
        let shots = items // ghosts are dropped here, so only what loads can become the last batch
        guard !shots.isEmpty else { // never overwrite the last batch with nothing
            if hadEntries { onChange?() } // the bucket was only ghosts: it just became empty
            return []
        }
        state.lastBatch = state.items
        state.items.removeAll()
        persist()
        return shots
    }

    private func persist() {
        persistQuietly()
        onChange?()
    }

    private func persistQuietly() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
