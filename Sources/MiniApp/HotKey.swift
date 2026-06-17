import AppKit
import Carbon.HIToolbox

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
