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
        NotificationCenter.default.post(name: .bufferIgnoreNextChange, object: nil)
        PasteController.copyToClipboard(item, store: store)
    }
    
    private func copyTextToClipboard(_ text: String) {
        NotificationCenter.default.post(name: .bufferIgnoreNextChange, object: nil)
        PasteController.copyTextToClipboard(text)
    }
    
    private func pasteItem(_ item: ClipboardItem) {
        let targetApplication = targetApplicationForPaste
        store.moveToTop(item)
        close()
        NotificationCenter.default.post(name: .bufferIgnoreNextChange, object: nil)
        PasteController.paste(item, store: store, targetApplication: targetApplication)
    }
    
    private func pasteText(_ text: String) {
        let targetApplication = targetApplicationForPaste
        close()
        NotificationCenter.default.post(name: .bufferIgnoreNextChange, object: nil)
        PasteController.paste(text: text, targetApplication: targetApplication)
    }
    
    override func showWindow(_ sender: Any?) {
        captureCurrentTargetApplication()
        if !isPresentingImagePreview {
            window?.center()
        }
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(window?.contentView)
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
    static let bufferIgnoreNextChange = Notification.Name("bufferIgnoreNextChange")
    static let bufferHotkeyChanged = Notification.Name("bufferHotkeyChanged")
    static let bufferWindowDidOpen = Notification.Name("bufferWindowDidOpen")
    static let bufferHistoryLimitChanged = Notification.Name("bufferHistoryLimitChanged")
    static let bufferImagePreviewPresentationChanged = Notification.Name("bufferImagePreviewPresentationChanged")
}

private enum HistorySelectionID: Hashable {
    case clipboard(UUID)
    case snippet(UUID)
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
    case confirmDelete
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
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var backgroundColor: Color {
        if isSelected {
            return Color.primary.opacity(0.08)
        } else if isHovered {
            return Color.primary.opacity(0.05)
        }
        return Color.clear
    }

    private var backgroundCornerRadius: CGFloat {
        6
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(width: 18, height: 18)

                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
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

    @ObservedObject var store: ClipboardStore
    @StateObject private var snippetStore = SnippetStore.shared
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
    @State private var quickActionMessage: String?
    @State private var quickActionError: String?
    @State private var filteredClipboardItems: [ClipboardItem] = []
    @State private var clipboardSearchRevision = 0
    
    
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
            return item
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
        .task(id: selectedItem?.id) {
            // Clear preview
            resetQuickActionState()
            previewImage = nil
            chunkedText = ChunkedTextState()
            isExtractingText = false
            itemSize = nil
            
            // Load new preview async
            if let item = selectedItem {
                itemSize = store.itemSize(for: item)
                
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
            }
        }
        .background(GlobalKeyMonitor(
            onUp: {
                navigateUp()
            },
            onDown: {
                navigateDown()
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
                                proxy.scrollTo(result.id)
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
            if let item = selectedItem {
                VStack(spacing: 0) {
                    if detailPaneMode == .quickActions {
                        quickActionsPane(for: item)
                    } else if detailPaneMode == .imagePreview {
                        imagePreviewPane(for: item)
                    } else {
                        previewPane(for: item)
                    }
                }
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
                    case .confirmDelete:
                        quickActionDeletePane(for: item)
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
                    quickActionRoute = .home
                    quickActionFocusedField = nil
                    quickActionError = nil
                    quickActionMessage = nil
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

    private func quickActionDeletePane(for item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Warning block
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundColor(.red)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Remove from History")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Text("This clipboard item will be permanently removed. This cannot be undone.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.red.opacity(0.12), lineWidth: 1)
            )

            Button(role: .destructive) {
                deleteSelectedItem(item)
            } label: {
                Text("Delete")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
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
            quickActionRoute = .confirmDelete
        }
    }

    private func resetQuickActionState() {
        setDetailPaneMode(.preview)
        quickActionRoute = .home
        quickActionHomeSelection = 0
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
        let normalizedQuery = ClipboardStore.normalizeSearchText(query)

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.searchDebounceDelay) {
            let matches = items.filter { item in
                store.matchesSearch(item, normalizedQuery: normalizedQuery)
            }

            DispatchQueue.main.async {
                guard revision == clipboardSearchRevision else { return }
                filteredClipboardItems = matches
                syncSelection()
            }
        }
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
        case .confirmDelete:
            quickActionFocusedField = nil
            break
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
            quickActionError = "Couldn't load this image."
            quickActionMessage = nil
            return
        }

        setDetailPaneMode(.quickActions)
        quickActionRoute = .home
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
                quickActionMessage = resolvedText == "No text found in this image."
                    ? resolvedText
                    : "OCR text is ready."
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
            case .confirmDelete:
                deleteSelectedItem(item)
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
                                NotificationCenter.default.post(name: .bufferIgnoreNextChange, object: nil)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(ocrText, forType: .string)
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
    
    private func navigateUp() {
        if detailPaneMode == .imagePreview {
            return
        }

        if detailPaneMode == .quickActions {
            switch quickActionRoute {
            case .home:
                quickActionHomeSelection = max(quickActionHomeSelection - 1, 0)
            case .saveSnippet, .confirmDelete:
                break
            }
            return
        }

        if selectedIndex > 0 {
            scrollTrigger = true
            selectedIndex -= 1
        }
    }
    
    private func navigateDown() {
        if detailPaneMode == .imagePreview {
            return
        }

        if detailPaneMode == .quickActions {
            switch quickActionRoute {
            case .home:
                guard let item = selectedItem else { return }
                let maxIndex = max(quickActionOptions(for: item).count - 1, 0)
                quickActionHomeSelection = min(quickActionHomeSelection + 1, maxIndex)
            case .saveSnippet, .confirmDelete:
                break
            }
            return
        }

        if selectedIndex < filteredResults.count - 1 {
            scrollTrigger = true
            selectedIndex += 1
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
            case .saveSnippet, .confirmDelete:
                quickActionRoute = .home
                quickActionFocusedField = nil
                quickActionMessage = nil
                quickActionError = nil
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
            guard quickActionRoute == .home, let item = selectedItem else { return }
            let options = quickActionOptions(for: item)
            guard options.indices.contains(quickActionHomeSelection) else { return }
            activateQuickAction(options[quickActionHomeSelection], for: item)
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
struct GlobalKeyMonitor: NSViewRepresentable {
    let onUp: () -> Void
    let onDown: () -> Void
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
                    onUp()
                    return nil // Consume event
                case 125: // Down
                    onDown()
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
