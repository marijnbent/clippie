import AppKit
import Combine
import SwiftUI

enum ClippieSettingsWindowMetrics {
    static let width: CGFloat = 480
    static let height: CGFloat = 660
    static let contentSize = NSSize(width: width, height: height)
}

enum ClippieSettingsTab: String, CaseIterable {
    case general
    case about

    var toolbarIdentifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier(rawValue)
    }

    var label: String {
        switch self {
        case .general: "General"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .about: "info.circle"
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let mainViewModel = ClippieSettingsMainViewModel()
    private var tabSubscription: AnyCancellable?

    init(store: ClipboardStore) {
        let rootView = ClippieSettingsRootView(mainViewModel: mainViewModel, store: store)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: ClippieSettingsWindowMetrics.width, height: ClippieSettingsWindowMetrics.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clippie"
        window.contentViewController = hostingController
        window.setContentSize(ClippieSettingsWindowMetrics.contentSize)
        window.contentMinSize = ClippieSettingsWindowMetrics.contentSize
        Self.positionWindow(window)
        window.isReleasedWhenClosed = false
        window.delegate = nil

        super.init(window: window)

        window.delegate = self

        let toolbar = NSToolbar(identifier: "ClippieSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.selectedItemIdentifier = mainViewModel.selectedTab.toolbarIdentifier
        window.toolbar = toolbar
        window.toolbarStyle = .preference

        tabSubscription = mainViewModel.$selectedTab.sink { [weak toolbar] tab in
            toolbar?.selectedItemIdentifier = tab.toolbarIdentifier
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWindowAndActivate() {
        updateActivationPolicy(forSettingsWindowIsOpen: true)
        let shouldPositionWindow = window?.isVisible != true
        showWindow(nil)
        if shouldPositionWindow, let window {
            Self.positionWindow(window)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        updateActivationPolicy(forSettingsWindowIsOpen: false)
    }

    private func updateActivationPolicy(forSettingsWindowIsOpen isOpen: Bool) {
        let policy: NSApplication.ActivationPolicy = isOpen ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else {
            return
        }

        NSApp.setActivationPolicy(policy)
    }

    private static func positionWindow(_ window: NSWindow) {
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let originX = visibleFrame.midX - (window.frame.width / 2)
        let originY = visibleFrame.maxY - window.frame.height - 80
        window.setFrameOrigin(NSPoint(x: originX.rounded(), y: max(visibleFrame.minY, originY.rounded())))
    }

    @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
        guard let tab = ClippieSettingsTab(rawValue: sender.itemIdentifier.rawValue) else {
            return
        }

        mainViewModel.selectedTab = tab
    }
}

extension SettingsWindowController: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ClippieSettingsTab.allCases.map(\.toolbarIdentifier)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ClippieSettingsTab.allCases.map(\.toolbarIdentifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ClippieSettingsTab.allCases.map(\.toolbarIdentifier)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let tab = ClippieSettingsTab(rawValue: itemIdentifier.rawValue) else {
            return nil
        }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.label
        item.image = NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: tab.label)
        item.target = self
        item.action = #selector(toolbarItemClicked(_:))
        return item
    }
}

@MainActor
private final class ClippieSettingsMainViewModel: ObservableObject {
    @Published var selectedTab: ClippieSettingsTab = .general
}

private struct ClippieSettingsRootView: View {
    @ObservedObject var mainViewModel: ClippieSettingsMainViewModel
    let store: ClipboardStore

    var body: some View {
        Group {
            switch mainViewModel.selectedTab {
            case .general:
                SettingsView(clipboardStore: store)
            case .about:
                ClippieAboutSettingsView()
            }
        }
        .frame(
            width: ClippieSettingsWindowMetrics.width,
            height: ClippieSettingsWindowMetrics.height,
            alignment: .topLeading
        )
    }
}

private struct ClippieAboutSettingsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "paperclip")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Clippie")
                .font(.title)
                .fontWeight(.semibold)
            Text("Clipboard history and snippets for macOS")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
