import Cocoa

enum ClipboardContentError: LocalizedError {
    case unavailable
    var errorDescription: String? { "The saved clipboard content could not be loaded." }
}

enum PreparedClipboardContent: Sendable, Equatable {
    case text(String)
    case image(png: Data, tiff: Data)
}

@MainActor
class PasteController {
    private static let pasteDelay: TimeInterval = 0.12

    @discardableResult
    static func copyTextToClipboard(_ text: String) -> Bool {
        writeToPasteboard { pasteboard in
            pasteboard.setString(text, forType: .string)
        }
    }
    
    @discardableResult
    static func copyToClipboard(_ content: PreparedClipboardContent) -> Bool {
        writeToPasteboard { pasteboard in
            switch content {
            case .text(let text):
                return pasteboard.setString(text, forType: .string)
            case .image(let png, let tiff):
                let item = NSPasteboardItem()
                guard item.setData(png, forType: .png), item.setData(tiff, forType: .tiff) else { return false }
                return pasteboard.writeObjects([item])
            }
        }
    }

    @discardableResult
    static func paste(_ content: PreparedClipboardContent, targetApplication: NSRunningApplication?) async -> Bool {
        guard !Task.isCancelled else { return false }
        if let targetApplication, targetApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            guard !targetApplication.isTerminated else { return false }
            let activePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard activePID == targetApplication.processIdentifier || activePID == ProcessInfo.processInfo.processIdentifier else { return false }
        }
        guard copyToClipboard(content) else { return false }
        _ = await prepareAndSimulatePaste(into: targetApplication)
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

    private static func prepareAndSimulatePaste(into targetApplication: NSRunningApplication?) async -> Bool {
        guard let targetApplication,
              !targetApplication.isTerminated,
              targetApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        targetApplication.activate(options: [.activateIgnoringOtherApps])
        do {
            try await Task.sleep(nanoseconds: UInt64(pasteDelay * 1_000_000_000))
            try Task.checkCancellation()
        } catch {
            return false
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApplication.processIdentifier else { return false }
        simulatePaste()
        return true
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
