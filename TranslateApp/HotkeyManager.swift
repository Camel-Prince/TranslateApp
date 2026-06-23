import Cocoa
import Carbon

class HotkeyManager {
    private var handler: () -> Void
    private var eventHotKey: EventHotKeyRef?
    
    // Store reference for the C callback
    private static var instance: HotkeyManager?
    
    init(handler: @escaping () -> Void) {
        self.handler = handler
        HotkeyManager.instance = self
    }
    
    func register() {
        // Register Option+D hotkey using Carbon API
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x5452_4E53) // "TRNS"
        hotKeyID.id = 1
        
        // Option key = optionKey (0x0800), D key = kVK_ANSI_D (0x02)
        let modifiers: UInt32 = UInt32(optionKey)
        let keyCode: UInt32 = UInt32(kVK_ANSI_D)
        
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                       eventKind: UInt32(kEventHotKeyPressed))
        
        // Install event handler
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            HotkeyManager.instance?.handler()
            return noErr
        }, 1, &eventType, nil, nil)
        
        // Register the hotkey
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                          GetApplicationEventTarget(), 0, &eventHotKey)
        
        if status != noErr {
            print("[HotkeyManager] Failed to register hotkey: \(status)")
            // Fallback: use NSEvent global monitor
            registerFallback()
        } else {
            print("[HotkeyManager] Hotkey Option+D registered successfully")
        }
    }
    
    private func registerFallback() {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Option+D: modifiers contains .option, keyCode for 'D' is 2
            if event.modifierFlags.contains(.option) && event.keyCode == 2 {
                self?.handler()
            }
        }
        print("[HotkeyManager] Using fallback global monitor for Option+D")
    }
    
    func unregister() {
        if let hotKey = eventHotKey {
            UnregisterEventHotKey(hotKey)
            eventHotKey = nil
        }
    }
    
    deinit {
        unregister()
    }
}
