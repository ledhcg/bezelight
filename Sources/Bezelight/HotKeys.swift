import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts (Control-Option-Shift + key) that work while another app is frontmost.
/// Carbon's hot-key API needs no extra permission, unlike listening for key events.
final class HotKeys: @unchecked Sendable {
    enum Action: UInt32, CaseIterable {
        case toggle = 1, on, off, brightnessUp, brightnessDown, dismissAlerts

        var keyCode: Int {
            switch self {
            case .toggle: return kVK_F8
            case .on: return kVK_F9
            case .off: return kVK_F10
            case .brightnessUp: return kVK_UpArrow
            case .brightnessDown: return kVK_DownArrow
            case .dismissAlerts: return kVK_F11
            }
        }
    }

    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    /// Always invoked on the main queue.
    var onAction: ((Action) -> Void)?

    var isRegistered: Bool { !refs.isEmpty }

    func register() {
        guard !isRegistered else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let me = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            if let action = Action(rawValue: id.id) {
                DispatchQueue.main.async { me.onAction?(action) }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)

        let modifiers = UInt32(controlKey | optionKey | shiftKey)
        for action in Action.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x425A4C54) /* 'BZLT' */, id: action.rawValue)
            if RegisterEventHotKey(UInt32(action.keyCode), modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr {
                refs.append(ref)
            }
        }
    }

    func unregister() {
        refs.forEach { if let r = $0 { UnregisterEventHotKey(r) } }
        refs.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    deinit { unregister() }
}
