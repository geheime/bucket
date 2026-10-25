import AppKit
import BucketCore

/// Headless entry points. Each one exits the process; none touches the status item or hotkeys.
enum Cli {
    static func warn(_ message: String) {
        FileHandle.standardError.write(Data("bucket: \(message)\n".utf8))
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("bucket: \(message)\n".utf8))
        exit(2)
    }

    static let usage = """
        usage: bucket                                   start the menu bar app
               bucket search "<query>" [--limit N] [--json]
               bucket ocr --backfill
               bucket --root <dir> ...                  use another archive instead of ~/Bucket
               bucket --help | --version
        """

    /// The bundle's short version, or "dev" when running a bare binary (swift run, a build without Info.plist).
    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    /// Another process that is this same app (same bundle id, or same executable when unbundled), if any.
    static func otherRunningInstance() -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.first { app in
            guard app.processIdentifier != me, !app.isTerminated else { return false }
            if let id = Bundle.main.bundleIdentifier { return app.bundleIdentifier == id }
            return app.executableURL != nil && app.executableURL == Bundle.main.executableURL
        }
    }

    /// Development subcommands (they write wherever they are told, or exist only to render and test). A release binary
    /// does not answer them unless `BUCKET_DEV=1`, so an agent allowed to run Bucket can only search.
    static let devCommands: Set<String> = ["ingest", "render", "render-motion", "migrate", "motion-smoke", "companion-check", "companion-demo"]

    static func run(_ command: String, _ args: [String], library: Library) -> Never {
        let dev = ProcessInfo.processInfo.environment["BUCKET_DEV"] == "1"
        if devCommands.contains(command), !dev { fail("unknown command '\(command)' (search, ocr --backfill)") }
        switch command {
        case "ingest":
            guard let png = args.first(where: { !$0.hasPrefix("--") }) else { fail("usage: ingest <png>") }
            exit(ingest(URL(fileURLWithPath: png), library: library, waitOCR: args.contains("--wait-ocr")))
        case "render":
            let positional = args.filter { !$0.hasPrefix("--") }
            guard positional.count == 2 else { fail("usage: render <state> <out.png> [--dark]") }
            exit(Render.run(state: positional[0], out: URL(fileURLWithPath: positional[1]), dark: args.contains("--dark")))
        case "migrate":
            let report = Migration.run(library: library, dryRun: args.contains("--dry-run"))
            if args.contains("--dry-run") { print("dry run — nothing was touched"); report.actions.forEach { print("  would: \($0)") } }
            report.warnings.forEach { print("warning: \($0)") }
            report.errors.forEach { print("error: \($0)") }
            print("migration: \(report.summary)")
            exit(report.errors.isEmpty ? 0 : 1)
        case "ocr":
            guard args.contains("--backfill") else { fail("usage: ocr --backfill") }
            if let r = RedactPass.run(library: library), r.redacted + r.dropped > 0 { print("redact: \(r.redacted) redacted, \(r.dropped) dropped") }
            guard OCRSetting.enabled else { warn(OCRSetting.backfillNotice); exit(0) }
            OCRQueue.shared.backfill(library: library)
            OCRQueue.shared.waitUntilIdle()
            let c = OCRQueue.shared.counts
            print("ocr: \(c.done) done, \(c.failed) failed")
            exit(c.failed == 0 ? 0 : 1)
        case "search":
            exit(search(args, library: library))
        case "render-motion":
            exit(MotionRender.run(args))
        case "motion-smoke":
            exit(MotionSmoke.run())
        case "companion-check":
            exit(CompanionCheck.run())
        case "companion-demo":
            CompanionDemo.run()
        default:
            fail("unknown command '\(command)' (" + (dev ? "ingest, render, render-motion, migrate, ocr, search, motion-smoke, companion-check, companion-demo" : "search, ocr --backfill") + ")")
        }
    }

    /// Simulates a capture: screencapture leaves a fresh file in tmp, so we hand over a copy and never touch the source.
    private static func ingest(_ png: URL, library: Library, waitOCR: Bool) -> Int32 {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bucket-\(UUID().uuidString).png")
        do {
            try FileManager.default.copyItem(at: png, to: tmp)
            let shot = try library.ingest(captured: tmp, frontApp: nil)
            BucketStore(library: library).add(shot)
            print(shot.path)
            if waitOCR { OCRQueue.shared.waitUntilIdle() } // the path is already printed: only the exit waits
            return 0
        } catch {
            FileHandle.standardError.write(Data("bucket: ingest failed: \(error.localizedDescription)\n".utf8))
            try? FileManager.default.removeItem(at: tmp)
            return 1
        }
    }

    /// `search "<query>" [--limit N] [--json]`. No results = empty stdout, exit 0.
    private static func search(_ args: [String], library: Library) -> Int32 {
        var limit = 10
        var words: [String] = []
        var jsonOut = false
        var i = 0
        var flagsDone = false // after a bare `--` everything is part of the query
        while i < args.count {
            if !flagsDone, args[i] == "--" { flagsDone = true; i += 1; continue }
            if !flagsDone, args[i].hasPrefix("--"), args[i] != "--limit", args[i] != "--json" {
                fail("unknown option '\(args[i])'\n" + usage)
            }
            if !flagsDone, args[i] == "--limit" {
                guard i + 1 < args.count, let n = Int(args[i + 1]), n >= 0 else { fail("--limit needs a number") }
                limit = n; i += 2
            } else if !flagsDone, args[i] == "--json" { jsonOut = true; i += 1 }
            else { words.append(args[i]); i += 1 }
        }
        let query = words.joined(separator: " ")
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { fail(usage) }
        let (results, unread) = Search.run(library: library, query: query, limit: limit)
        if !OCRSetting.enabled { warn(OCRSetting.searchNotice) }
        if unread > 0 { FileHandle.standardError.write(Data("bucket: \(unread) shots not read yet\n".utf8)) }
        if jsonOut {
            print(Search.json(results))
        } else {
            for r in results { print("\(r.path) · \(Search.display(r)) · \(r.frontApp ?? "-") · \"\(r.snippet)\"") }
        }
        return 0
    }
}
