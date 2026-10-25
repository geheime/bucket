import AppKit

/// Capturer: runs Apple's native selection UI and hands back a valid image file.
/// Knows nothing about the bucket or the archive.
enum CaptureResult {
    case captured(URL)
    case cancelled
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

            var result: CaptureResult
            do {
                try process.run()
                process.waitUntilExit()
                if let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.size] as? Int,
                   size > 0, NSImage(contentsOf: tmp) != nil {
                    result = .captured(tmp)
                } else {
                    // ESC leaves no file. Anything else without a file is reported as cancel too,
                    // because screencapture gives no distinct exit code we can rely on.
                    result = .cancelled
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
