import AppKit
import Carbon

/// Global hotkeys via Carbon. Does not require the Accessibility permission.
public enum Hotkeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var refs: [UInt32: EventHotKeyRef] = [:]
    private static var combos: [UInt32: Combo] = [:]
    private static var installed = false

    private struct Combo: Equatable { let keyCode: Int, modifiers: Int }

    /// Registers `id` on a key combination. All or nothing: the new combination is taken FIRST, and only once it is
    /// ours is the one `id` held before released. If it fails, `id` keeps what it had (and its handler).
    @discardableResult
    public static func register(id: UInt32, keyCode: Int, modifiers: Int, handler: @escaping () -> Void) -> Bool {
        installIfNeeded()
        let combo = Combo(keyCode: keyCode, modifiers: modifiers)
        if combos[id] == combo { handlers[id] = handler; return true } // already ours: asking Carbon again would say "taken"
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x424B_5454), id: id) // 'BKTT'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("Bucket: could not register hotkey \(id) (status \(status))")
            return false
        }
        unregister(id: id)
        handlers[id] = handler
        refs[id] = ref
        combos[id] = combo
        return true
    }

    public static func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        combos.removeValue(forKey: id)
        handlers.removeValue(forKey: id)
    }

    /// What `id` holds right now (nil = nothing).
    public static func registered(id: UInt32) -> (keyCode: Int, modifiers: Int)? {
        combos[id].map { ($0.keyCode, $0.modifiers) }
    }

    private static func installIfNeeded() {
        guard !installed else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            Hotkeys.handlers[hotKeyID.id]?()
            return noErr
        }, 1, &spec, nil, nil)
        if status == noErr { installed = true } else { NSLog("Bucket: could not install the hotkey handler (status \(status))") }
    }
}

/// Switching the user's shortcut: the wanted one is registered first and only becomes the preference if that worked.
/// Otherwise the current one stays (and stays registered: `register` is all or nothing).
public enum ShortcutSwitch {
    public static func apply<S>(wanted: S, current: S, register: (S) -> Bool, save: (S) -> Void) -> (active: S, switched: Bool) {
        guard register(wanted) else { return (current, false) }
        save(wanted)
        return (wanted, true)
    }
}
