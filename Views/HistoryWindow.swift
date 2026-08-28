import Cocoa
import SwiftUI

/// Custom panel that closes when clicking outside
class HistoryPanel: NSPanel {
    var onClickOutside: (() -> Void)?
    
    override var canBecomeKey: Bool { true }
    
    override func resignKey() {
        super.resignKey()
        onClickOutside?()
    }
}

private struct ChunkedTextState {
    var visibleText: String = ""
    var totalBytes: Int = 0
    var loadedCharCount: Int = 0
    var reachedEOF: Bool = true
    var isLoadingMore: Bool = false
    static let chunkSize = 2_000
    static let initialChars = 2_000
    static let maximumPreviewChars = 8_000
    var hasMore: Bool {
        !reachedEOF && loadedCharCount >= Self.initialChars && loadedCharCount < Self.maximumPreviewChars
    }
    var reachedPreviewLimit: Bool {
        !reachedEOF && loadedCharCount >= Self.maximumPreviewChars
    }
}

private struct VisualEffectBackdropView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var emphasized = true

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            ? .windowBackground
            : material
        nsView.blendingMode = blendingMode
        nsView.state = .active
        nsView.isEmphasized = emphasized
    }
}

private struct GlassPanelBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    private var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    private var overlayOpacity: Double {
        if reduceTransparency {
            return 0.96
        }

        return colorScheme == .dark ? 0.3 : 0.18
    }

    private var highlightOpacity: Double {
        if reduceTransparency {
            return 0
        }

        return colorScheme == .dark ? 0.08 : 0.16
    }

    var body: some View {
        ZStack {
            VisualEffectBackdropView(material: .hudWindow)

            Color(NSColor.windowBackgroundColor)
                .opacity(overlayOpacity)

            LinearGradient(
                colors: [
                    Color.white.opacity(highlightOpacity),
                    Color.white.opacity(0)
                ],
                startPoint: .top,
                endPoint: .center
            )
        }
    }
}

/// Manages the floating history window
class HistoryWindowController: NSWindowController {
    private let store: ClipboardStore
    private let diagnostics = DiagnosticsLog.shared
    private var targetApplicationForPaste: NSRunningApplication?
    private var storedStandardFrame: NSRect?
    private var isPresentingImagePreview = false
    
    init(store: ClipboardStore) {
        self.store = store
        
        // Keep the split pane roomy, but pull the overall window in a bit.
        let panel = HistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        super.init(window: panel)
        
        panel.onClickOutside = { [weak self] in
            self?.close()
        }
        
        setupPanel(panel)
        setupContent()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupPanel(_ panel: NSPanel) {
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 16
        panel.contentView?.layer?.masksToBounds = true
        
        panel.center()
        
        // Notify content view when window becomes key so it can reset state
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: panel,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(name: .bufferWindowDidOpen, object: nil)
        }

        NotificationCenter.default.addObserver(
            forName: .bufferImagePreviewPresentationChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let isPresented = notification.userInfo?["isPresented"] as? Bool ?? false
            self.updateImagePreviewPresentation(isPresented)
        }
    }
    
    private func setupContent() {
        let contentView = ZStack {
            GlassPanelBackground()

            HistoryContentView(
                store: store,
                onCopyToClipboard: { [weak self] item in
                    self?.copyToClipboard(item)
                },
                onPaste: { [weak self] item in
                    self?.pasteItem(item)
                },
                onCopyText: { [weak self] text in
                    self?.copyTextToClipboard(text)
                },
                onPasteText: { [weak self] text in
                    self?.pasteText(text)
                },
                onDismiss: { [weak self] in
                    self?.close()
                }
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        
        window?.contentView = NSHostingView(rootView: contentView)
    }
    
    private func copyToClipboard(_ item: ClipboardItem) {
        PasteController.copyToClipboard(item, store: store)
    }
    
    private func copyTextToClipboard(_ text: String) {
        PasteController.copyTextToClipboard(text)
    }
    
    private func pasteItem(_ item: ClipboardItem) {
        let targetApplication = targetApplicationForPaste
        store.moveToTop(item)
        close()
        PasteController.paste(item, store: store, targetApplication: targetApplication)
    }
    
    private func pasteText(_ text: String) {
        let targetApplication = targetApplicationForPaste
        close()
        PasteController.paste(text: text, targetApplication: targetApplication)
    }
    
    override func showWindow(_ sender: Any?) {
        let showStart = diagnostics.isEnabled ? ContinuousClock.now : nil
        captureCurrentTargetApplication()
        if !isPresentingImagePreview {
            window?.center()
        }
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(window?.contentView)

        if let showStart {
            diagnostics.benchmark(
                "historyWindow.orderFront",
                durationMilliseconds: DiagnosticsLog.elapsedMilliseconds(since: showStart),
                details: "items=\(self.store.items.count)"
            )
            DispatchQueue.main.async { [diagnostics] in
                diagnostics.benchmark(
                    "historyWindow.nextRunLoop",
                    durationMilliseconds: DiagnosticsLog.elapsedMilliseconds(since: showStart),
                    details: "items=\(self.store.items.count)"
                )
            }
        }
    }

    private func updateImagePreviewPresentation(_ isPresented: Bool) {
        guard let panel = window else { return }

        if isPresented {
            guard !isPresentingImagePreview else { return }
            isPresentingImagePreview = true
            storedStandardFrame = panel.frame
            panel.level = .modalPanel

            guard let screen = panel.screen ?? NSScreen.main else { return }
            let visibleFrame = screen.visibleFrame
            let targetWidth = max(960, floor(visibleFrame.width * 0.88))
            let targetHeight = max(560, floor(visibleFrame.height * 0.86))
            let frame = NSRect(
                x: visibleFrame.midX - (targetWidth / 2),
                y: visibleFrame.midY - (targetHeight / 2),
                width: targetWidth,
                height: targetHeight
            )

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
            return
        }

        guard isPresentingImagePreview else { return }
        isPresentingImagePreview = false
        panel.level = .floating

        guard let storedStandardFrame else { return }
        self.storedStandardFrame = nil

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(storedStandardFrame, display: true)
        }
    }

    private func captureCurrentTargetApplication() {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            targetApplicationForPaste = nil
            return
        }

        if frontmostApplication.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            targetApplicationForPaste = nil
            return
        }

        targetApplicationForPaste = frontmostApplication
    }
}

extension Notification.Name {
    static let bufferDidWritePasteboard = Notification.Name("bufferDidWritePasteboard")
    static let bufferHotkeyChanged = Notification.Name("bufferHotkeyChanged")
    static let bufferWindowDidOpen = Notification.Name("bufferWindowDidOpen")
    static let bufferHistoryLimitChanged = Notification.Name("bufferHistoryLimitChanged")
    static let bufferImagePreviewPresentationChanged = Notification.Name("bufferImagePreviewPresentationChanged")
}

private enum HistorySelectionID: Hashable {
    case clipboard(UUID)
    case snippet(UUID)
}

private struct HistoryNavigationMeasurement {
    let sequence: Int
    let triggeredAt: ContinuousClock.Instant
    let direction: String
    let isRepeat: Bool
    let keyIntervalMilliseconds: Double?
    let selectionID: HistorySelectionID
    let kind: String
    let storage: String
    let contentCharacterCount: Int?
    let previewCharacterCount: Int
    var bytes: Int
    var didRequestScroll = false
    var didShowSelectedRow = false
    var didCompletePreview = false
    var didReachPreviewNextRunLoop = false

    var isComplete: Bool {
        didShowSelectedRow && didReachPreviewNextRunLoop
    }

    var stage: String {
        if didReachPreviewNextRunLoop { return "preview_next_run_loop" }
        if didCompletePreview { return "preview_ready" }
        if didShowSelectedRow { return "row_appeared" }
        if didRequestScroll { return "scroll_requested" }
        return "selection_changed"
    }
}

private enum HistorySearchResult: Identifiable {
    case clipboard(ClipboardItem)
    case snippet(Snippet)
    
    var id: String {
        switch self {
        case .clipboard(let item):
            return "clipboard-\(item.id.uuidString)"
        case .snippet(let snippet):
            return "snippet-\(snippet.id.uuidString)"
        }
    }
    
    var selectionID: HistorySelectionID {
        switch self {
        case .clipboard(let item):
            return .clipboard(item.id)
        case .snippet(let snippet):
            return .snippet(snippet.id)
        }
    }
}

