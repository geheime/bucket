import Foundation

/// "Send last to Desktop": hands the ORIGINAL of the last shot in the bucket to the user,
/// under its readable archive name, and takes it out of the bucket. The archive is never touched.
public enum DesktopSender {
    public enum Result: Equatable {
        case sent(id: String, to: URL)
        case empty
        case failed(String)
    }

    /// `BUCKET_DESKTOP_DIR` is for tests and renders only; the product always lands on the real Desktop.
    public static func desktopDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["BUCKET_DESKTOP_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    /// Copies first, removes from the bucket only after the copy succeeded: a failure leaves everything as it was.
    public static func sendLast(of bucket: BucketStore, to desktop: URL = desktopDirectory()) -> Result {
        guard let shot = bucket.items.last else { return .empty }
        let fm = FileManager.default
        let source = URL(fileURLWithPath: shot.originalPath)
        guard fm.fileExists(atPath: source.path) else { return .failed("Original is missing: \(shot.originalPath)") }
        do {
            try fm.createDirectory(at: desktop, withIntermediateDirectories: true)
            let dest = try copyWithoutOverwriting(source, into: desktop)
            bucket.remove(id: shot.id)
            return .sent(id: shot.id, to: dest)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// `name.png`, then `name 2.png`, `name 3.png`… The copy itself refuses to overwrite, so a file that appears
    /// between the check and the copy just moves us to the next suffix instead of being replaced.
    static func copyWithoutOverwriting(_ source: URL, into dir: URL) throws -> URL {
        let fm = FileManager.default
        let base = source.deletingPathExtension().lastPathComponent, ext = source.pathExtension
        var n = 1
        while true {
            let name = (n == 1 ? base : "\(base) \(n)") + (ext.isEmpty ? "" : ".\(ext)")
            let dest = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: dest.path) {
                do { try fm.copyItem(at: source, to: dest); return dest }
                catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileWriteFileExistsError { /* raced: next suffix */ }
            }
            n += 1
            if n > 10_000 { throw NSError(domain: "Bucket", code: 5, userInfo: [NSLocalizedDescriptionKey: "No free name on the Desktop"]) }
        }
    }
}
