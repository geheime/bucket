import Foundation

/// How a `screencapture -i` run ended, told from what it leaves behind. Measured on macOS 26 (spike, 02/11/2026):
/// ESC = exit 0, no file, empty stderr. No Screen Recording permission (for example a new ad-hoc signature after an
/// update while Settings still shows the switch on) = exit 1 and "could not create image from rect" on stderr
/// (a full-screen run without -i says "...from display").
public enum CaptureOutcome: Equatable {
    case captured
    case cancelled
    case permissionDenied
    case failed(String)

    /// - Parameters:
    ///   - status: the exit code of screencapture.
    ///   - stderr: what it wrote on standard error.
    ///   - hasImage: a non-empty, readable image file is there.
    public static func classify(status: Int32, stderr: String, hasImage: Bool) -> CaptureOutcome {
        if hasImage { return .captured }
        if status == 0 { return .cancelled } // ESC leaves no file and says nothing
        if stderr.contains("could not create image") { return .permissionDenied }
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(text.isEmpty ? "screencapture exited with status \(status)" : text)
    }
}
