import Cocoa
import Carbon.HIToolbox

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var clipboardWatcher: ClipboardWatcher?
    private var historyWindowController: HistoryWindowController?
    private var hotkeyManager: HotkeyManager?
    private var snippetExpansionController: SnippetExpansionController?
    let clipboardStore = ClipboardStore()
    private lazy var settingsWindowController = SettingsWindowController(store: clipboardStore)
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon - we're menu bar only
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = AppMenuBuilder.build()
        
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "hasLaunchedBefore") {
            // Give it a tiny delay to ensure everything is loaded before registering SMAppService
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                SettingsManager.shared.toggleLaunchAtLogin(true)
                defaults.set(true, forKey: "hasLaunchedBefore")
            }
        }
        
        // Initialize clipboard watcher
        clipboardWatcher = ClipboardWatcher(store: clipboardStore)
        clipboardWatcher?.startWatching()
        
        // Initialize status bar
        statusBarController = StatusBarController(
            onShowSettings: { [weak self] in
                self?.showSettingsWindow()
            }
        )
        
        // Initialize history window controller
        historyWindowController = HistoryWindowController(store: clipboardStore)

        snippetExpansionController = SnippetExpansionController(store: .shared)
        snippetExpansionController?.start()
        
        // Setup global hotkey (Option + /)
        hotkeyManager = HotkeyManager { [weak self] in
            self?.toggleHistoryWindow()
        }
        hotkeyManager?.register()
        
        NotificationCenter.default.addObserver(forName: .bufferHotkeyChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.hotkeyManager?.reregister()
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        clipboardWatcher?.stopWatching()
        clipboardWatcher?.finishPendingProcessing()
        clipboardStore.flushPendingHistorySave()
        hotkeyManager?.unregister()
        snippetExpansionController?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow()
        return true
    }
    
    private func toggleHistoryWindow() {
        print("[AppDelegate] toggleHistoryWindow called")
        if let window = historyWindowController?.window, window.isVisible {
            print("[AppDelegate] Window is visible, closing...")
            historyWindowController?.close()
        } else {
            print("[AppDelegate] Window is hidden, showing...")
            showHistoryWindow()
        }
    }
    
    private func showHistoryWindow() {
        historyWindowController?.showWindow(nil)
    }

    private func showSettingsWindow() {
        settingsWindowController.showWindowAndActivate()
    }
}
