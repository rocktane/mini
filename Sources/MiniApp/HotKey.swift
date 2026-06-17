import AppKit
import Carbon.HIToolbox

extension Notification.Name {
    /// Posted when the user changes the global toggle shortcut in Settings.
    static let miniHotKeyChanged = Notification.Name("MiniHotKeyChanged")
}

/// The persisted global toggle shortcut: a key code, Carbon modifier mask, and display string.
struct HotKeyConfig: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String

    // ⌃⌥⌘M: ⌃⌥ alone collides with Rectangle's window-tiling shortcuts and ⌘⌥ with macOS
    // (minimize-all / hide-others); adding all three avoids both.
    static let `default` = HotKeyConfig(keyCode: UInt32(kVK_ANSI_M),
                                        carbonModifiers: UInt32(controlKey | optionKey | cmdKey),
                                        display: "⌃⌥⌘M")

    static func load() -> HotKeyConfig {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "hotKeyKeyCode") != nil else { return .default }
        return HotKeyConfig(keyCode: UInt32(defaults.integer(forKey: "hotKeyKeyCode")),
                            carbonModifiers: UInt32(defaults.integer(forKey: "hotKeyModifiers")),
                            display: defaults.string(forKey: "hotKeyDisplay") ?? HotKeyConfig.default.display)
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(Int(keyCode), forKey: "hotKeyKeyCode")
        defaults.set(Int(carbonModifiers), forKey: "hotKeyModifiers")
        defaults.set(display, forKey: "hotKeyDisplay")
    }

    /// Builds a config from a captured key-down event, or nil if it lacks a usable modifier.
    static func from(event: NSEvent) -> HotKeyConfig? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control) || flags.contains(.option) || flags.contains(.command) else { return nil }

        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }

        var symbols = ""
        if flags.contains(.control) { symbols += "⌃" }
        if flags.contains(.option) { symbols += "⌥" }
        if flags.contains(.shift) { symbols += "⇧" }
        if flags.contains(.command) { symbols += "⌘" }

        return HotKeyConfig(keyCode: UInt32(event.keyCode),
                            carbonModifiers: carbon,
                            display: symbols + keyName(for: event))
    }

    private static func keyName(for event: NSEvent) -> String {
        let specials: [UInt16: String] = [
            49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        if let name = specials[event.keyCode] { return name }
        if let chars = event.charactersIgnoringModifiers, let first = chars.first,
           first.isLetter || first.isNumber || first.isPunctuation {
            return chars.uppercased()
        }
        return "Key\(event.keyCode)"
    }
}

/// A single system-wide hot key registered through Carbon (no Accessibility permission needed).
/// Carbon delivers the event on the main thread, so the action hops back onto the main actor.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let id: UInt32

    fileprivate let action: () -> Void
    fileprivate static var instances: [UInt32: GlobalHotKey] = [:]

    init?(id: UInt32 = 1, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.id = id
        self.action = action
        GlobalHotKey.instances[id] = self

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D494E49), id: id) // 'MINI'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            GlobalHotKey.instances[id] = nil
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        GlobalHotKey.instances[id] = nil
    }
}

/// Top-level C callback (EventHandlerUPP can't capture context), routes to the matching instance.
private func hotKeyEventHandler(_ next: EventHandlerCallRef?,
                                _ event: EventRef?,
                                _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                      nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    GlobalHotKey.instances[hotKeyID.id]?.action()
    return noErr
}
