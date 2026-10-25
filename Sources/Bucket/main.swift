import AppKit
import BucketCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusController?
    let library: Library
    init(library: Library) { self.library = library }

    // The status item is created once the app has finished launching; earlier it may never show up.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before the BucketStore exists: it reads bucket.json, which the migration may rewrite.
        let report = Migration.run(library: library, dryRun: false)
        if report.migrated > 0 || !report.errors.isEmpty || !report.warnings.isEmpty {
            NSLog("Bucket: migration \(report.summary)")
            report.warnings.forEach { NSLog("Bucket: migration warning: \($0)") }
            report.errors.forEach { NSLog("Bucket: migration error: \($0)") }
        }
        controller = StatusController(library: library)
        OCRQueue.shared.backfill(library: library) // after the migration: ids and paths are final
    }
}

// Everything Bucket writes (PNG, sidecars with the OCR text, state) is for the owner only, whatever umask we inherit.
umask(0o077)

// Global `--root <dir>` swaps ~/Bucket for an isolated archive; the rest is subcommand + args.
var args = Array(CommandLine.arguments.dropFirst())
var root: URL?
if let i = args.firstIndex(of: "--root") {
    guard i + 1 < args.count else { Cli.fail("--root needs a directory") }
    root = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
    args.removeSubrange(i ... i + 1)
}
if args.contains("--help") || args.contains("-h") { print(Cli.usage); exit(0) }
if args.contains("--version") { print("Bucket \(Cli.version)"); exit(0) }

// One menu bar app at a time. CLI subcommands never get here, so `search` keeps working while the app runs.
if args.isEmpty, let other = Cli.otherRunningInstance() {
    FileHandle.standardError.write(Data("bucket: already running (pid \(other.processIdentifier))\n".utf8))
    exit(0)
}

// `search` only reads: it must not create the archive (or touch its permissions) if the app was never opened.
let readOnly = args.first == "search"
let library = root.map { Library(root: $0, create: !readOnly) } ?? Library(create: !readOnly)
library.ocrOnIngest = true // every capture is read in the background, app and CLI alike

// Headless modes never create the status item nor register hotkeys.
if let command = args.first {
    Cli.run(command, Array(args.dropFirst()), library: library)
}

let app = NSApplication.shared
let delegate = AppDelegate(library: library)
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