private enum DetailPaneMode: Equatable {
    case preview
    case quickActions
    case imagePreview
}

private enum QuickActionRoute: Equatable {
    case home
    case saveSnippet
    case confirmation(QuickActionConfirmationKind)
}

private enum QuickActionConfirmationKind: Equatable {
    case deleteHistory
}

private enum QuickActionConfirmationChoice: Equatable {
    case cancel
    case confirm
}

private enum QuickActionHomeOption: Equatable {
    case showLargerImage
    case saveSnippet
    case runOCR
    case deleteHistory
}

private struct SnippetRow: View {
    let snippet: Snippet
    let isSelected: Bool

    @State private var isHovered = false

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.15)
        } else if isHovered {
            return Color.primary.opacity(0.05)
        }
        return Color.clear
    }

    private var backgroundCornerRadius: CGFloat {
        isSelected ? 0 : 5
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(":\(snippet.trigger)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.accentColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(snippet.content)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            backgroundColor,
            in: RoundedRectangle(cornerRadius: backgroundCornerRadius, style: .continuous)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct QuickActionRow: View {
    enum Tone {
        case normal
        case destructive

        var iconColor: Color {
            switch self {
            case .normal:
                return .secondary
            case .destructive:
                return .red
            }
        }

        var textColor: Color {
            switch self {
            case .normal:
                return .primary
            case .destructive:
                return .red
            }
        }

        func backgroundColor(isSelected: Bool, isHovered: Bool) -> Color {
            switch (self, isSelected, isHovered) {
            case (.destructive, true, _):
                return Color.red.opacity(0.11)
            case (.destructive, false, true):
                return Color.red.opacity(0.07)
            case (.normal, true, _):
                return Color.primary.opacity(0.08)
            case (.normal, false, true):
                return Color.primary.opacity(0.05)
            default:
                return Color.clear
            }
        }
    }

    let title: String
    let systemImage: String
    let isSelected: Bool
    var tone: Tone = .normal
    let action: () -> Void

    @State private var isHovered = false

    private var backgroundColor: Color {
        tone.backgroundColor(isSelected: isSelected, isHovered: isHovered)
    }

    private var backgroundCornerRadius: CGFloat {
        6
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundColor(tone.iconColor)
                    .frame(width: 18, height: 18)

                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(tone.textColor)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "return")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.5))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                backgroundColor,
                in: RoundedRectangle(cornerRadius: backgroundCornerRadius, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

/// Main content view - Split pane with list and detail
struct HistoryContentView: View {
    private static let initialVisibleClipboardItemLimit = 50
    private static let searchDebounceDelay: DispatchTimeInterval = .milliseconds(70)
    private static let keyboardPreviewDelayNanoseconds: UInt64 = 300_000_000
    private static let navigationPreviewCharacterLimit = 300

    @ObservedObject var store: ClipboardStore
    @StateObject private var snippetStore = SnippetStore.shared
    private let diagnostics = DiagnosticsLog.shared
    let onCopyToClipboard: (ClipboardItem) -> Void
    let onPaste: (ClipboardItem) -> Void
    let onCopyText: (String) -> Void
    let onPasteText: (String) -> Void
    let onDismiss: () -> Void
    
    @FocusState private var isSearchFocused: Bool
    @FocusState private var quickActionFocusedField: QuickActionFocusedField?
    @State private var searchText = ""
    @State private var selectedIndex = 0
    @State private var previewImage: NSImage?
    @State private var chunkedText = ChunkedTextState()
    @State private var scrollTrigger = false  // Triggers scroll on keyboard navigation
    @State private var itemSize: Int?         // Holds computed size of item
    @State private var detailPaneMode: DetailPaneMode = .preview
    @State private var quickActionRoute: QuickActionRoute = .home
    @State private var snippetDraftTrigger = ""
    @State private var snippetDraftContent = ""
    @State private var quickActionHomeSelection = 0
    @State private var quickActionConfirmationSelection = 0
    @State private var quickActionMessage: String?
    @State private var quickActionError: String?
    @State private var filteredClipboardItems: [ClipboardItem] = []
    @State private var clipboardSearchRevision = 0
    @State private var navigationSequence = 0
    @State private var pendingNavigation: HistoryNavigationMeasurement?
    @State private var previousNavigationKeyAt: ContinuousClock.Instant?
    @State private var previewSelectionID: HistorySelectionID?
    @State private var isKeyboardNavigationSelection = false
    
    
    // OCR state
    @State private var isExtractingText = false
    
    // Track selection by ID so it survives list insertions
    @State private var selectedID: HistorySelectionID?
    
    private var isSnippetSearch: Bool {
        searchText.hasPrefix(":")
    }

    private var filteredItems: [ClipboardItem] {
        if isSnippetSearch {
            return []
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return Array(store.items.prefix(Self.initialVisibleClipboardItemLimit))
        }

        return filteredClipboardItems
    }
    
    private var filteredSnippets: [Snippet] {
        guard isSnippetSearch else { return [] }
        
        let query = String(searchText.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return snippetStore.snippets
        }
        return snippetStore.matches(for: query)
    }
    
    private var filteredResults: [HistorySearchResult] {
        if isSnippetSearch {
            return filteredSnippets.map { .snippet($0) }
        }
        return filteredItems.map { .clipboard($0) }
    }
    
    private var selectedResult: HistorySearchResult? {
        if let id = selectedID, let result = filteredResults.first(where: { $0.selectionID == id }) {
            return result
        }
        return filteredResults[safe: selectedIndex]
    }
    
    private var selectedItem: ClipboardItem? {
        if case .clipboard(let item)? = selectedResult {
            return store.items.first(where: { $0.id == item.id }) ?? item
        }
        return nil
    }
    
    private var selectedSnippet: Snippet? {
        if case .snippet(let snippet)? = selectedResult {
            return snippet
        }
        return nil
    }
    
    private var resultCountLabel: String {
        let count = filteredResults.count
        if isSnippetSearch {
            return "\(count) snippet" + (count == 1 ? "" : "s")
        }
        return "\(count) item" + (count == 1 ? "" : "s")
    }

    private var selectedItemActionText: String? {
        guard let item = selectedItem else { return nil }
        return actionText(for: item)
    }

    private var selectedItemActionWarning: String? {
        guard let item = selectedItem else { return nil }
        return actionWarning(for: item)
    }

    private var reduceTransparencyEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    private var chromeSurfaceFill: Color {
        Color(NSColor.windowBackgroundColor).opacity(reduceTransparencyEnabled ? 0.96 : 0.34)
    }

    private var paneSurfaceFill: Color {
        Color(NSColor.controlBackgroundColor).opacity(reduceTransparencyEnabled ? 0.98 : 0.2)
    }

    private var cardSurfaceFill: Color {
        Color(NSColor.textBackgroundColor).opacity(reduceTransparencyEnabled ? 1 : 0.62)
    }

    private var inputSurfaceFill: Color {
        Color(NSColor.textBackgroundColor).opacity(reduceTransparencyEnabled ? 1 : 0.5)
    }

    private var surfaceStroke: Color {
        Color.primary.opacity(reduceTransparencyEnabled ? 0.08 : 0.12)
    }

    private var isImagePreviewActive: Bool {
        detailPaneMode == .imagePreview && selectedItem?.type == .image
    }
    
    var body: some View {
        Group {
            if isImagePreviewActive, let item = selectedItem {
                imagePreviewPane(for: item)
            } else {
                VStack(spacing: 0) {
                    // Search bar
                    searchBar
                    
                    Divider()
                    
                    if filteredResults.isEmpty {
                        emptyResultsPane
                    } else {
                        // Split pane: List + Detail
                        HSplitView {
                            // Left: List
                            listPane
                                .frame(minWidth: 300, maxWidth: 340)
                            
                            // Right: Detail
                            detailPane
                                .frame(minWidth: 260)
                        }
                    }
                }
            }
        }
        .frame(
            minWidth: isImagePreviewActive ? 720 : 580,
            minHeight: isImagePreviewActive ? 520 : 400
        )
        .onAppear {
            refreshFilteredItems()
        }
        .onChange(of: searchText) { _ in
            pendingNavigation = nil
            previousNavigationKeyAt = nil
            isKeyboardNavigationSelection = false
            resetQuickActionState()
            selectedIndex = 0
            selectedID = nil
            refreshFilteredItems()
        }
        .onChange(of: selectedIndex) { newIndex in
            selectedID = filteredResults[safe: newIndex]?.selectionID
        }
        .onChange(of: selectedID) { _ in
            resetQuickActionState()
        }
        .onChange(of: store.items) { _ in
            refreshFilteredItems()
        }
        .onChange(of: snippetStore.snippets) { _ in
            if isSnippetSearch {
                syncSelection()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bufferWindowDidOpen)) { _ in
            pendingNavigation = nil
            previousNavigationKeyAt = nil
            previewSelectionID = nil
            isKeyboardNavigationSelection = false
            resetQuickActionState()
            searchText = ""
            selectedIndex = 0
            selectedID = store.items.first.map { HistorySelectionID.clipboard($0.id) }
            refreshFilteredItems()
            // Delay needed for NSHostingView to have settled as key window
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFocused = true
            }
        }
        .task(id: selectedResult?.id) {
            let result = selectedResult
            let selectionID = result?.selectionID
            let collectDiagnostics = diagnostics.isEnabled
            let previewStart = collectDiagnostics ? ContinuousClock.now : nil
            resetQuickActionState()
            previewImage = nil
            chunkedText = ChunkedTextState()
            isExtractingText = false
            itemSize = nil
            previewSelectionID = nil

            if isKeyboardNavigationSelection {
                try? await Task.sleep(nanoseconds: Self.keyboardPreviewDelayNanoseconds)
                guard !Task.isCancelled else { return }
            }

            if case .clipboard(let item)? = result {
                let sizeLookupStart = collectDiagnostics ? ContinuousClock.now : nil
                itemSize = store.itemSize(for: item)
                let sizeLookupMilliseconds = sizeLookupStart.map {
                    DiagnosticsLog.elapsedMilliseconds(since: $0)
                } ?? 0
                let loadStart = collectDiagnostics ? ContinuousClock.now : nil
                
                if item.type == .image {
                    previewImage = await loadPreviewImage(for: item)
                } else if item.type == .text {
                    if item.isFileBacked {
                        await loadInitialChunk(for: item)
                    } else {
                        chunkedText.visibleText = item.textContent ?? ""
                        chunkedText.reachedEOF = true
                    }
                }

                let loadMilliseconds = loadStart.map {
                    DiagnosticsLog.elapsedMilliseconds(since: $0)
                } ?? 0
                let storage: String
                if item.type == .image {
                    storage = "file"
                } else if item.isFileBacked {
                    storage = "file"
                } else if item.isTruncated {
                    storage = "truncated"
                } else {
                    storage = "inline"
                }

                guard !Task.isCancelled, selectedResult?.selectionID == selectionID else { return }
                previewSelectionID = selectionID

                if let previewStart {
                    diagnostics.benchmark(
                        "historyPreview.ready",
                        durationMilliseconds: DiagnosticsLog.elapsedMilliseconds(since: previewStart),
                        details: "type=\(item.type.rawValue) storage=\(storage) bytes=\(itemSize ?? 0) size_lookup_ms=\(DiagnosticsLog.format(sizeLookupMilliseconds)) load_ms=\(DiagnosticsLog.format(loadMilliseconds)) cancelled=\(Task.isCancelled)"
                    )
                    recordNavigationPreviewReady(
                        selectionID: .clipboard(item.id),
                        bytes: itemSize ?? 0,
                        loadMilliseconds: loadMilliseconds
                    )
                }
            } else if case .snippet(let snippet)? = result {
                let bytes = snippet.content.utf8.count
                guard !Task.isCancelled, selectedResult?.selectionID == selectionID else { return }
                previewSelectionID = selectionID

                if let previewStart {
                    diagnostics.benchmark(
                        "historyPreview.ready",
                        durationMilliseconds: DiagnosticsLog.elapsedMilliseconds(since: previewStart),
                        details: "type=snippet storage=inline bytes=\(bytes) content_chars=\(snippet.content.count) load_ms=0.00 cancelled=\(Task.isCancelled)"
                    )
                    recordNavigationPreviewReady(
                        selectionID: .snippet(snippet.id),
                        bytes: bytes,
                        loadMilliseconds: 0
                    )
                }
            }
        }
        .background(GlobalKeyMonitor(
            onUp: { event in
                navigateUp(event: event)
            },
            onDown: { event in
                navigateDown(event: event)
            },
            onLeft: {
                navigateLeft()
            },
            onRight: {
                navigateRight()
            },
            onEnter: {
                activateCurrentSelection()
            },
            onEscape: {
                handleEscape()
            },
            onDelete: {
                if let item = selectedItem {
                    deleteSelectedItem(item)
                }
            },
            onCopy: {
                if let item = selectedItem {
                    onCopyToClipboard(item)
                } else if let snippet = selectedSnippet {
                    onCopyText(snippet.content)
                }
            }
        ))
    }
    
    private func loadPreviewImage(for item: ClipboardItem) async -> NSImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let img = store.image(for: item)
                continuation.resume(returning: img)
            }
        }
    }
    
    private func loadInitialChunk(for item: ClipboardItem) async {
        chunkedText.isLoadingMore = true // Initial load spinner
        let chunkSource = store.textChunkSource(for: item)
        
        let chunkResult = await Task.detached(priority: .userInitiated) {
            ClipboardStore.readTextChunk(from: chunkSource, charCount: ChunkedTextState.initialChars)
        }.value
        
        if let result = chunkResult {
            chunkedText.visibleText = result.text
            chunkedText.totalBytes = result.totalBytes
            chunkedText.loadedCharCount = result.text.count
            chunkedText.reachedEOF = result.reachedEOF
        }
        chunkedText.isLoadingMore = false
    }
    
    private func loadNextChunk(for item: ClipboardItem) async {
        guard !chunkedText.isLoadingMore && chunkedText.hasMore else { return }
        
        chunkedText.isLoadingMore = true
        let nextCharCount = min(
            chunkedText.loadedCharCount + ChunkedTextState.chunkSize,
            ChunkedTextState.maximumPreviewChars
        )
        let chunkSource = store.textChunkSource(for: item)
        
        let chunkResult = await Task.detached(priority: .userInitiated) {
            ClipboardStore.readTextChunk(from: chunkSource, charCount: nextCharCount)
        }.value
        
        if let result = chunkResult {
            chunkedText.visibleText = result.text
            chunkedText.totalBytes = result.totalBytes
            chunkedText.loadedCharCount = result.text.count
            chunkedText.reachedEOF = result.reachedEOF
        }
        chunkedText.isLoadingMore = false
    }
    
    private func formattedByteCount(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    private func formattedSize(bytes: Int) -> String {
        return formattedByteCount(bytes)
    }
    
    private func relativeCopiedText(for date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        
        if seconds < 60 {
            return "Copied just now"
        }
        
        if seconds < 3_600 {
            let minutes = seconds / 60
            return "Copied \(minutes) min ago"
        }
        
        if seconds < 86_400 {
            let hours = seconds / 3_600
            return "Copied \(hours)h ago"
        }
        
        let days = seconds / 86_400
        return "Copied \(days)d ago"
    }
    
    private func fullCopiedText(for date: Date) -> String {
        date.formatted(
            Date.FormatStyle()
                .year()
                .month(.abbreviated)
                .day()
                .hour()
                .minute()
        )
    }
    
    private var searchBar: some View {
        HStack(spacing: 8) {
            TextField("", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFocused)
                .accessibilityLabel("Search clipboard")

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary.opacity(0.4))
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(chromeSurfaceFill)
    }

    private var emptyResultsPane: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: searchText.isEmpty ? "clipboard" : "magnifyingglass")
                .font(.system(size: 20, weight: .light))
                .foregroundColor(.secondary.opacity(0.3))
            Text(emptyStateText)
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.5))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(paneSurfaceFill)
    }
    
    private var listPane: some View {
        Group {
            if filteredResults.isEmpty {
                // Empty state with icon for visual weight
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: searchText.isEmpty ? "clipboard" : "magnifyingglass")
                        .font(.system(size: 20, weight: .light))
                        .foregroundColor(.secondary.opacity(0.3))
                    Text(emptyStateText)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.5))
                    Spacer()
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(filteredResults.enumerated()), id: \.element.id) { index, result in
                                resultRow(for: result, isSelected: index == selectedIndex)
                                    .id(result.id)
                                    .background(
                                        navigationRowProbe(
                                            for: result,
                                            isSelected: index == selectedIndex
                                        )
                                    )
                                    .contentShape(Rectangle())
                                    .contextMenu {
                                        resultContextMenu(for: result, index: index)
                                    }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onChange(of: selectedIndex) { newValue in
                        if scrollTrigger {
                            if let result = filteredResults[safe: newValue] {
                                if diagnostics.isEnabled {
                                    let scrollStart = ContinuousClock.now
                                    proxy.scrollTo(result.id)
                                    recordNavigationScrollRequested(
                                        selectionID: result.selectionID,
                                        scrollCallMilliseconds: DiagnosticsLog.elapsedMilliseconds(since: scrollStart)
                                    )
                                } else {
                                    proxy.scrollTo(result.id)
                                }
                            }
                            scrollTrigger = false
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .bufferWindowDidOpen)) { _ in
                        if let firstID = filteredResults.first?.id {
                            proxy.scrollTo(firstID, anchor: .top)
                        }
                    }
                }
            }
        }
        // Keep the list readable, but let the glass show through underneath.
        .background(paneSurfaceFill)
    }
    
    private var detailPane: some View {
        Group {
            if let item = selectedItem, detailPaneMode == .quickActions {
                quickActionsPane(for: item)
            } else if let item = selectedItem, detailPaneMode == .imagePreview {
                imagePreviewPane(for: item)
            } else if let result = selectedResult,
                      previewSelectionID != result.selectionID {
                navigationPreview(for: result)
            } else if let item = selectedItem {
                previewPane(for: item)
            } else if let snippet = selectedSnippet {
                ScrollView {
                    snippetContent(snippet)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                // Empty detail state — give it some visual presence
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 28, weight: .ultraLight))
                        .foregroundColor(.secondary.opacity(0.25))
                    Text("Select an item to preview")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func navigationPreview(for result: HistorySearchResult) -> some View {
        ScrollView {
            switch result {
            case .clipboard(let item) where item.type == .text:
                Text(String((item.textContent ?? "").prefix(Self.navigationPreviewCharacterLimit)))
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            case .clipboard:
                Image(systemName: "photo")
                    .font(.system(size: 28, weight: .ultraLight))
                    .foregroundColor(.secondary.opacity(0.35))
                    .frame(maxWidth: .infinity)
            case .snippet(let snippet):
                Text(String(snippet.content.prefix(Self.navigationPreviewCharacterLimit)))
                    .font(.system(size: 13, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(16)
    }

    private func previewPane(for item: ClipboardItem) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                itemContent(item)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Divider()

            HStack {
                if !item.isFileBacked, let text = item.textContent, !text.isEmpty {
                    let words = text.split(whereSeparator: \.isWhitespace).count
                    Text("\(words) words · \(text.count) chars")
                } else if let size = itemSize, size > 0 {
                    Text(formattedByteCount(size))
                }
                Spacer()
                Text(fullCopiedText(for: item.timestamp))
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary.opacity(0.7))
            .monospacedDigit()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func imagePreviewPane(for item: ClipboardItem) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: closeDetailOverlay) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)

                Spacer()

                if let size = itemSize, size > 0 {
                    Text(formattedByteCount(size))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.75))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(chromeSurfaceFill)

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(reduceTransparencyEnabled ? 0.06 : 0.1))

                if let img = previewImage {
                    GeometryReader { proxy in
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(
                                width: max(proxy.size.width - 24, 1),
                                height: max(proxy.size.height - 24, 1)
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(12)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle()
                .fill(Color.primary.opacity(0.05))
                .frame(height: 1)

            HStack {
                Text(fullCopiedText(for: item.timestamp))
                Spacer()
                Text("Esc or Left Arrow to close")
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary.opacity(0.7))
            .monospacedDigit()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func quickActionsPane(for item: ClipboardItem) -> some View {
        VStack(spacing: 0) {
            // Sub-screen header with back chevron (hidden on home)
            if quickActionRoute != .home {
                quickActionsSubScreenHeader(for: item)
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)
            }

            ScrollView {
                let isHome = quickActionRoute == .home
                let bannerHorizontalPadding: CGFloat = isHome ? 10 : 0

                VStack(alignment: .leading, spacing: isHome ? 6 : 10) {
                    // Status banners sit at the top of content
                    if let quickActionMessage {
                        quickActionStatus(text: quickActionMessage, systemImage: "checkmark.circle.fill", tint: .green)
                            .padding(.horizontal, bannerHorizontalPadding)
                    }
                    if let quickActionError {
                        quickActionStatus(text: quickActionError, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                            .padding(.horizontal, bannerHorizontalPadding)
                    }

                    switch quickActionRoute {
                    case .home:
                        quickActionsHomePane(for: item)
                    case .saveSnippet:
                        quickActionSaveSnippetPane(for: item)
                    case .confirmation(let confirmation):
                        quickActionConfirmationPane(for: confirmation, item: item)
                    }
                }
                .padding(.horizontal, isHome ? 0 : 14)
                .padding(.top, isHome ? 0 : 14)
                .padding(.bottom, isHome ? 6 : 14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    // Back button header shared by all sub-screens
    private func quickActionsSubScreenHeader(for item: ClipboardItem) -> some View {
        HStack(spacing: 4) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    returnToQuickActionsHome()
                }
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Actions")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(chromeSurfaceFill)
    }

    private func quickActionsHomePane(for item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                let options = quickActionOptions(for: item)
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    let isDestructive = option == .deleteHistory
                    let isSelected = index == quickActionHomeSelection

                    if isDestructive, index > 0 {
                        Color.clear
                            .frame(height: 6)
                    }

                    QuickActionRow(
                        title: quickActionTitle(for: option, item: item),
                        systemImage: quickActionSystemImage(for: option),
                        isSelected: isSelected,
                        tone: isDestructive ? .destructive : .normal,
                        action: {
                            quickActionHomeSelection = index
                            activateQuickAction(option, for: item)
                        }
                    )
                }
            }

            if let warning = selectedItemActionWarning {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                    Text(warning)
                        .font(.system(size: 11))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }
        }
    }

    private func quickActionSaveSnippetPane(for item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !canSaveItemAsSnippet(item) || selectedItemActionText == nil {
                // No-text warning state
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 13))
                        .foregroundColor(.orange)
                    Text(selectedItemActionWarning ?? "This item does not have text available for snippets.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                snippetFormField(
                    label: "Trigger",
                    placeholder: "shortcut",
                    text: $snippetDraftTrigger,
                    focusedField: .snippetTrigger
                )

                VStack(alignment: .leading, spacing: 5) {
                    quickFormLabel("Text")
                    TextEditor(text: $snippetDraftContent)
                        .font(.system(size: 12))
                        .frame(minHeight: 100)
                        .scrollContentBackground(.hidden)
                        .background(inputSurfaceFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(surfaceStroke, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }

            // CTA at bottom
            Button("Save Snippet") {
                saveSnippetFromQuickActions()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .disabled(selectedItemActionText == nil)
        }
    }

    private func quickActionConfirmationPane(
        for confirmation: QuickActionConfirmationKind,
        item: ClipboardItem
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: quickActionConfirmationSystemImage(for: confirmation))
                    .font(.system(size: 13))
                    .foregroundColor(quickActionConfirmationTint(for: confirmation))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(quickActionConfirmationTitle(for: confirmation))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(quickActionConfirmationMessage(for: confirmation))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(quickActionConfirmationTint(for: confirmation).opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(quickActionConfirmationTint(for: confirmation).opacity(0.12), lineWidth: 1)
            )

            VStack(spacing: 0) {
                let choices = quickActionConfirmationChoices(for: confirmation)
                ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                    QuickActionRow(
                        title: quickActionConfirmationChoiceTitle(for: choice, confirmation: confirmation),
                        systemImage: quickActionConfirmationChoiceSystemImage(for: choice, confirmation: confirmation),
                        isSelected: index == quickActionConfirmationSelection,
                        tone: quickActionConfirmationChoiceTone(for: choice, confirmation: confirmation),
                        action: {
                            quickActionConfirmationSelection = index
                            activateQuickActionConfirmation(choice, confirmation: confirmation, item: item)
                        }
                    )
                }
            }
        }
    }

    private func quickActionStatus(text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 12))
            .foregroundColor(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // Helpers for sub-screen form fields
    private func quickFormLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .tracking(0.3)
    }

    private func snippetFormField(
        label: String,
        placeholder: String,
        text: Binding<String>,
        focusedField: QuickActionFocusedField? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            quickFormLabel(label)
            TextField(placeholder, text: text)
                .focused($quickActionFocusedField, equals: focusedField)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(inputSurfaceFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(surfaceStroke, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
    
    private var emptyStateText: String {
        if searchText.isEmpty {
            return "No clipboard history"
        }
        return isSnippetSearch ? "No snippets" : "No matches"
    }
    
    @ViewBuilder
    private func resultRow(for result: HistorySearchResult, isSelected: Bool) -> some View {
        switch result {
        case .clipboard(let item):
            ClipboardItemRow(
                item: item,
                store: store,
                isSelected: isSelected
            )
        case .snippet(let snippet):
            SnippetRow(snippet: snippet, isSelected: isSelected)
        }
    }

    @ViewBuilder
    private func navigationRowProbe(
        for result: HistorySearchResult,
        isSelected: Bool
    ) -> some View {
        if isSelected,
           let navigation = pendingNavigation,
           navigation.selectionID == result.selectionID {
            Color.clear
                .id("navigation-row-\(navigation.sequence)")
                .onAppear {
                    let sequence = navigation.sequence
                    DispatchQueue.main.async {
                        recordNavigationRowAppeared(sequence: sequence)
                    }
                }
        }
    }

    @ViewBuilder
    private func resultContextMenu(for result: HistorySearchResult, index: Int) -> some View {
        switch result {
        case .clipboard(let item):
            Button("Quick Actions") {
                selectResult(at: index)
                openQuickActions(for: item)
            }

            if item.type == .image {
                Button("Show Larger") {
                    selectResult(at: index)
                    openImagePreview(for: item)
                }
            }

            if canSaveItemAsSnippet(item) {
                Button("Save as Snippet") {
                    selectResult(at: index)
                    openQuickActions(for: item, route: .saveSnippet)
                }
            }

            if item.type == .image {
                Button(item.ocrText == nil ? "Run OCR" : "Refresh OCR") {
                    selectResult(at: index)
                    runOCR(for: item)
                }
            }

            Divider()

            Button("Delete from History", role: .destructive) {
                selectResult(at: index)
                deleteSelectedItem(item)
            }
        case .snippet:
            EmptyView()
        }
    }
    
    private func copySelectedResult(_ result: HistorySearchResult) {
        switch result {
        case .clipboard(let item):
            onCopyToClipboard(item)
        case .snippet(let snippet):
            onCopyText(snippet.content)
        }
    }
    
    private func activateResult(_ result: HistorySearchResult) {
        switch result {
        case .clipboard(let item):
            onPaste(item)
        case .snippet(let snippet):
            onPasteText(snippet.content)
        }
    }

    private func quickActionOptions(for item: ClipboardItem) -> [QuickActionHomeOption] {
        var options: [QuickActionHomeOption] = []

        if item.type == .image {
            options.append(.showLargerImage)
        }

        if canSaveItemAsSnippet(item) {
            options.append(.saveSnippet)
        }

        if item.type == .image {
            options.append(.runOCR)
        }

        options.append(.deleteHistory)
        return options
    }

    private func quickActionTitle(for option: QuickActionHomeOption, item: ClipboardItem) -> String {
        switch option {
        case .showLargerImage:
            return "Show Larger"
        case .saveSnippet:
            return "Save as Snippet"
        case .runOCR:
            return item.ocrText == nil ? "Run OCR" : "Refresh OCR"
        case .deleteHistory:
            return "Delete from History"
        }
    }

    private func quickActionSystemImage(for option: QuickActionHomeOption) -> String {
        switch option {
        case .showLargerImage:
            return "arrow.up.left.and.arrow.down.right"
        case .saveSnippet:
            return "square.and.arrow.down"
        case .runOCR:
            return isExtractingText ? "ellipsis.circle" : "text.viewfinder"
        case .deleteHistory:
            return "trash"
        }
    }

    private func quickActionConfirmationTitle(for confirmation: QuickActionConfirmationKind) -> String {
        switch confirmation {
        case .deleteHistory:
            return "Remove from History"
        }
    }

    private func quickActionConfirmationMessage(for confirmation: QuickActionConfirmationKind) -> String {
        switch confirmation {
        case .deleteHistory:
            return "This clipboard item will be permanently removed. This cannot be undone."
        }
    }

    private func quickActionConfirmationSystemImage(for confirmation: QuickActionConfirmationKind) -> String {
        switch confirmation {
        case .deleteHistory:
            return "trash"
        }
    }

    private func quickActionConfirmationTint(for confirmation: QuickActionConfirmationKind) -> Color {
        switch confirmation {
        case .deleteHistory:
            return .red
        }
    }

    private func quickActionConfirmationChoices(
        for confirmation: QuickActionConfirmationKind
    ) -> [QuickActionConfirmationChoice] {
        switch confirmation {
        case .deleteHistory:
            return [.cancel, .confirm]
        }
    }

    private func quickActionConfirmationChoiceTitle(
        for choice: QuickActionConfirmationChoice,
        confirmation: QuickActionConfirmationKind
    ) -> String {
        switch (confirmation, choice) {
        case (_, .cancel):
            return "Cancel"
        case (.deleteHistory, .confirm):
            return "Delete"
        }
    }

    private func quickActionConfirmationChoiceSystemImage(
        for choice: QuickActionConfirmationChoice,
        confirmation: QuickActionConfirmationKind
    ) -> String {
        switch (confirmation, choice) {
        case (_, .cancel):
            return "xmark"
        case (.deleteHistory, .confirm):
            return "trash"
        }
    }

    private func quickActionConfirmationChoiceTone(
        for choice: QuickActionConfirmationChoice,
        confirmation: QuickActionConfirmationKind
    ) -> QuickActionRow.Tone {
        switch (confirmation, choice) {
        case (.deleteHistory, .confirm):
            return .destructive
        default:
            return .normal
        }
    }

    private func activateQuickAction(_ option: QuickActionHomeOption, for item: ClipboardItem) {
        switch option {
        case .showLargerImage:
            openImagePreview(for: item)
        case .saveSnippet:
            openQuickActions(for: item, route: .saveSnippet)
        case .runOCR:
            runOCR(for: item)
        case .deleteHistory:
            quickActionMessage = nil
            quickActionError = nil
            quickActionRoute = .confirmation(.deleteHistory)
            quickActionConfirmationSelection = defaultQuickActionConfirmationSelection(for: .deleteHistory)
        }
    }

    private func defaultQuickActionConfirmationSelection(for confirmation: QuickActionConfirmationKind) -> Int {
        let choices = quickActionConfirmationChoices(for: confirmation)
        return choices.firstIndex(of: .confirm) ?? 0
    }

    private func activateQuickActionConfirmation(
        _ choice: QuickActionConfirmationChoice,
        confirmation: QuickActionConfirmationKind,
        item: ClipboardItem
    ) {
        switch choice {
        case .cancel:
            returnToQuickActionsHome()
        case .confirm:
            switch confirmation {
            case .deleteHistory:
                deleteSelectedItem(item)
            }
        }
    }

    private func returnToQuickActionsHome() {
        quickActionRoute = .home
        quickActionConfirmationSelection = 0
        quickActionFocusedField = nil
        quickActionError = nil
        quickActionMessage = nil
    }

    private func resetQuickActionState() {
        setDetailPaneMode(.preview)
        quickActionRoute = .home
        quickActionHomeSelection = 0
        quickActionConfirmationSelection = 0
        quickActionFocusedField = nil
        snippetDraftTrigger = ""
        snippetDraftContent = ""
        quickActionMessage = nil
        quickActionError = nil
    }

    private func canSaveItemAsSnippet(_ item: ClipboardItem) -> Bool {
        item.type == .text
    }

    private func actionText(for item: ClipboardItem) -> String? {
        switch item.type {
        case .text:
            let text = store.fullText(for: item) ?? item.textContent ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .image:
            return nil
        }
    }

    private func actionWarning(for item: ClipboardItem) -> String? {
        if item.isTruncated {
            return "Only the stored preview is available for snippet actions."
        }

        return nil
    }

    private func refreshFilteredItems() {
        clipboardSearchRevision += 1
        let revision = clipboardSearchRevision

        guard !isSnippetSearch else {
            filteredClipboardItems = []
            syncSelection()
            return
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            filteredClipboardItems = Array(store.items.prefix(Self.initialVisibleClipboardItemLimit))
            syncSelection()
            return
        }

        let items = store.items
        let collectDiagnostics = diagnostics.isEnabled
        let requestStart = collectDiagnostics ? ContinuousClock.now : nil
        let normalizationStart = collectDiagnostics ? ContinuousClock.now : nil
        let normalizedQuery = ClipboardStore.normalizeSearchText(query)
        let queryNormalizationMilliseconds = normalizationStart.map {
            DiagnosticsLog.elapsedMilliseconds(since: $0)
        } ?? 0
        let queryCharacterCount = query.count

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.searchDebounceDelay) {
            let scan = store.search(items, normalizedQuery: normalizedQuery)
            let scanFinished = collectDiagnostics ? ContinuousClock.now : nil

            DispatchQueue.main.async {
                let isCurrent = revision == clipboardSearchRevision
                guard isCurrent else {
                    if let requestStart, let scanFinished {
                        logSearchBenchmark(
                            scan,
                            queryCharacterCount: queryCharacterCount,
                            queryNormalizationMilliseconds: queryNormalizationMilliseconds,
                            requestStart: requestStart,
                            scanFinished: scanFinished,
                            applyMilliseconds: 0,
                            applied: false
                        )
                    }
                    return
                }

                let applyStart = collectDiagnostics ? ContinuousClock.now : nil
                filteredClipboardItems = scan.matches
                syncSelection()
                let applyMilliseconds = applyStart.map {
                    DiagnosticsLog.elapsedMilliseconds(since: $0)
                } ?? 0

                if let requestStart, let scanFinished {
                    logSearchBenchmark(
                        scan,
                        queryCharacterCount: queryCharacterCount,
                        queryNormalizationMilliseconds: queryNormalizationMilliseconds,
                        requestStart: requestStart,
                        scanFinished: scanFinished,
                        applyMilliseconds: applyMilliseconds,
                        applied: true
                    )

                    DispatchQueue.main.async { [diagnostics] in
                        diagnostics.benchmark(
                            "historySearch.nextRunLoop",
                            durationMilliseconds: DiagnosticsLog.elapsedMilliseconds(since: requestStart),
                            details: "query_chars=\(queryCharacterCount) items=\(scan.metrics.scannedItemCount) matches=\(scan.matches.count)"
                        )
                    }
                }
            }
        }
    }

    private func logSearchBenchmark(
        _ scan: ClipboardSearchScan,
        queryCharacterCount: Int,
        queryNormalizationMilliseconds: Double,
        requestStart: ContinuousClock.Instant,
        scanFinished: ContinuousClock.Instant,
        applyMilliseconds: Double,
        applied: Bool
    ) {
        guard diagnostics.isEnabled else { return }
        let metrics = scan.metrics
        let requestToMainMilliseconds = DiagnosticsLog.elapsedMilliseconds(since: requestStart)
        let resultQueueMilliseconds = DiagnosticsLog.elapsedMilliseconds(since: scanFinished)
        diagnostics.benchmark(
            "historySearch.scan",
            durationMilliseconds: metrics.scanMilliseconds,
            details: "request_to_main_ms=\(DiagnosticsLog.format(requestToMainMilliseconds)) result_queue_ms=\(DiagnosticsLog.format(resultQueueMilliseconds)) apply_ms=\(DiagnosticsLog.format(applyMilliseconds)) debounce_ms=70 query_normalize_ms=\(DiagnosticsLog.format(queryNormalizationMilliseconds)) query_chars=\(queryCharacterCount) items=\(metrics.scannedItemCount) matches=\(scan.matches.count) applied=\(applied) active_at_start=\(metrics.activeSearchCountAtStart) inline_text=\(metrics.inlineTextItemCount) file_text=\(metrics.fileBackedItemCount) images=\(metrics.imageItemCount) full_text_checks=\(metrics.fileFullTextChecks) cache_hits=\(metrics.fileCacheHits) cache_misses=\(metrics.fileCacheMisses) file_bytes_loaded=\(metrics.fileBytesLoaded) file_load_ms=\(DiagnosticsLog.format(metrics.fileLoadMilliseconds)) normalize_ms=\(DiagnosticsLog.format(metrics.normalizationMilliseconds)) slowest_item_ms=\(DiagnosticsLog.format(metrics.slowestItemMilliseconds)) slowest_item_bytes=\(metrics.slowestItemBytes) slowest_item_kind=\(metrics.slowestItemKind)"
        )
    }

    private func prepareSnippetDraft(for item: ClipboardItem) {
        let sourceText = actionText(for: item) ?? ""
        quickActionFocusedField = nil
        snippetDraftTrigger = ""
        snippetDraftContent = sourceText
    }

    private func openQuickActions(for item: ClipboardItem, route: QuickActionRoute = .home) {
        setDetailPaneMode(.quickActions)
        quickActionRoute = route
        quickActionMessage = nil
        quickActionError = nil

        switch route {
        case .home:
            quickActionHomeSelection = 0
            quickActionFocusedField = nil
        case .saveSnippet:
            prepareSnippetDraft(for: item)
            DispatchQueue.main.async {
                quickActionFocusedField = .snippetTrigger
            }
        case .confirmation(let confirmation):
            quickActionConfirmationSelection = defaultQuickActionConfirmationSelection(for: confirmation)
            quickActionFocusedField = nil
        }
    }

    private func openImagePreview(for item: ClipboardItem) {
        guard item.type == .image else { return }
        setDetailPaneMode(.imagePreview)
        quickActionMessage = nil
        quickActionError = nil
    }

    private func saveSnippetFromQuickActions() {
        guard let item = selectedItem, canSaveItemAsSnippet(item) else {
            quickActionError = "Only text clips can be saved as snippets."
            quickActionMessage = nil
            return
        }

        let content = snippetDraftContent.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try snippetStore.saveSnippet(
                title: "",
                trigger: snippetDraftTrigger,
                content: content
            )
            quickActionRoute = .home
            quickActionFocusedField = nil
            quickActionError = nil
            quickActionMessage = nil
            snippetDraftTrigger = ""
            snippetDraftContent = ""
        } catch {
            quickActionError = error.localizedDescription
            quickActionMessage = nil
        }
    }

    private func runOCR(for item: ClipboardItem) {
        guard item.type == .image else { return }
        guard let image = store.image(for: item) else {
            openQuickActions(for: item)
            quickActionError = "Couldn't load this image."
            quickActionMessage = nil
            return
        }

        setDetailPaneMode(.preview)
        quickActionRoute = .home
        quickActionConfirmationSelection = 0
        quickActionFocusedField = nil
        quickActionMessage = nil
        quickActionError = nil
        isExtractingText = true

        Task {
            let result = await OCRService.shared.recognizeText(from: image)

            await MainActor.run {
                let text = result?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedText = (text?.isEmpty == false) ? text! : "No text found in this image."
                store.setOCRText(resolvedText, for: item)
                isExtractingText = false
                guard selectedItem?.id == item.id else { return }
                setDetailPaneMode(.preview)
                quickActionRoute = .home
                quickActionConfirmationSelection = 0
                quickActionFocusedField = nil
                quickActionMessage = nil
                quickActionError = nil
            }
        }
    }

    private func deleteSelectedItem(_ item: ClipboardItem) {
        quickActionMessage = nil
        quickActionError = nil
        store.delete(item)
    }

    private func activateCurrentSelection() {
        if detailPaneMode == .quickActions, let item = selectedItem {
            switch quickActionRoute {
            case .home:
                let options = quickActionOptions(for: item)
                guard options.indices.contains(quickActionHomeSelection) else { return }
                activateQuickAction(options[quickActionHomeSelection], for: item)
            case .saveSnippet:
                if quickActionFocusedField == .snippetTrigger {
                    saveSnippetFromQuickActions()
                }
            case .confirmation(let confirmation):
                let choices = quickActionConfirmationChoices(for: confirmation)
                guard choices.indices.contains(quickActionConfirmationSelection) else { return }
                activateQuickActionConfirmation(
                    choices[quickActionConfirmationSelection],
                    confirmation: confirmation,
                    item: item
                )
            }
            return
        }

        if detailPaneMode == .imagePreview {
            return
        }

        if let result = selectedResult {
            activateResult(result)
        }
    }

    private func selectResult(at index: Int) {
        pendingNavigation = nil
        previousNavigationKeyAt = nil
        isKeyboardNavigationSelection = false
        selectedIndex = index
        selectedID = filteredResults[safe: index]?.selectionID
    }
    
    private func syncSelection() {
        guard !filteredResults.isEmpty else {
            selectedIndex = 0
            selectedID = nil
            return
        }
        
        guard let selectedID else {
            self.selectedID = filteredResults.first?.selectionID
            selectedIndex = 0
            return
        }
        
        if let newIndex = filteredResults.firstIndex(where: { $0.selectionID == selectedID }) {
            if selectedIndex != newIndex {
                selectedIndex = newIndex
            }
        } else {
            self.selectedID = filteredResults.first?.selectionID
            selectedIndex = 0
        }
    }
    
    @ViewBuilder
    private func itemContent(_ item: ClipboardItem) -> some View {
        switch item.type {
        case .text:
            if item.isTruncated {
                VStack(alignment: .leading, spacing: 12) {
                    Text(limitedInlinePreviewText(item.textContent ?? ""))
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                    Label("Content was too large to store (\(formattedSize(bytes: item.originalSizeBytes ?? 0))). Showing first 500 characters.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
            } else if item.isFileBacked {
                textContent(item)
            } else {
                inlineTextContent(item.textContent ?? "")
            }
        case .image:
            VStack(spacing: 12) {
                if let img = previewImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                } else {
                    // Loading placeholder
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: 200)
                }
                
                // OCR result
                if isExtractingText {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, 12)
                } else if let ocrText = item.ocrText {
                    VStack(alignment: .leading, spacing: 0) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.06))
                            .frame(height: 0.5)
                        
                        HStack(alignment: .top) {
                            Text(ocrText)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .lineSpacing(4)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            
                            Button(action: {
                                PasteController.copyTextToClipboard(ocrText)
                            }) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .help("Copy extracted text")
                        }
                        .padding(.top, 12)
                    }
                }
            }
        }
    }
    
    private func snippetContent(_ snippet: Snippet) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(":\(snippet.trigger)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.accentColor)
            
            Text(snippet.content)
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
    
    @ViewBuilder
    private func inlineTextContent(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(limitedInlinePreviewText(text))
                .font(.system(size: 14))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)

            if text.count > ChunkedTextState.maximumPreviewChars {
                previewLimitText(totalBytes: text.utf8.count)
            }
        }
    }

    private func limitedInlinePreviewText(_ text: String) -> String {
        guard text.count > ChunkedTextState.maximumPreviewChars else { return text }
        return String(text.prefix(ChunkedTextState.maximumPreviewChars))
    }

    @ViewBuilder
    private func textContent(_ item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(chunkedText.visibleText)
                .font(.system(size: 14))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            
            if chunkedText.isLoadingMore {
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, 8)
            } else if chunkedText.hasMore {
                // This hint fires .onAppear only when it scrolls into view (LazyVStack)
                // That's what triggers the next chunk load
                Text("— \(formattedByteCount(chunkedText.totalBytes)) total · scroll to load more —")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
                    .onAppear {
                        Task { await loadNextChunk(for: item) }
                    }
            } else if chunkedText.reachedPreviewLimit {
                previewLimitText(totalBytes: chunkedText.totalBytes)
            }
        }
    }

    private func previewLimitText(totalBytes: Int) -> some View {
        Text("— preview limited to \(ChunkedTextState.maximumPreviewChars.formatted()) chars · \(formattedByteCount(totalBytes)) total —")
            .font(.system(size: 11))
            .foregroundColor(.secondary.opacity(0.4))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
    }
    
    private func beginNavigation(
        to targetIndex: Int,
        direction: String,
        event: NavigationKeyEvent
    ) {
        guard let result = filteredResults[safe: targetIndex] else { return }

        isKeyboardNavigationSelection = true
        scrollTrigger = true

        guard diagnostics.isEnabled else {
            pendingNavigation = nil
            previousNavigationKeyAt = nil
            selectedIndex = targetIndex
            return
        }

        if let previous = pendingNavigation, !previous.isComplete {
            diagnostics.benchmark(
                "historyNavigation.superseded",
                durationMilliseconds: DiagnosticsLog.elapsedMilliseconds(since: previous.triggeredAt),
                details: navigationDetails(previous)
            )
        }

        let keyIntervalMilliseconds = event.isRepeat
            ? previousNavigationKeyAt.map { DiagnosticsLog.elapsedMilliseconds(since: $0) }
            : nil
        previousNavigationKeyAt = event.triggeredAt
        navigationSequence += 1

        var navigation = navigationMeasurement(
            for: result,
            sequence: navigationSequence,
            direction: direction,
            event: event,
            keyIntervalMilliseconds: keyIntervalMilliseconds
        )
        pendingNavigation = navigation
        selectedIndex = targetIndex

        navigation = pendingNavigation ?? navigation
        diagnostics.benchmark(
            "historyNavigation.selectionChanged",
            durationMilliseconds: DiagnosticsLog.elapsedMilliseconds(since: event.triggeredAt),
            details: navigationDetails(navigation)
        )
    }

    private func navigationMeasurement(
        for result: HistorySearchResult,
        sequence: Int,
        direction: String,
        event: NavigationKeyEvent,
        keyIntervalMilliseconds: Double?
    ) -> HistoryNavigationMeasurement {
        switch result {
        case .clipboard(let item):
            let contentCharacterCount: Int?
            let previewCharacterCount = item.textContent?.count ?? 0
            let bytes: Int
            let kind: String
            let storage: String

            switch item.type {
            case .text:
                kind = "clipboard_text"
                if item.isFileBacked {
                    storage = "file"
                    contentCharacterCount = nil
                } else if item.isTruncated {
                    storage = "truncated"
                    contentCharacterCount = nil
                } else {
                    storage = "inline"
                    contentCharacterCount = item.textContent?.count ?? 0
                }
                bytes = item.originalSizeBytes ?? item.textContent?.utf8.count ?? 0
            case .image:
                kind = "clipboard_image"
                storage = "file"
                contentCharacterCount = item.ocrText?.count
                bytes = item.originalSizeBytes ?? 0
            }

            return HistoryNavigationMeasurement(
                sequence: sequence,
                triggeredAt: event.triggeredAt,
                direction: direction,
                isRepeat: event.isRepeat,
                keyIntervalMilliseconds: keyIntervalMilliseconds,
                selectionID: .clipboard(item.id),
                kind: kind,
                storage: storage,
                contentCharacterCount: contentCharacterCount,
                previewCharacterCount: previewCharacterCount,
                bytes: bytes
            )
        case .snippet(let snippet):
            return HistoryNavigationMeasurement(
                sequence: sequence,
                triggeredAt: event.triggeredAt,
                direction: direction,
                isRepeat: event.isRepeat,
                keyIntervalMilliseconds: keyIntervalMilliseconds,
                selectionID: .snippet(snippet.id),
                kind: "snippet",
                storage: "inline",
                contentCharacterCount: snippet.content.count,
                previewCharacterCount: snippet.content.count,
                bytes: snippet.content.utf8.count
            )
        }
    }

    private func recordNavigationScrollRequested(
        selectionID: HistorySelectionID,
        scrollCallMilliseconds: Double
    ) {
        guard diagnostics.isEnabled else { return }
        guard var navigation = pendingNavigation,
              navigation.selectionID == selectionID,
              !navigation.didRequestScroll else { return }

        navigation.didRequestScroll = true
        pendingNavigation = navigation
        diagnostics.benchmark(
            "historyNavigation.scrollRequested",
            durationMilliseconds: DiagnosticsLog.elapsedMilliseconds(since: navigation.triggeredAt),
            details: "\(navigationDetails(navigation)) scroll_call_ms=\(DiagnosticsLog.format(scrollCallMilliseconds))"
        )
    }

    private func recordNavigationRowAppeared(sequence: Int) {
        guard diagnostics.isEnabled else { return }
        guard var navigation = pendingNavigation,
              navigation.sequence == sequence,
              !navigation.didShowSelectedRow else { return }

        navigation.didShowSelectedRow = true
        pendingNavigation = navigation
        diagnostics.benchmark(
            "historyNavigation.selectedRowAppeared",
            durationMilliseconds: DiagnosticsLog.elapsedMilliseconds(since: navigation.triggeredAt),
            details: navigationDetails(navigation)
        )
    }

    private func recordNavigationPreviewReady(
        selectionID: HistorySelectionID,
        bytes: Int,
        loadMilliseconds: Double
    ) {
        guard diagnostics.isEnabled else { return }
        guard var navigation = pendingNavigation,
              navigation.selectionID == selectionID,
              !navigation.didCompletePreview else { return }

        if bytes > 0 {
            navigation.bytes = bytes
        }
        navigation.didCompletePreview = true
        pendingNavigation = navigation
        diagnostics.benchmark(
            "historyNavigation.previewReady",
            durationMilliseconds: DiagnosticsLog.elapsedMilliseconds(since: navigation.triggeredAt),
            details: "\(navigationDetails(navigation)) load_ms=\(DiagnosticsLog.format(loadMilliseconds))"
        )

        let sequence = navigation.sequence
        DispatchQueue.main.async {
            guard var current = pendingNavigation,
                  current.sequence == sequence,
                  !current.didReachPreviewNextRunLoop else { return }

            current.didReachPreviewNextRunLoop = true
            pendingNavigation = current
            diagnostics.benchmark(
                "historyNavigation.previewNextRunLoop",
                durationMilliseconds: DiagnosticsLog.elapsedMilliseconds(since: current.triggeredAt),
                details: navigationDetails(current)
            )
        }
    }

    private func navigationDetails(_ navigation: HistoryNavigationMeasurement) -> String {
        let keyInterval = navigation.keyIntervalMilliseconds.map { DiagnosticsLog.format($0) } ?? "none"
        let contentCharacters = navigation.contentCharacterCount.map { String($0) } ?? "unknown"
        return "sequence=\(navigation.sequence) direction=\(navigation.direction) repeat=\(navigation.isRepeat) key_interval_ms=\(keyInterval) kind=\(navigation.kind) storage=\(navigation.storage) bytes=\(navigation.bytes) content_chars=\(contentCharacters) preview_chars=\(navigation.previewCharacterCount) stage=\(navigation.stage)"
    }

    private func navigateUp(event: NavigationKeyEvent) {
        if detailPaneMode == .imagePreview {
            return
        }

        if detailPaneMode == .quickActions {
            switch quickActionRoute {
            case .home:
                quickActionHomeSelection = max(quickActionHomeSelection - 1, 0)
            case .saveSnippet:
                break
            case .confirmation:
                quickActionConfirmationSelection = max(quickActionConfirmationSelection - 1, 0)
            }
            return
        }

        if selectedIndex > 0 {
            beginNavigation(to: selectedIndex - 1, direction: "up", event: event)
        }
    }
    
    private func navigateDown(event: NavigationKeyEvent) {
        if detailPaneMode == .imagePreview {
            return
        }

        if detailPaneMode == .quickActions {
            switch quickActionRoute {
            case .home:
                guard let item = selectedItem else { return }
                let maxIndex = max(quickActionOptions(for: item).count - 1, 0)
                quickActionHomeSelection = min(quickActionHomeSelection + 1, maxIndex)
            case .saveSnippet:
                break
            case .confirmation(let confirmation):
                let maxIndex = max(quickActionConfirmationChoices(for: confirmation).count - 1, 0)
                quickActionConfirmationSelection = min(quickActionConfirmationSelection + 1, maxIndex)
            }
            return
        }

        if selectedIndex < filteredResults.count - 1 {
            beginNavigation(to: selectedIndex + 1, direction: "down", event: event)
        }
    }

    private func navigateLeft() {
        switch detailPaneMode {
        case .imagePreview:
            closeDetailOverlay()
        case .quickActions:
            switch quickActionRoute {
            case .home:
                closeDetailOverlay()
            case .saveSnippet, .confirmation:
                returnToQuickActionsHome()
            }
        case .preview:
            break
        }
    }

    private func navigateRight() {
        switch detailPaneMode {
        case .preview:
            guard let item = selectedItem else { return }
            openQuickActions(for: item)
        case .quickActions:
            guard let item = selectedItem else { return }
            switch quickActionRoute {
            case .home:
                let options = quickActionOptions(for: item)
                guard options.indices.contains(quickActionHomeSelection) else { return }
                activateQuickAction(options[quickActionHomeSelection], for: item)
            case .saveSnippet:
                break
            case .confirmation(let confirmation):
                let choices = quickActionConfirmationChoices(for: confirmation)
                guard choices.indices.contains(quickActionConfirmationSelection) else { return }
                activateQuickActionConfirmation(
                    choices[quickActionConfirmationSelection],
                    confirmation: confirmation,
                    item: item
                )
            }
        case .imagePreview:
            break
        }
    }

    private func handleEscape() {
        switch detailPaneMode {
        case .imagePreview, .quickActions:
            navigateLeft()
        case .preview:
            onDismiss()
        }
    }

    private func closeDetailOverlay() {
        setDetailPaneMode(.preview)
        quickActionMessage = nil
        quickActionError = nil
    }

    private func setDetailPaneMode(_ mode: DetailPaneMode) {
        let wasImagePreview = detailPaneMode == .imagePreview
        detailPaneMode = mode
        let isImagePreview = mode == .imagePreview

        guard wasImagePreview != isImagePreview else { return }
        NotificationCenter.default.post(
            name: .bufferImagePreviewPresentationChanged,
            object: nil,
            userInfo: ["isPresented": isImagePreview]
        )
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private enum QuickActionFocusedField: Hashable {
    case snippetTrigger
}

/// Monitors global key events for the window
private struct NavigationKeyEvent {
    let triggeredAt: ContinuousClock.Instant
    let isRepeat: Bool
}

private struct GlobalKeyMonitor: NSViewRepresentable {
    let onUp: (NavigationKeyEvent) -> Void
    let onDown: (NavigationKeyEvent) -> Void
    let onLeft: () -> Void
    let onRight: () -> Void
    let onEnter: () -> Void
    let onEscape: () -> Void
    let onDelete: () -> Void
    let onCopy: () -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            // Add local monitor to window
            guard view.window != nil else { return }
            
            // We use a property on the window or controller to store the monitor
            // But for simplicity in SwiftUI, we'll use a weak ref approach here
            // or just rely on the view traversing up. 
            // Actually, best way is to add monitor to the window.
            
            let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch event.keyCode {
                case 126: // Up
                    onUp(NavigationKeyEvent(triggeredAt: .now, isRepeat: event.isARepeat))
                    return nil // Consume event
                case 125: // Down
                    onDown(NavigationKeyEvent(triggeredAt: .now, isRepeat: event.isARepeat))
                    return nil // Consume event
                case 123: // Left
                    onLeft()
                    return nil
                case 124: // Right
                    onRight()
                    return nil
                case 36: // Enter
                    onEnter()
                    return nil
                case 53: // Escape
                    onEscape()
                    return nil
                case 51: // Delete
                    // Check if search field is first responder - if so, don't consume delete unless empty?
                    // For now, let's assume Cmd+Delete or just Delete on list.
                    // If we consume Delete always, we can't delete text in search.
                    // So let's only consume if we are NOT editing text OR if modifier is used.
                    // But simpler: Only trigger if search text is empty? 
                    // Let's rely on Command+Delete for item deletion to be safe/standard
                    if event.modifierFlags.contains(.command) {
                        onDelete()
                        return nil
                    }
                    return event
                case 8: // C (for Copy)
                    if event.modifierFlags.contains(.command) {
                        // If text is selected in a text view, let the system handle native copy
                        if let responder = view.window?.firstResponder, responder is NSTextView {
                            return event
                        }
                        onCopy()
                        return nil
                    }
                    return event
                default:
                    return event
                }
            }
            
            // Store monitor to remove later? 
            // In a real app we need to clean up. For this snippet, 
            // the monitor lasts as long as the window is open.
            // Since the window is closed/released, the monitor should be cleaned up 
            // if we attached it to the window properly or if we remove it on dismantle.
            // However, NSEvent.addLocalMonitorForEvents returns an object that must be removed.
            
            context.coordinator.monitor = monitor
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var monitor: Any?
        
        deinit {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
