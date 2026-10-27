import AppKit
import BucketCore
import Carbon

/// UI: menu bar icon + menu. Shows state and triggers actions; never touches files itself.
final class StatusController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: StatusController.itemLength)
    private let library: Library
    private let bucket: BucketStore
    private let exporter: Exporter
    private let capturer = Capturer()
    private let companion: Companion
    private let keycaps = KeycapOverlay()
    private let errorPill = ErrorPill()
    private let panel: PanelController
    /// The bar icon waits for the companion's animation (it changes when the drop lands).
    private var barHeld = false
    /// No Screen Recording permission: the bar shows `bucket.slash`. Checked at launch and on every capture attempt.
    private var permissionMissing = false
    /// The status-item menu is tracking (menuWillOpen → menuDidClose). A capture asked meanwhile waits for it to close.
    private var menuOpen = false
    private var capturePending = false

    static let seedPosition = 400
    /// Fixed item width: the 18 pt glyph sits centered, no count text beside it.
    static let itemLength: CGFloat = 28

    /// Hook for the primary click: the panel. The secondary click (right, ⌃) is always the menu.
    var onPrimaryClick: (() -> Void)?
    private let menu = NSMenu()
    /// ⌥⇧V could not be registered (another app holds it): the menu says so, the panel's Re-copy button still works.
    private var recopyShortcutTaken = false
    private var clearShortcutTaken = false
    /// How the clipboard is laid out, from the last non-system app that was frontmost.
    private var pasteMode: PasteMode = .terminal

    init(library: Library) {
        self.library = library
        self.bucket = BucketStore(library: library)
        self.exporter = Exporter(library: library)
        self.companion = Companion(count: bucket.count)
        self.panel = PanelController(library: library, bucket: bucket)
        super.init()

        // New items land next to the notch on crowded menu bars. A fixed autosave name lets us
        // seed a position closer to the right edge; the user can still ⌘-drag it afterwards.
        let positionKey = "NSStatusItem Preferred Position BucketStatusItem"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(StatusController.seedPosition, forKey: positionKey)
        }
        item.autosaveName = "BucketStatusItem"

        menu.delegate = self
        onPrimaryClick = { [weak self] in self?.panel.toggle() }
        panel.statusFrame = { [weak self] in self?.item.button?.window?.frame }
        // Same menu as the right click, opened from the gear in the panel's footer (single source of settings).
        panel.showSettingsMenu = { [weak self] view, point in
            guard let self else { return }
            self.menu.popUp(positioning: nil, at: point, in: view)
        }
        panel.onOpenChanged = { [weak self] open in self?.companion.panelOpen = open }
        panel.actions = (
            copyNow: { [weak self] in self?.copyBatch(); self?.panel.confirmCopyNow() },
            recopy: { [weak self] in self?.recopyLastBatch() },
            sendLast: { [weak self] in self?.sendLastToDesktop() },
            clear: { [weak self] in self?.clearBucket() },
            remove: { [weak self] id in self?.removeShot(id: id) })
        // No `item.menu`: with one set, AppKit swallows the click and the left/right routing never runs.
        item.button?.target = self
        item.button?.action = #selector(statusClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        bucket.onChange = { [weak self] in
            guard let self else { return }
            self.panel.refresh()
            if !self.barHeld { self.refreshIcon() }
        }
        companion.statusFrame = { [weak self] in self?.item.button?.window?.frame }
        companion.barHold = { [weak self] held in self?.barHeld = held }
        companion.barShow = { [weak self] bounce in
            self?.refreshIcon()
            if bounce { self?.bounceBar() }
        }
        errorPill.permissionGranted = { CGPreflightScreenCaptureAccess() }
        errorPill.onGranted = { [weak self] in self?.permissionMissing = false; self?.refreshIcon() }
        permissionMissing = !CGPreflightScreenCaptureAccess()
        // The user grants the permission in System Settings and comes back: any app activating re-checks it, only while the slash
        // is up (no timer). The pill's own poll dies when it opens Settings, so nothing else would clear the slash.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.permissionMissing, CGPreflightScreenCaptureAccess() else { return }
            self.permissionMissing = false
            self.refreshIcon()
        }
        if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           let mode = PasteTarget.mode(for: PasteTarget.classify(bundleID: id)) { pasteMode = mode }
        // The front app changed: lay the clipboard out for it, but only while our promise is still what it holds.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let mode = PasteTarget.mode(for: PasteTarget.classify(bundleID: app?.bundleIdentifier)) else { return }
            guard mode != self.pasteMode else { return } // the clipboard is already laid out for this kind
            self.pasteMode = mode
            if self.bucket.count > 0 && self.exporter.isStaged { self.stageBucket() } else { self.exporter.relayout(mode: mode) }
        }
        refreshIcon()
        companion.start()
        if ProcessInfo.processInfo.environment["BUCKET_DEBUG"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                FileHandle.standardError.write("status frame=\(String(describing: self.item.button?.window?.frame))\n".data(using: .utf8)!)
            }
        }

        // Capture (default ⌘⇧4, the clipboard is staged right away) · ⌥⇧V copy now / re-copy last batch.
        let captureTaken = !registerCapture(Shortcut.capture) // the menu keeps saying it (menuNeedsUpdate): captureShortcutTaken
        recopyShortcutTaken = !Hotkeys.register(id: 2, keyCode: kVK_ANSI_V, modifiers: optionKey | shiftKey) { [weak self] in
            self?.keycaps.show(.recopy, captureSymbols: Shortcut.capture.symbols) // ⌥⇧V always teaches itself
            self?.copyBatch()
        }
        // ⌥⇧X empties the bucket by hand: some apps read the clipboard before the paste, so the promise never says "pasted".
        clearShortcutTaken = !Hotkeys.register(id: 3, keyCode: kVK_ANSI_X, modifiers: optionKey | shiftKey) { [weak self] in
            self?.clearFromShortcut()
        }
        // One pill, not two: if several failed, the capture one wins (it is the shortcut the app is for); the menu names each.
        if captureTaken || recopyShortcutTaken || clearShortcutTaken || nativeScreenshotConflict { companion.feedback(CompanionCopy.shortcutTaken) } // the menu keeps saying it
    }

    /// Bucket's capture shortcut is Cmd+Shift+4 and the macOS one is still on: Carbon lets us register it, but macOS wins
    /// silently. Read from the system settings each time, never written; if it cannot be read, there is no conflict to report.
    private var nativeScreenshotConflict: Bool {
        Shortcut.capture.id == "cmdShift4" && NativeShortcuts.nativeAreaScreenshotEnabled() == true
    }

    /// Nothing holds the capture combo (id 1): another app has it. Read from Carbon, so it also follows a later successful switch.
    private var captureShortcutTaken: Bool { Hotkeys.registered(id: 1) == nil }

    private func registerCapture(_ sc: Shortcut) -> Bool {
        Hotkeys.register(id: 1, keyCode: sc.keyCode, modifiers: sc.modifiers, handler: { [weak self] in self?.capture() })
    }

    /// The new preset is registered first; the preference changes only if that worked. Otherwise the previous one stays.
    @objc func setCaptureShortcut(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let sc = Shortcut.presets.first(where: { $0.id == id }) else { return }
        let result = ShortcutSwitch.apply(wanted: sc, current: Shortcut.capture, register: registerCapture, save: { Shortcut.capture = $0 })
        if !result.switched { companion.feedback(CompanionCopy.shortcutTaken) }
    }

    // MARK: Actions

    @objc func capture() {
        guard !capturer.isBusy else { return }
        // Our own menu open: menu tracking owns the mouse (a click outside dismisses it), so screencapture's first click would be
        // eaten and the crosshair would hang. Close it first and start once it is gone. macOS can capture an open menu, we cannot.
        if menuOpen {
            NSLog("Bucket: capture asked with the menu open: closing it first")
            menu.cancelTrackingWithoutAnimation()
            guard !capturePending else { return }
            capturePending = true
            // menuDidClose resumes it; this is the net if that callback never comes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.resumeCapture() }
            return
        }
        // No permission: the error pill (the only clickable piece) instead of a capture that would come back empty.
        guard CGPreflightScreenCaptureAccess() else { requestScreenAccess(); permissionDenied(); return }
        if permissionMissing { permissionMissing = false; refreshIcon() } // granted since the last attempt

        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName
        let frontBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Law: every Bucket window is off screen BEFORE screencapture starts, then one runloop turn so the
        // window server has really removed them.
        companion.beginCapture()
        BucketWindows.hideAll()
        CATransaction.flush()
        DispatchQueue.main.async { [weak self] in
            self?.capturer.capture { [weak self] result in self?.captured(result, frontApp: frontApp, frontBundleId: frontBundleId) }
        }
    }

    /// The capture that waited for the menu to close (once: menuDidClose and the timer both try to resume it).
    private func resumeCapture() {
        guard capturePending else { return }
        capturePending = false
        menuOpen = false
        capture()
    }

    func menuWillOpen(_ menu: NSMenu) { if menu === self.menu { menuOpen = true } }
    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuOpen = false
        if capturePending { DispatchQueue.main.async { [weak self] in self?.resumeCapture() } } // one turn: the menu window is really gone
    }

    /// Registers Bucket in System Settings > Screen Recording on every capture attempt without permission. No "already asked"
    /// flag: it went stale when the permission was removed (tccutil, or the zip and Homebrew copies, same bundle id, different
    /// signatures) and the app then never re-registered. macOS shows its own prompt only once per app, and the call is
    /// harmless afterwards; it returns at once. Not at launch: a permission dialog before the user did anything is the annoying option.
    private func requestScreenAccess() {
        UserDefaults.standard.removeObject(forKey: "screenAccessRequested") // the flag of earlier builds
        _ = CGRequestScreenCaptureAccess()
    }

    /// Missing permission: the bar says "no" (shake, 160/320), its glyph becomes `bucket.slash` (480/120, opacity .3→1) and the
    /// error pill appears at 480 (ErrorPill.show). Reduce Motion: no shake, the glyph changes by a 160 ms crossfade right away.
    private func permissionDenied() {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let E = Motion.Edges.self
        errorPill.show(at: NSEvent.mouseLocation)
        let layer = item.button?.layer
        if let layer, !reduce {
            let n = E.permissionShakeValues.count
            layer.add(Anim.keyframes("position.x", values: E.permissionShakeValues, times: (0 ..< n).map { Double($0) / Double(n - 1) },
                                     start: E.permissionShake.start, dur: E.permissionShake.dur, base: Anim.now, additive: true), forKey: "no")
        }
        guard !permissionMissing else { return } // already struck through: shake and pill only
        let fade = reduce ? Motion.Reduced.crossfade : Motion.Step(0, E.permissionSlash.dur, E.permissionSlash.curve)
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduce ? 0 : E.permissionSlash.start / 1000)) { [weak self] in
            guard let self else { return }
            self.permissionMissing = true
            self.refreshIcon()
            self.item.button?.layer?.add(Anim.basic("opacity", from: E.permissionSlashFrom, to: 1, fade, base: Anim.now), forKey: "slash")
        }
    }

    private func captured(_ result: CaptureResult, frontApp: String?, frontBundleId: String?) {
        defer { BucketWindows.captureEnded(); panel.captureEnded() }
        switch result {
        case .captured(let tmp):
            do {
                let shot = try library.ingest(captured: tmp, frontApp: frontApp, frontBundleId: frontBundleId)
                let before = bucket.count
                companion.prepare()            // holds the bar icon: the drop has to land first
                bucket.add(shot)
                NSSound(named: "Pop")?.play()
                stageBucket()                  // the circuit that matters does not wait for the animation
                companion.absorbed(before: before, after: bucket.count)
                keycaps.show(.capture, captureSymbols: Shortcut.capture.symbols) // at the end of the capture, never during it
                NSLog("Bucket: \(shot.id) \(shot.width)x\(shot.height) \(shot.bytes / 1024)KB (orig \(shot.originalBytes / 1024)KB) resize \(shot.resizeMs)ms")
            } catch {
                NSLog("Bucket: ingest failed: \(error.localizedDescription)")
                NSSound.beep()
                companion.feedback(CompanionCopy.couldNotSave)
            }
        case .cancelled:
            companion.cancelCapture()
        case .failed(let message):
            NSLog("Bucket: capture failed: \(message)")
            NSSound.beep()
            companion.feedback(CompanionCopy.captureFailed)
        }
    }

    /// Every capture re-stages the whole bucket, so the clipboard is always ready to paste.
    /// The first paste empties the bucket; the next capture starts a new batch.
    private func stageBucket() {
        exporter.stage(bucket.items, mode: pasteMode) { [weak self] in
            guard let self else { return }
            guard self.bucket.count > 0 else { // only ghosts were left: the companion and the icon take the real count
                self.companion.countChanged(0)
                if !self.barHeld { self.refreshIcon() }
                return
            }
            self.companion.prepare()
            let shots = self.bucket.takeBatch()
            guard !shots.isEmpty else { self.companion.abandonPrepared(count: self.bucket.count); return }
            self.exporter.record(shots, via: "paste")
            self.companion.pasted(shots.count)
            self.keycaps.show(.paste, captureSymbols: Shortcut.capture.symbols)
        }
    }

    /// ⌥⇧V and "Copy batch": with load it copies now (the bucket empties, as before); with an empty bucket it re-copies.
    @objc func copyBatch() {
        guard bucket.count > 0 else {
            if !barHeld { refreshIcon() } // a prune may have emptied it: the icon takes the real count
            recopyLastBatch(); return
        }
        companion.prepare()
        let shots = bucket.takeBatch()
        guard !shots.isEmpty else { companion.abandonPrepared(count: bucket.count); return } // only ghosts were in there
        exporter.copy(shots, mode: pasteMode)
        NSSound(named: "Tink")?.play()
        companion.feedback(CompanionCopy.copied(shots.count), count: bucket.count)
    }

    /// The clipboard is armed with the last batch and the bucket is not touched. With load the clipboard
    /// held the bucket's promise: re-copying replaces it, and the next capture re-stages the whole bucket (stageBucket).
    @objc func recopyLastBatch() {
        let last = bucket.lastBatch
        guard !last.isEmpty else { NSSound.beep(); companion.feedback(CompanionCopy.count(0), count: bucket.count); return }
        exporter.copy(last, mode: pasteMode, recopy: true)
        NSSound(named: "Tink")?.play()
        companion.recopied(last.count, bucketCount: bucket.count)
    }

    /// The bucket lost shots without a paste (remove, clear, send): a clipboard promise that is still ours must not
    /// paste what is gone. With load it is re-staged; with none it is cleared. Whatever the user copied since stays.
    private func bucketShrank() {
        if exporter.isStaged { if bucket.count > 0 { stageBucket() } else { exporter.unstage() } }
        companion.countChanged(bucket.count)
    }

    @objc func clearBucket() { bucket.clear(); bucketShrank() }

    /// ⌥⇧X: same as Clear bucket; with nothing in it, a beep (like ⌥⇧V with nothing to copy). The archive keeps every shot.
    private func clearFromShortcut() {
        guard bucket.count > 0 else { NSSound.beep(); return }
        clearBucket()
    }

    func removeShot(id: String) { bucket.remove(id: id); bucketShrank() }

    @objc func removeShot(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { removeShot(id: id) }
    }

    /// The original of the last shot goes to the Desktop and leaves the bucket; the archive keeps it.
    /// With the panel open the confirmation lives in its footer; otherwise the companion says it.
    @objc func sendLastToDesktop() {
        switch DesktopSender.sendLast(of: bucket) {
        case .sent:
            NSSound(named: "Tink")?.play()
            if exporter.isStaged { if bucket.count > 0 { stageBucket() } else { exporter.unstage() } }
            if panel.isOpen { panel.flash(CompanionCopy.sentToDesktop); companion.countChanged(bucket.count) }
            else { companion.feedback(CompanionCopy.sentToDesktop, count: bucket.count) }
        case .empty:
            NSSound.beep()
        case .failed(let message):
            NSLog("Bucket: send to Desktop failed: \(message)")
            NSSound.beep()
            if panel.isOpen { panel.flash(CompanionCopy.couldNotSend) } else { companion.feedback(CompanionCopy.couldNotSend) }
        }
    }

    @objc func toggleKeepInMenuBar() { companion.keepInMenuBar.toggle() }

    @objc func revealShot(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    @objc func setFormat(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let format = PasteFormat(rawValue: raw) {
            PasteFormat.current = format
        }
    }

    /// Off: new captures stay `pending`. On again: whatever piled up while it was off is read now.
    @objc func toggleOCR() {
        let on = !OCRSetting.enabled
        OCRSetting.enabled = on
        library.ocrOnIngest = on
        if on { OCRQueue.shared.backfill(library: library) }
    }

    @objc func openArchive() { NSWorkspace.shared.open(library.root) }

    // MARK: Clicks

    /// Right click and ⌃-click always open the menu; a plain left click goes to `onPrimaryClick`.
    @objc private func statusClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if secondary { showMenu() } else { onPrimaryClick?() }
    }

    private func showMenu() {
        item.menu = menu
        item.button?.performClick(nil) // blocks while the menu is tracking
        item.menu = nil
    }

    // MARK: Menu

    /// Shared with the offscreen renderer so `render menubar-N` shows exactly what the bar shows.
    static func icon(count n: Int) -> NSImage { Glyph.barImage(GlyphState(count: n)) }

    private func refreshIcon() {
        guard let button = item.button else { return }
        button.image = permissionMissing ? Glyph.barImage(.slash) : StatusController.icon(count: bucket.count)
        button.imagePosition = .imageOnly
        button.title = ""
    }

    /// The template glyph scales 1→1.25→1 (springSoft, 260 ms) about its center.
    private func bounceBar() {
        guard let button = item.button, let layer = button.layer else { return }
        let b = button.bounds, a = layer.anchorPoint
        let cx = b.midX - a.x * b.width, cy = b.midY - a.y * b.height // pivot relative to the layer's own anchor
        let peak = Motion.Absorb.barBounceScale - 1
        layer.add(Anim.sampled("transform", Motion.Absorb.barBounce, base: Anim.now, backwards: false) { u in
            let s = 1 + peak * Anim.lerp([(0, 0), (0.5, 1), (1, 0)], u)
            var t = CATransform3DMakeTranslation(CGFloat((1 - s) * cx), CGFloat((1 - s) * cy), 0)
            t = CATransform3DScale(t, CGFloat(s), CGFloat(s), 1)
            return NSValue(caTransform3D: t)
        }, forKey: "bounce")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let n = bucket.count

        let sc = Shortcut.capture
        let cap = entry("Capture", #selector(capture))
        cap.keyEquivalent = sc.menuKey
        cap.keyEquivalentModifierMask = sc.menuMask
        menu.addItem(cap)
        if captureShortcutTaken {
            let taken = NSMenuItem(title: "\(Shortcut.capture.symbols.joined()) is taken by another app", action: nil, keyEquivalent: "")
            taken.isEnabled = false
            menu.addItem(taken)
        }
        if nativeScreenshotConflict {
            let native = NSMenuItem(title: "⌘⇧4 is also on in macOS (Keyboard Shortcuts › Screenshots)", action: nil, keyEquivalent: "")
            native.isEnabled = false
            menu.addItem(native)
        }
        // ⌥⇧V does one of two things (copyBatch): the menu shows it next to the one it would do right now.
        let copy = entry(n > 0 ? "Copy batch (\(n))" : "Copy batch", #selector(copyBatch), key: n > 0 ? "v" : "")
        copy.isEnabled = n > 0
        menu.addItem(copy)
        let last = bucket.lastBatch
        let recopy = entry(last.isEmpty ? "Re-copy last batch" : "Re-copy last batch (\(last.count))", #selector(recopyLastBatch), key: n == 0 && !last.isEmpty ? "v" : "")
        recopy.isEnabled = !last.isEmpty
        menu.addItem(recopy)
        if recopyShortcutTaken {
            let taken = NSMenuItem(title: "⌥⇧V is taken by another app", action: nil, keyEquivalent: "")
            taken.isEnabled = false
            menu.addItem(taken)
        }
        let send = entry("Send last to Desktop", #selector(sendLastToDesktop))
        send.isEnabled = n > 0
        menu.addItem(send)

        if n > 0 {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "In bucket"))
            for (i, shot) in bucket.items.enumerated() {
                let time = Library.timeLabel(of: shot.id) ?? shot.id
                let row = NSMenuItem(title: "\(i + 1). \(time) · \(shot.frontApp ?? "—")", action: nil, keyEquivalent: "")
                row.image = thumbnail(shot.path)
                let sub = NSMenu()
                let reveal = entry("Show in Finder", #selector(revealShot(_:)))
                reveal.representedObject = shot.path
                let remove = entry("Remove from bucket", #selector(removeShot(_:)))
                remove.representedObject = shot.id
                sub.addItem(reveal)
                sub.addItem(remove)
                row.submenu = sub
                menu.addItem(row)
            }
            menu.addItem(entry("Clear bucket", #selector(clearBucket), key: "x"))
        }
        if clearShortcutTaken {
            let taken = NSMenuItem(title: "⌥⇧X is taken by another app", action: nil, keyEquivalent: "")
            taken.isEnabled = false
            menu.addItem(taken)
        }

        menu.addItem(.separator())
        let formatItem = NSMenuItem(title: "Paste format", action: nil, keyEquivalent: "")
        let formats = NSMenu()
        for format in PasteFormat.allCases {
            let f = entry(format.title, #selector(setFormat(_:)))
            f.representedObject = format.rawValue
            f.state = format == PasteFormat.current ? .on : .off
            formats.addItem(f)
        }
        formatItem.submenu = formats
        menu.addItem(formatItem)
        let shortcutItem = NSMenuItem(title: "Capture shortcut", action: nil, keyEquivalent: "")
        let shortcuts = NSMenu()
        for preset in Shortcut.presets {
            let s = entry(preset.title, #selector(setCaptureShortcut(_:)))
            s.representedObject = preset.id
            s.state = preset == Shortcut.capture ? .on : .off
            shortcuts.addItem(s)
        }
        shortcutItem.submenu = shortcuts
        menu.addItem(shortcutItem)
        let ocr = entry("Read text in screenshots", #selector(toggleOCR))
        markToggle(ocr, on: OCRSetting.enabled)
        menu.addItem(ocr)
        // Shown as the positive: on = the companion follows the cursor (the stored preference is still keepInMenuBar, inverted).
        let keep = entry("Follow the cursor", #selector(toggleKeepInMenuBar))
        markToggle(keep, on: !companion.keepInMenuBar)
        menu.addItem(keep)
        menu.addItem(entry("Open archive", #selector(openArchive)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Bucket", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// On/off items only: the native checkmark shows nothing when off, so the item does not look clickable.
    /// Radio groups (Paste format, Capture shortcut) keep the normal checkmark.
    private func markToggle(_ item: NSMenuItem, on: Bool) {
        func symbol(_ name: String) -> NSImage? {
            let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            img?.isTemplate = true
            return img
        }
        item.onStateImage = symbol("checkmark.square")
        item.offStateImage = symbol("square")
        item.state = on ? .on : .off
    }

    private func entry(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if !key.isEmpty { item.keyEquivalentModifierMask = [.option, .shift] }
        return item
    }

    private func thumbnail(_ path: String) -> NSImage? {
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        let side: CGFloat = 32
        let ratio = image.size.width / max(image.size.height, 1)
        image.size = ratio >= 1 ? NSSize(width: side, height: side / ratio) : NSSize(width: side * ratio, height: side)
        return image
    }
}
