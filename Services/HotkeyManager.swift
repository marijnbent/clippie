import Cocoa
import Carbon
import ApplicationServices

/// Manages global keyboard shortcut registration using Carbon API
class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var registeredKeyCode: UInt16 = SettingsManager.defaultHotkeyKeyCode
    private var registeredModifiers = SettingsManager.defaultHotkeyModifiers
    private let callback: () -> Void
    
    // Store the singleton for the C callback
    private static var instance: HotkeyManager?
    private static var eventHandlerInstalled = false
    
    init(callback: @escaping () -> Void) {
        self.callback = callback
        HotkeyManager.instance = self
    }
    
    func register() {
        let settings = SettingsManager.shared
        registeredKeyCode = settings.hotkeyKeyCode
        registeredModifiers = settings.hotkeyModifiers
        print("[HotkeyManager] Registering: keyCode=\(settings.hotkeyKeyCode) mods=\(settings.hotkeyModifiers.displayString)")
        
        unregister()
        
        if !HotkeyManager.eventHandlerInstalled {
            // Install event handler
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { (nextHandler, theEvent, userData) -> OSStatus in
                    var hotKeyID = EventHotKeyID()
                    GetEventParameter(
                        theEvent,
                        EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        &hotKeyID
                    )
                    
                    if hotKeyID.id == 1 {
                        print("[HotkeyManager] Carbon hotkey detected!")
                        DispatchQueue.main.async {
                            HotkeyManager.instance?.callback()
                        }
                    }
                    
                    return noErr
                },
                1,
                &eventType,
                nil,
                nil
            )
            
            if status != noErr {
                print("[HotkeyManager] ❌ Failed to install event handler: \(status)")
            } else {
                HotkeyManager.eventHandlerInstalled = true
            }
        }
        
        // Register the hotkey
        let requiredKeyCode = UInt32(registeredKeyCode)
        let mods = registeredModifiers
        var modifiers: UInt32 = 0
        if mods.shift { modifiers |= UInt32(shiftKey) }
        if mods.command { modifiers |= UInt32(cmdKey) }
        if mods.option { modifiers |= UInt32(optionKey) }
        if mods.control { modifiers |= UInt32(controlKey) }
        
        let hotKeyID = EventHotKeyID(signature: OSType(0x4255_4646), id: 1) // "BUFF"
        
        let registerStatus = RegisterEventHotKey(
            requiredKeyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            UInt32(kEventHotKeyExclusive),
            &hotKeyRef
        )
        
        if registerStatus == noErr {
            print("[HotkeyManager] ✅ Carbon hotkey registered: keyCode=\(requiredKeyCode)")
        } else {
            print("[HotkeyManager] ❌ Failed to register hotkey: \(registerStatus)")
        }

        startEventTap()
    }
    
    func reregister() {
        register()
    }
    
    func unregister() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
            print("[HotkeyManager] Hotkey unregistered")
        }

        stopEventTap()
    }

    private func startEventTap() {
        stopEventTap()

        let hasListenAccess = CGPreflightListenEventAccess()
        print("[HotkeyManager] Input Monitoring access: \(hasListenAccess)")
        if !hasListenAccess {
            let granted = CGRequestListenEventAccess()
            print("[HotkeyManager] Input Monitoring request result: \(granted)")
        }

        let eventMask = (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }

                let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                return manager.handleEventTap(type: type, event: event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            print("[HotkeyManager] ❌ Failed to create hotkey event tap")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source

        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    private func handleEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown, matchesRegisteredHotkey(event) else {
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            print("[HotkeyManager] Event tap hotkey detected!")
            DispatchQueue.main.async { [callback] in
                callback()
            }
        }

        return nil
    }

    private func matchesRegisteredHotkey(_ event: CGEvent) -> Bool {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == registeredKeyCode else { return false }

        let flags = event.flags
        let modifiers = HotkeyModifiers(
            shift: flags.contains(.maskShift),
            command: flags.contains(.maskCommand),
            option: flags.contains(.maskAlternate),
            control: flags.contains(.maskControl)
        )

        return modifiers == registeredModifiers
    }
    
    deinit {
        unregister()
        HotkeyManager.instance = nil
    }
}
