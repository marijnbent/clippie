import Cocoa

/// Handles pasting content into the frontmost application
class PasteController {
    private static let pasteDelay: TimeInterval = 0.12

    @discardableResult
    static func copyTextToClipboard(_ text: String) -> Bool {
        writeToPasteboard { pasteboard in
            pasteboard.setString(text, forType: .string)
        }
    }
    
    /// Copy item content back to system clipboard
    @discardableResult
    static func copyToClipboard(_ item: ClipboardItem, store: ClipboardStore) -> Bool {
        switch item.type {
        case .text:
            guard let text = store.fullText(for: item) else { return false }
            return writeToPasteboard { pasteboard in
                pasteboard.setString(text, forType: .string)
            }
        case .image:
            guard let image = store.image(for: item),
                  let tiffData = image.tiffRepresentation else {
                return false
            }
            return writeToPasteboard { pasteboard in
                pasteboard.setData(tiffData, forType: .tiff)
            }
        }
    }
    
    /// Paste item into the frontmost application
    @discardableResult
    static func paste(
        _ item: ClipboardItem,
        store: ClipboardStore,
        targetApplication: NSRunningApplication? = nil
    ) -> Bool {
        guard copyToClipboard(item, store: store) else { return false }

        prepareAndSimulatePaste(into: targetApplication)
        return true
    }
    
    @discardableResult
    static func paste(text: String, targetApplication: NSRunningApplication? = nil) -> Bool {
        guard copyTextToClipboard(text) else { return false }

        prepareAndSimulatePaste(into: targetApplication)
        return true
    }

    /// Record only the exact change count from a completed Clippie pasteboard write.
    private static func writeToPasteboard(_ write: (NSPasteboard) -> Bool) -> Bool {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.clearContents()
        guard write(pasteboard), pasteboard.changeCount == changeCount else { return false }

        NotificationCenter.default.post(
            name: .bufferDidWritePasteboard,
            object: NSNumber(value: changeCount)
        )
        return true
    }

    private static func prepareAndSimulatePaste(into targetApplication: NSRunningApplication?) {
        if let targetApplication,
           !targetApplication.isTerminated,
           targetApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            targetApplication.activate(options: [.activateIgnoringOtherApps])
        }

        // Give the pasteboard and target app a brief moment to settle before posting Cmd+V.
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay) {
            simulatePaste()
        }
    }
    
    /// Simulate Command + V keystroke
    private static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        
        // Key code for 'V' is 9
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        
        // Add Command modifier
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        
        // Post the events
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
