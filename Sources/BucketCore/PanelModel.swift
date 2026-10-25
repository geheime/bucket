import Foundation

/// Panel measures and words. Core so the checks can pin the arithmetic the view relies on.
public enum PanelMetrics {
    public static let width: CGFloat = 360
    public static let header: CGFloat = 52
    public static let thumbSize = CGSize(width: 104, height: 72)
    public static let gridGap: CGFloat = 8
    public static let gridInset: CGFloat = 16
    public static let columns = 3
    public static let maxVisibleRows = 3
    public static let emptyBlock: CGFloat = 136
    public static let separator: CGFloat = 1
    public static let lastBatch: CGFloat = 66
    public static let actions: CGFloat = 68
    public static let footer: CGFloat = 36
    public static let permissionRow: CGFloat = 44
    public static let miniSize = CGSize(width: 32, height: 22)
    public static let maxMinis = 6

    public static func rows(_ shots: Int) -> Int { (shots + columns - 1) / columns }

    /// Grid block: rows × 72 + gaps + 16 below; from the 4th row on, it scrolls inside the 3-row height.
    public static func gridHeight(shots: Int) -> CGFloat {
        let r = min(rows(shots), maxVisibleRows)
        return thumbSize.height * CGFloat(r) + gridGap * CGFloat(max(r - 1, 0)) + gridInset
    }
    /// Full height of the grid content (what the scroll view scrolls).
    public static func gridContentHeight(shots: Int) -> CGFloat {
        let r = rows(shots)
        return thumbSize.height * CGFloat(r) + gridGap * CGFloat(max(r - 1, 0)) + gridInset
    }
    public static func scrolls(shots: Int) -> Bool { rows(shots) > maxVisibleRows }

    /// Column/row cell of the n-th shot (0-based) inside the grid content, y down.
    public static func cell(_ index: Int) -> CGRect {
        let c = index % columns, r = index / columns
        return CGRect(x: gridInset + CGFloat(c) * (thumbSize.width + gridGap), y: CGFloat(r) * (thumbSize.height + gridGap),
                      width: thumbSize.width, height: thumbSize.height)
    }

    /// Without a last batch the section and its separator do not exist (−67).
    public static func height(shots: Int, hasLastBatch: Bool, permissionError: Bool = false) -> CGFloat {
        var h = header + (shots == 0 ? emptyBlock : gridHeight(shots: shots))
        if permissionError { h += permissionRow }
        if hasLastBatch { h += separator + lastBatch }
        return h + separator + actions + footer
    }
}

public enum PanelCopy {
    public static func title(_ count: Int) -> String { CompanionCopy.count(count) }
    public static let copyNow = "Copy now", copied = "Copied", recopy = "Re-copy", recopyHint = "⌥⇧V"
    public static let sendLast = "Send last to Desktop", clear = "Clear bucket"
    public static let remove = "Remove from bucket", showInFinder = "Show in Finder"
    public static let emptyHint = "to capture"
    public static let allSearchable = "All shots searchable"
    public static func lastBatch(_ n: Int) -> String { "Last batch · \(n)" }
    public static func reading(_ n: Int) -> String { n == 1 ? "Reading 1 shot…" : "Reading \(n) shots…" }
    /// "Reading N shots…" while the OCR queue has work, "All shots searchable" otherwise.
    public static func ocr(pending: Int, enabled: Bool = true) -> String { !enabled ? readingOff : pending > 0 ? reading(pending) : allSearchable }
    public static let readingOff = "Text reading is off"

    /// `~/Bucket/2026-10-24`: the folder the next capture lands in. Home is abbreviated to `~`.
    public static func savedIn(root: URL, day: String) -> String {
        (root.appendingPathComponent(day).path as NSString).abbreviatingWithTildeInPath
    }
}
