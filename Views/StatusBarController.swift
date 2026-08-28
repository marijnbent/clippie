import Cocoa

/// Manages the menu bar status item and its context menu.
class StatusBarController {
    private var statusItem: NSStatusItem
    private let onShowSettings: () -> Void
    
    init(
        onShowSettings: @escaping () -> Void
    ) {
        self.onShowSettings = onShowSettings
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        setupButton()
    }
    
    private func setupButton() {
        guard let button = statusItem.button else { return }
        
        // Use SF Symbol for clipboard
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "clippie")
        image?.isTemplate = true
        button.image = image?.withSymbolConfiguration(config)
        
        // Open the context menu for both primary and secondary clicks.
        button.action = #selector(handleClick)
        button.target = self
        
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    
    @objc private func handleClick(_ sender: NSStatusBarButton) {
        showContextMenu()
    }
    
    
    private func showContextMenu() {
        let menu = NSMenu()
        
        // Show current shortcut
        let settings = SettingsManager.shared
        let shortcutDisplay = "\(settings.hotkeyModifiers.displayString)\(keyCodeNames[settings.hotkeyKeyCode] ?? "?")"
        let shortcutItem = NSMenuItem(title: "Shortcut: \(shortcutDisplay)", action: nil, keyEquivalent: "")
        shortcutItem.isEnabled = false
        menu.addItem(shortcutItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let diagnosticsItem = NSMenuItem(
            title: "Reveal Diagnostics Log",
            action: #selector(revealDiagnosticsLog),
            keyEquivalent: ""
        )
        diagnosticsItem.target = self
        diagnosticsItem.isEnabled = settings.diagnosticsEnabled
        menu.addItem(diagnosticsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit
        let quitItem = NSMenuItem(title: "Quit clippie", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // Reset so left click works
    }
    
    @objc private func showSettings() {
        onShowSettings()
    }

    @objc private func revealDiagnosticsLog() {
        let diagnostics = DiagnosticsLog.shared
        diagnostics.ensureFileExists()
        diagnostics.event("diagnosticsLog.revealed")
        NSWorkspace.shared.activateFileViewerSelecting([diagnostics.fileURL])
    }
    
    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
