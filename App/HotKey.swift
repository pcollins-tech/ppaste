import Carbon.HIToolbox
import AppKit

/// Global hotkey via Carbon; needs no extra permissions.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static var nextID: UInt32 = 1
    private let id: UInt32

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) {
        self.action = action
        self.id = HotKey.nextID; HotKey.nextID += 1
        var carbonMods: UInt32 = 0
        if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
        if modifiers.contains(.shift) { carbonMods |= UInt32(shiftKey) }
        if modifiers.contains(.option) { carbonMods |= UInt32(optionKey) }
        if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let hk = Unmanaged<HotKey>.fromOpaque(userData!).takeUnretainedValue()
            guard hkID.id == hk.id else { return OSStatus(eventNotHandledErr) }
            hk.action()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let status = RegisterEventHotKey(keyCode, carbonMods, EventHotKeyID(signature: OSType(0x70707374), id: id),
                            GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
