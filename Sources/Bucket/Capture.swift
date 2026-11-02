import AppKit
import BucketCore

/// Capturer: runs Apple's native selection UI and hands back a valid image file.
/// Knows nothing about the bucket or the archive.
enum CaptureResult {
    case captured(URL)
    case cancelled
    /// screencapture itself failed for lack of Screen Recording (see `CaptureOutcome`): not an ESC.
    case permissionDenied
    case failed(String)
}

final class Capturer {
    private var busy = false
    var isBusy: Bool { busy }

    func capture(completion: @escaping (CaptureResult) -> Void) {
        guard !busy else { return }
        busy = true

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bucket-\(UUID().uuidString).png")

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // -i interactive selection (space toggles window mode), -x no sound
            process.arguments = ["-i", "-x", tmp.path]

            let stderr = Pipe()
            process.standardError = stderr

            var result: CaptureResult
            do {
                try process.run()
                // EOF comes when screencapture exits, and its stderr is a line or two: reading here cannot fill the pipe.
                let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                process.waitUntilExit()
                let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.size] as? Int
                let hasImage = (size ?? 0) > 0 && NSImage(contentsOf: tmp) != nil
                switch CaptureOutcome.classify(status: process.terminationStatus, stderr: errText, hasImage: hasImage) {
                case .captured: result = .captured(tmp)
                case .cancelled: result = .cancelled
                case .permissionDenied: result = .permissionDenied
                case .failed(let message): result = .failed(message)
                }
            } catch {
                result = .failed(error.localizedDescription)
            }

            DispatchQueue.main.async {
                self.busy = false
                completion(result)
            }
        }
    }
}
