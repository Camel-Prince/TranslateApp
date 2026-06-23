import Cocoa

class TextGrabber {
    /// Grab selected text by simulating Cmd+C
    static func grabSelectedText(completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        
        // Save current clipboard content
        let savedChangeCount = pasteboard.changeCount
        let savedItems = pasteboard.pasteboardItems?.compactMap { item -> [String: Data]? in
            var dict = [String: Data]()
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type.rawValue] = data
                }
            }
            return dict.isEmpty ? nil : dict
        }
        
        // Simulate Cmd+C
        simulateCopy()
        
        // Wait for clipboard to update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Check if clipboard changed
            if pasteboard.changeCount == savedChangeCount {
                // No change — nothing was selected
                completion(nil)
                return
            }
            
            // Read new text
            let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Restore original clipboard
            pasteboard.clearContents()
            if let items = savedItems {
                for itemDict in items {
                    let pbItem = NSPasteboardItem()
                    for (typeStr, data) in itemDict {
                        pbItem.setData(data, forType: NSPasteboard.PasteboardType(typeStr))
                    }
                    pasteboard.writeObjects([pbItem])
                }
            }
            
            completion(text)
        }
    }
    
    private static func simulateCopy() {
        let source = CGEventSource(stateID: .hidSystemState)
        
        // Key down: Cmd+C
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true) // 'c' key
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        
        // Key up: Cmd+C
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
