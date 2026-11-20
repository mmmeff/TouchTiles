import AppKit
import Carbon

enum WindowAction: UInt32, CaseIterable, Identifiable {
    case float = 1
    case fullscreen = 2

    var id: Self { self }

    var title: String {
        switch self {
        case .float: return "Float or tile window"
        case .fullscreen: return "Expand or restore window"
        }
    }

    var defaultBinding: KeyBinding {
        let key = self == .float ? kVK_ANSI_T : kVK_ANSI_F
        return KeyBinding(code: UInt32(key), modifiers: UInt32(optionKey),
                          label: self == .float ? "T" : "F")
    }
}

struct KeyBinding: Codable, Equatable {
    let code: UInt32
    let modifiers: UInt32
    let label: String

    var display: String {
        var keys = ""
        for (mask, symbol) in [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")] {
            if modifiers & UInt32(mask) != 0 { keys += symbol }
        }
        return keys + label
    }

    init(code: UInt32, modifiers: UInt32, label: String) {
        self.code = code
        self.modifiers = modifiers
        self.label = label
    }

    init(recording event: NSEvent) throws {
        var mask: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        guard mask == UInt32(optionKey) || mask.nonzeroBitCount >= 2 else {
            throw ShortcutError.message("Hold Option, or hold two or more modifiers, while pressing a key.")
        }
        // Control-Command-F belongs to the frontmost app, outside the system hotkey registry.
        guard !(event.keyCode == kVK_ANSI_F && mask == UInt32(controlKey | cmdKey)) else {
            throw ShortcutError.message("macOS apps use this shortcut for full screen. Choose another combination.")
        }
        let special: [Int: String] = [kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑",
            kVK_DownArrow: "↓", kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab",
            kVK_Delete: "Delete", kVK_ForwardDelete: "⌦", kVK_Home: "Home", kVK_End: "End",
            kVK_PageUp: "PgUp", kVK_PageDown: "PgDn"]
        let key = special[Int(event.keyCode)] ?? event.characters(byApplyingModifiers: [])?.uppercased()
        guard let key, !key.isEmpty, key.unicodeScalars.allSatisfy({ !$0.properties.isDefaultIgnorableCodePoint && $0.value < 0xf700 }) else {
            throw ShortcutError.message("Choose a letter, number, arrow, or navigation key.")
        }
        self.init(code: UInt32(event.keyCode), modifiers: mask, label: key)
    }

    func matches(_ other: KeyBinding) -> Bool {
        code == other.code && modifiers == other.modifiers
    }

    func checkSystemShortcut() throws {
        var keys: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&keys) == noErr, let keys else { return }
        let records = keys.takeRetainedValue() as NSArray
        for case let item as NSDictionary in records {
            guard (item["kHISymbolicHotKeyEnabled"] as? NSNumber)?.boolValue == true,
                  (item["kHISymbolicHotKeyCode"] as? NSNumber)?.uint32Value == code,
                  (item["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value == modifiers else { continue }
            throw ShortcutError.message("\(display) is assigned in System Settings. Choose another shortcut.")
        }
    }
}

enum ShortcutError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

final class Shortcuts {
    var onPress: ((WindowAction) -> Void)?
    private var handler: EventHandlerRef?
    private var registered: [WindowAction: EventHotKeyRef] = [:]
    private static let signature: OSType = 0x44524654 // DRFT

    private func installHandler() throws {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == Shortcuts.signature,
                  let action = WindowAction(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            Unmanaged<Shortcuts>.fromOpaque(context).takeUnretainedValue().onPress?(action)
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr { throw ShortcutError.message("Couldn’t install the shortcut handler (\(status)).") }
    }

    func register(_ binding: KeyBinding, for action: WindowAction) throws {
        try binding.checkSystemShortcut()
        try installHandler()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(binding.code, binding.modifiers, id, GetApplicationEventTarget(),
                                         UInt32(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else {
            throw ShortcutError.message("macOS couldn’t reserve \(binding.display) (\(status)). Choose another shortcut.")
        }
        if let previous = registered.updateValue(ref, forKey: action) { UnregisterEventHotKey(previous) }
    }

    func stop() {
        for ref in registered.values { UnregisterEventHotKey(ref) }
        registered.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
