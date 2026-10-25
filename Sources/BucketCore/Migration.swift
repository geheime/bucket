import Foundation

/// v0.1 → v0.2 archive layout: `yyyy/MM/dd/yyyyMMdd-HHmmss-xxxx.*` → `yyyy-MM-dd/yyyy-MM-dd_HH-mm-ss_xxxx.*`.
/// Idempotent and resumable: every step looks at the disk, so a run that died halfway is finished by the next one.
/// Never deletes a file (only directories left empty, via rmdir, which refuses non-empty ones; the Finder's `.DS_Store`
/// inside such a directory goes with it) and never overwrites one.
public enum Migration {
    public struct Report {
        public var migrated = 0
        public var alreadyOK = 0
        public var actions: [String] = []   // what was done (or, in a dry run, what would be done)
        public var warnings: [String] = []
        public var errors: [String] = []

        public var summary: String { "\(migrated) migrated, \(alreadyOK) already ok, \(errors.count) errors" }
    }

    /// old id → where it went. Paths are relative to the archive root so the file survives a copy of the archive.
    private struct Entry: Codable, Equatable {
        var newId: String
        var oldPath: String, newPath: String
        var oldOriginalPath: String, newOriginalPath: String
    }

    private struct Map: Codable, Equatable {
        var version = 2
        var shots: [String: Entry] = [:]
    }

    private struct Legacy {
        let oldID: String, newID: String
        let png: (src: URL, dst: URL)
        let original: (src: URL, dst: URL)
        let json: (src: URL, dst: URL)
    }

    public static func run(library: Library, dryRun: Bool) -> Report {
        var report = Report()
        let root = library.root
        // Directory listings come back symlink-resolved (/private/var/...), so strip either spelling of the root.
        func rel(_ u: URL) -> String {
            for prefix in [root.path + "/", "/private" + root.path + "/"] where u.path.hasPrefix(prefix) { return String(u.path.dropFirst(prefix.count)) }
            return u.path
        }

        let legacy = findLegacy(root)
        // Compared symlink-resolved on both sides: /var/... and /private/var/... are the same sidecar.
        let legacyDsts = Set(legacy.map { $0.json.dst.resolvingSymlinksInPath().path })

        // New-layout sidecars: count the consistent ones, queue the ones with a stale id/path (a run that died after the move).
        var stale: [(url: URL, shot: Shot)] = []
        for url in newSidecars(root) where !legacyDsts.contains(url.resolvingSymlinksInPath().path) {
            guard let shot = library.loadRaw(sidecar: url.path) else {
                report.warnings.append("unreadable sidecar: \(rel(url))"); continue
            }
            if isConsistent(shot, sidecar: url) { report.alreadyOK += 1 } else { stale.append((url, shot)) }
        }

        // Write-ahead: the old→new map is saved before anything moves, so a crash never loses a mapping.
        var map = loadMap(library)
        let before = map
        for l in legacy { map.shots[l.oldID] = entry(l, rel) }
        for (url, shot) in stale where Library.isLegacyID(shot.id) && map.shots[shot.id] == nil { // a resumed run keeps the real old paths
            let base = url.deletingPathExtension().lastPathComponent
            let day = url.deletingLastPathComponent().lastPathComponent
            map.shots[shot.id] = Entry(newId: base, oldPath: "?/\(shot.id).png", newPath: "\(day)/\(base).png",
                                       oldOriginalPath: "?/originals/\(shot.id).png", newOriginalPath: "originals/\(day)/\(base).png")
        }
        if map != before {
            report.actions.append("write .state/migration-v02.json (\(map.shots.count) ids)")
            if !dryRun { saveMap(map, library, &report) }
        }

        var movedSources = Set<String>()
        var settled = Set<String>() // new ids whose shot is fully at the new place (this run or an earlier one)
        for l in legacy {
            let errorsBefore = report.errors.count
            if migrate(l, library: library, dryRun: dryRun, rel: rel, report: &report, moved: &movedSources) { report.migrated += 1 }
            if report.errors.count == errorsBefore { settled.insert(l.newID) }
        }
        for (url, shot) in stale {
            report.actions.append("rewrite sidecar \(rel(url)) (stale id \(shot.id))")
            if !dryRun {
                do { try fix(url, library: library); report.migrated += 1; settled.insert(url.deletingPathExtension().lastPathComponent) }
                catch { report.errors.append("\(rel(url)): \(error.localizedDescription)") }
            } else { report.migrated += 1; settled.insert(url.deletingPathExtension().lastPathComponent) }
        }

        // A shot still found at the old place only counts when this run settled it; any other id counts when its new sidecar is sound.
        let stillLegacy = Set(legacy.map(\.newID))
        func isSettled(_ newID: String) -> Bool {
            if settled.contains(newID) { return true }
            if stillLegacy.contains(newID) { return false }
            guard let day = Library.day(of: newID) else { return false }
            let sidecar = root.appendingPathComponent(day).appendingPathComponent("\(newID).json")
            guard let shot = library.loadRaw(sidecar: sidecar.path) else { return false }
            return isConsistent(shot, sidecar: sidecar)
        }
        rewriteState(library, dryRun: dryRun, settled: isSettled, report: &report)
        pruneEmptyDirs(root, dryRun: dryRun, moved: movedSources, rel: rel, report: &report)
        return report
    }

