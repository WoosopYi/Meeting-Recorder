import Carbon.HIToolbox
import Foundation

final class HotKeyManager {
    enum HotKeyError: Swift.Error {
        case eventHandlerInstallFailed(OSStatus)
        case hotKeyRegisterFailed(OSStatus)
        case invalidHotKeyRef
    }

    // 'MVHK'
    private let signature = OSType(0x4D56_484B)

    private var eventHandlerRef: EventHandlerRef?
    private var registrations: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]

    func registerToggleRecording(handler: @escaping () -> Void) throws {
        // Default: Shift + Command + R
        let modifiers = UInt32(cmdKey | shiftKey)
        try register(id: 1, keyCode: UInt32(kVK_ANSI_R), modifiers: modifiers, handler: handler)
    }

    private func installIfNeeded() throws {
        guard eventHandlerRef == nil else { return }

        let handlerUPP: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else {
                return OSStatus(eventNotHandledErr)
            }

            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            return manager.handle(event: event)
        }

        let eventTypes: [EventTypeSpec] = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
        ]

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            handlerUPP,
            eventTypes.count,
            eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        guard status == noErr else {
            throw HotKeyError.eventHandlerInstallFailed(status)
        }
    }

    private func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) throws {
        try installIfNeeded()

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr else {
            throw HotKeyError.hotKeyRegisterFailed(status)
        }

        guard let hotKeyRef else {
            throw HotKeyError.invalidHotKeyRef
        }

        hotKeyRefs[id] = hotKeyRef
        registrations[id] = handler
    }

    private func handle(event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else { return status }
        guard hotKeyID.signature == signature else { return OSStatus(eventNotHandledErr) }

        registrations[hotKeyID.id]?()
        return noErr
    }
}