    // MARK: Discovery

    private static func subdirs(_ dir: URL, matching pattern: String) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.filter { ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) && Library.matches($0.lastPathComponent, pattern) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func files(_ dir: URL, ext: String) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == ext }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func findLegacy(_ root: URL) -> [Legacy] {
        var out: [Legacy] = []
        for y in subdirs(root, matching: #"\d{4}"#) {
            for m in subdirs(y, matching: #"\d{2}"#) {
                for d in subdirs(m, matching: #"\d{2}"#) {
                    for json in files(d, ext: "json") {
                        let old = json.deletingPathExtension().lastPathComponent
                        guard let new = Library.newID(fromLegacy: old), let day = Library.day(of: old) else { continue }
                        let comps = "\(y.lastPathComponent)/\(m.lastPathComponent)/\(d.lastPathComponent)"
                        let newDir = root.appendingPathComponent(day)
                        let newOrig = root.appendingPathComponent("originals").appendingPathComponent(day)
                        out.append(Legacy(
                            oldID: old, newID: new,
                            png: (d.appendingPathComponent("\(old).png"), newDir.appendingPathComponent("\(new).png")),
                            original: (root.appendingPathComponent("originals/\(comps)/\(old).png"), newOrig.appendingPathComponent("\(new).png")),
                            json: (json, newDir.appendingPathComponent("\(new).json"))))
                    }
                }
            }
        }
        return out
    }

    private static func newSidecars(_ root: URL) -> [URL] {
        subdirs(root, matching: #"\d{4}-\d{2}-\d{2}"#).flatMap { files($0, ext: "json") }
            .filter { Library.isID($0.deletingPathExtension().lastPathComponent) }
    }

    /// Root-agnostic on purpose (suffix match): an archive that was copied elsewhere is not "stale" just for that.
    private static func isConsistent(_ shot: Shot, sidecar: URL) -> Bool {
        let base = sidecar.deletingPathExtension().lastPathComponent
        let day = sidecar.deletingLastPathComponent().lastPathComponent
        return shot.id == base && shot.path.hasSuffix("/\(day)/\(base).png") && shot.originalPath.hasSuffix("/originals/\(day)/\(base).png")
    }

    private static func entry(_ l: Legacy, _ rel: (URL) -> String) -> Entry {
        Entry(newId: l.newID, oldPath: rel(l.png.src), newPath: rel(l.png.dst),
              oldOriginalPath: rel(l.original.src), newOriginalPath: rel(l.original.dst))
    }

    // MARK: Moving

    /// Returns true if the shot needed work. png and original go first, the sidecar last: while the old sidecar
    /// is still in place the next run rediscovers the shot and picks up where this one stopped.
    private static func migrate(_ l: Legacy, library: Library, dryRun: Bool, rel: (URL) -> String,
                                report: inout Report, moved: inout Set<String>) -> Bool {
        let fm = FileManager.default
        let pairs = [("png", l.png), ("original", l.original), ("sidecar", l.json)]

        // Preflight: never overwrite. Same bytes at both ends = leftover duplicate (warn); different bytes = conflict, skip the shot.
        for (what, p) in pairs where fm.fileExists(atPath: p.src.path) && fm.fileExists(atPath: p.dst.path) {
            if !sameContent(what, p.src, p.dst, fm) {
                report.errors.append("\(l.oldID): \(what) differs at \(rel(p.dst)) — left untouched")
                return false
            }
        }

        var worked = false
        var done: [(src: URL, dst: URL)] = [] // moves of THIS shot, undone in reverse if a later step fails
        /// Puts back what this shot already moved, so the legacy sidecar keeps matching its files. Moves only, never deletes.
        func rollBack() {
            for m in done.reversed() {
                do { try fm.moveItem(at: m.dst, to: m.src); moved.remove(m.src.path) }
                catch { report.errors.append("\(l.oldID): could not undo the move of \(rel(m.src)): \(error.localizedDescription)") }
            }
            done.removeAll()
            worked = false
        }
        for (what, p) in pairs {
            let srcThere = fm.fileExists(atPath: p.src.path), dstThere = fm.fileExists(atPath: p.dst.path)
            if srcThere && dstThere {
                report.warnings.append("\(l.oldID): \(what) exists at both \(rel(p.src)) and \(rel(p.dst)), identical — old one kept (nothing is deleted)")
            } else if srcThere {
                report.actions.append("move \(rel(p.src)) -> \(rel(p.dst))")
                worked = true
                moved.insert(p.src.path)
                if dryRun { continue }
                do {
                    try fm.createDirectory(at: p.dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: p.src, to: p.dst)
                    done.append((p.src, p.dst))
                } catch {
                    report.errors.append("\(l.oldID): \(what): \(error.localizedDescription)")
                    rollBack() // the shot goes back to the old place whole: next run retries
                    return worked
                }
            } else if !dstThere {
                report.warnings.append("\(l.oldID): \(what) missing (\(rel(p.src)))")
            }
        }

        if !dryRun, fm.fileExists(atPath: l.json.dst.path) {
            if let shot = library.loadRaw(sidecar: l.json.dst.path), isConsistent(shot, sidecar: l.json.dst) { return worked }
            do { try fix(l.json.dst, library: library); worked = true }
            catch { report.errors.append("\(l.oldID): sidecar rewrite: \(error.localizedDescription)"); rollBack() }
        } else if dryRun {
            report.actions.append("rewrite sidecar \(rel(l.json.dst)) (id, path, originalPath)")
        }
        return worked
    }

    /// Same bytes, or (sidecars only) the same shot apart from id/path/originalPath: those three are exactly what a
    /// finished run rewrites in the new copy, so a leftover old copy still matches it on every later run.
    private static func sameContent(_ what: String, _ src: URL, _ dst: URL, _ fm: FileManager) -> Bool {
        if fm.contentsEqual(atPath: src.path, andPath: dst.path) { return true }
        guard what == "sidecar", let a = try? Data(contentsOf: src), let b = try? Data(contentsOf: dst),
              var x = try? JSONDecoder().decode(Shot.self, from: a), var y = try? JSONDecoder().decode(Shot.self, from: b) else { return false }
        x.id = ""; x.path = ""; x.originalPath = ""
        y.id = ""; y.path = ""; y.originalPath = ""
        return x == y
    }

    /// Points a sidecar at its own location: id, path and originalPath all derive from where the file sits.
    private static func fix(_ sidecar: URL, library: Library) throws {
        let id = sidecar.deletingPathExtension().lastPathComponent
        let day = sidecar.deletingLastPathComponent().lastPathComponent
        let dir = library.root.appendingPathComponent(day) // from the root, not from the enumerated URL (it may be symlink-resolved)
        try library.update(sidecar: sidecar.path) { shot in
            shot.id = id
            shot.path = dir.appendingPathComponent("\(id).png").path
            shot.originalPath = library.root.appendingPathComponent("originals/\(day)/\(id).png").path
        }
    }

    // MARK: State, map, empty dirs

    private static func mapURL(_ library: Library) -> URL { library.stateDir.appendingPathComponent("migration-v02.json") }

    private static func loadMap(_ library: Library) -> Map {
        (try? Data(contentsOf: mapURL(library))).flatMap { try? JSONDecoder().decode(Map.self, from: $0) } ?? Map()
    }

    private static func saveMap(_ map: Map, _ library: Library, _ report: inout Report) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do { try enc.encode(map).write(to: mapURL(library), options: .atomic) }
        catch { report.errors.append("migration-v02.json: \(error.localizedDescription)") }
    }

    /// bucket.json holds sidecar paths. An entry with a legacy id is pointed at its new sidecar only if that shot is settled
    /// there; an unmigrated shot (conflict, error) keeps pointing at the sidecar that still exists. The rest is left as is.
    private static func rewriteState(_ library: Library, dryRun: Bool, settled: (String) -> Bool, report: inout Report) {
        let file = library.stateDir.appendingPathComponent("bucket.json")
        guard let data = try? Data(contentsOf: file), var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        var changed = 0
        for key in ["items", "lastBatch"] {
            guard let paths = obj[key] as? [String] else { continue }
            obj[key] = paths.map { path -> String in
                let url = URL(fileURLWithPath: path)
                guard let new = Library.newID(fromLegacy: url.deletingPathExtension().lastPathComponent),
                      let day = Library.day(of: new), settled(new) else { return path }
                changed += 1
                return library.root.appendingPathComponent(day).appendingPathComponent("\(new).\(url.pathExtension)").path
            }
        }
        guard changed > 0 else { return }
        report.actions.append("rewrite .state/bucket.json (\(changed) paths)")
        guard !dryRun else { return }
        do {
            let out = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
            try out.write(to: file, options: .atomic)
        } catch { report.errors.append("bucket.json: \(error.localizedDescription)") }
    }

    /// Removes old yyyy/MM/dd dirs (root and originals/) that hold nothing. rmdir cannot remove a dir with anything inside.
    /// In a dry run, `moved` stands in for the files that a real run would already have moved away.
    private static func pruneEmptyDirs(_ root: URL, dryRun: Bool, moved: Set<String>, rel: (URL) -> String, report: inout Report) {
        let fm = FileManager.default
        func prune(_ dir: URL, depth: Int) -> Bool {
            let children = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            var empty = true
            var finder: URL?
            for c in children {
                if c.lastPathComponent == ".DS_Store" { finder = c; continue } // Finder metadata, not the user's: does not keep a dir alive
                let isDir = (try? c.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir, depth < 3, Library.matches(c.lastPathComponent, #"\d{2}"#) { if !prune(c, depth: depth + 1) { empty = false } }
                else if !moved.contains(c.path) { empty = false }
            }
            guard empty else { return false }
            report.actions.append("remove empty dir \(rel(dir))")
            if dryRun { return true }
            if let finder { try? fm.removeItem(at: finder) } // the only file ever removed, and only from a dir that holds nothing else
            return rmdir(dir.path) == 0
        }
        for base in [root, root.appendingPathComponent("originals")] {
            for year in subdirs(base, matching: #"\d{4}"#) { _ = prune(year, depth: 1) }
        }
    }
}
