import Foundation
import AppKit
import Combine

struct ClipboardTextChunkSource: Sendable {
    let fileURL: URL?
    let inlineText: String
    let originalSizeBytes: Int?
}

private struct ClipboardExportItem: Encodable {
    let id: UUID
    let type: ClipboardItemType
    let timestamp: Date
    let sourceApp: String?
    let sourceBundleIdentifier: String?
    let textContent: String?
    let imageFilename: String?
    let ocrText: String?
    let isTruncated: Bool
    let originalSizeBytes: Int?
}

/// Manages persistent storage of clipboard history
class ClipboardStore: ObservableObject {
    @Published var items: [ClipboardItem] = []
    
    private let fileManager = FileManager.default
    private let saveQueue = DispatchQueue(label: "com.clippie.save", qos: .utility)
    private let saveStateLock = NSLock()
    private var pendingHistorySnapshot: [ClipboardItem]?
    private var isHistorySaveWorkerRunning = false
    private let fullTextCacheQueue = DispatchQueue(
        label: "com.clippie.file-text-cache",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let fileTextSearchCacheQueue = DispatchQueue(
        label: "com.clippie.file-text-search-cache",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private var fullTextCache: [UUID: String] = [:]
    private var fileTextSearchCache: [UUID: String] = [:]
    
    private var storageDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("clippie", isDirectory: true)
    }

    private var legacyStorageDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Buffer", isDirectory: true)
    }
    
    private var historyFileURL: URL {
        storageDirectory.appendingPathComponent("history.json")
    }
    
    private var imagesDirectory: URL {
        storageDirectory.appendingPathComponent("images", isDirectory: true)
    }
    
    private var textsDirectory: URL {
        storageDirectory.appendingPathComponent("texts", isDirectory: true)
    }
    
    init() {
        migrateLegacyStorageIfNeeded()
        ensureDirectoriesExist()
        loadHistory()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLimitChanged),
            name: .bufferHistoryLimitChanged,
            object: nil
        )
    }

    private func migrateLegacyStorageIfNeeded() {
        let legacyURL = legacyStorageDirectory
        let currentURL = storageDirectory

        guard legacyURL != currentURL else { return }
        guard fileManager.fileExists(atPath: legacyURL.path) else { return }
        guard !fileManager.fileExists(atPath: currentURL.path) else { return }

        do {
            try fileManager.createDirectory(at: currentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: legacyURL, to: currentURL)
        } catch {
            print("[clippie] Failed to migrate legacy storage: \(error)")
        }
    }
    
    @objc private func handleLimitChanged() {
        applyHistoryRetention()
    }
    
    // MARK: - Public API
    
    func add(_ item: ClipboardItem) {
        // Must be called on main thread for SwiftUI updates
        if Thread.isMainThread {
            performAdd(item)
        } else {
            DispatchQueue.main.sync {
                performAdd(item)
            }
        }
    }
    
    private func performAdd(_ item: ClipboardItem) {
        print("[clippie] Store: Adding item, current count: \(items.count)")
        invalidateCachedFullText(for: item.id)
        invalidateCachedSearchText(for: item.id)
        
        // Insert at beginning (newest first)
        items.insert(item, at: 0)
        
        applyHistoryRetention(persist: false)
        
        print("[clippie] Store: New count: \(items.count)")
        
        scheduleHistorySave(items)
    }
    
    func delete(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        invalidateCachedFullText(for: item.id)
        invalidateCachedSearchText(for: item.id)
        deleteAssociatedFiles(for: item)
        
        scheduleHistorySave(items)
    }
    
    /// Save extracted OCR text for an image item
    func setOCRText(_ text: String, for item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        guard items[index].ocrText != text else { return }

        var updatedItems = items
        updatedItems[index].ocrText = text
        items = updatedItems
        
        scheduleHistorySave(updatedItems)
    }
    
    /// Mark an existing item as recently reused so it becomes the newest history entry.
    func moveToTop(_ item: ClipboardItem, timestamp: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }

        var updatedItem = items.remove(at: index)
        updatedItem = ClipboardItem(
            id: updatedItem.id,
            type: updatedItem.type,
            timestamp: timestamp,
            sourceApp: updatedItem.sourceApp,
            sourceBundleIdentifier: updatedItem.sourceBundleIdentifier,
            textContent: updatedItem.textContent,
            textFilename: updatedItem.textFilename,
            imageFilename: updatedItem.imageFilename,
            ocrText: updatedItem.ocrText,
            isTruncated: updatedItem.isTruncated,
            originalSizeBytes: updatedItem.originalSizeBytes
        )
        items.insert(updatedItem, at: 0)

        scheduleHistorySave(items)
    }
    
    func clear() {
        // Delete all associated files
        for item in items {
            deleteAssociatedFiles(for: item)
        }
        items.removeAll()
        clearCachedFullText()
        clearCachedSearchText()
        
        scheduleHistorySave([])
    }

    var hasImagesOrLargeText: Bool {
        items.contains(where: isImageOrLargeText)
    }

    func deleteImagesAndLargeText() {
        let removed = items.filter(isImageOrLargeText)
        guard !removed.isEmpty else { return }

        let removedIDs = Set(removed.map(\.id))
        items.removeAll { removedIDs.contains($0.id) }

        for item in removed {
            invalidateCachedFullText(for: item.id)
            invalidateCachedSearchText(for: item.id)
            deleteAssociatedFiles(for: item)
        }

        scheduleHistorySave(items)
    }

    func combinedTextRepresentation() -> String {
        items
            .map { item in
                switch item.type {
                case .text:
                    return fullText(for: item) ?? item.textContent ?? ""
                case .image:
                    return "Image"
                }
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    func combinedTextRepresentationForExport() async -> String {
        var exportedItems: [String] = []

        for item in items {
            switch item.type {
            case .text:
                if let text = await cachedPreviewText(for: item), !text.isEmpty {
                    exportedItems.append(text)
                }
            case .image:
                exportedItems.append("Image")
            }
        }

        return exportedItems.joined(separator: "\n\n")
    }

    func combinedJSONRepresentation() -> String? {
        let exportItems = items.map { item in
            ClipboardExportItem(
                id: item.id,
                type: item.type,
                timestamp: item.timestamp,
                sourceApp: item.sourceApp,
                sourceBundleIdentifier: item.sourceBundleIdentifier,
                textContent: item.type == .text ? (fullText(for: item) ?? item.textContent) : nil,
                imageFilename: item.imageFilename,
                ocrText: item.ocrText,
                isTruncated: item.isTruncated,
                originalSizeBytes: item.originalSizeBytes
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(exportItems)
            return String(data: data, encoding: .utf8)
        } catch {
            print("[clippie] Failed to encode clipboard export JSON: \(error)")
            return nil
        }
    }

    func combinedJSONRepresentationForExport() async -> String? {
        var exportItems: [ClipboardExportItem] = []

        for item in items {
            exportItems.append(
                ClipboardExportItem(
                    id: item.id,
                    type: item.type,
                    timestamp: item.timestamp,
                    sourceApp: item.sourceApp,
                    sourceBundleIdentifier: item.sourceBundleIdentifier,
                    textContent: item.type == .text ? await cachedPreviewText(for: item) : nil,
                    imageFilename: item.imageFilename,
                    ocrText: item.ocrText,
                    isTruncated: item.isTruncated,
                    originalSizeBytes: item.originalSizeBytes
                )
            )
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601

                do {
                    let data = try encoder.encode(exportItems)
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                } catch {
                    print("[clippie] Failed to encode clipboard export JSON: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    func image(for item: ClipboardItem) -> NSImage? {
        guard item.type == .image, let filename = item.imageFilename else { return nil }
        let url = imagesDirectory.appendingPathComponent(filename)
        return NSImage(contentsOf: url)
    }
    
    func saveImage(_ data: Data) -> String? {
        let filename = UUID().uuidString + ".png"
        let url = imagesDirectory.appendingPathComponent(filename)
        
        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            print("[clippie] Failed to save image: \(error)")
            return nil
        }
    }
    
    /// Save large text to a file and return the filename
    func saveText(_ utf8Data: Data) -> String? {
        let filename = UUID().uuidString + ".txt"
        let url = textsDirectory.appendingPathComponent(filename)
        
        do {
            try utf8Data.write(to: url, options: .atomic)
            return filename
        } catch {
            print("[clippie] Failed to save text file: \(error)")
            return nil
        }
    }
    
    /// Load full text content from file (lazy loading for large text)
    func fullText(for item: ClipboardItem) -> String? {
        guard item.type == .text else { return nil }
        guard item.textFilename != nil else { return item.textContent }
        return cachedFullText(for: item) ?? item.textContent
    }

    func cachedPreviewText(for item: ClipboardItem) async -> String? {
        guard item.type == .text else { return nil }
        guard let filename = item.textFilename else { return item.textContent }

        if let cached = cachedFullText(for: item) {
            return cached
        }

        let url = textsDirectory.appendingPathComponent(filename)
        let loadedText: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    continuation.resume(returning: text)
                } catch {
                    print("[clippie] Failed to load text file: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }

        if let loadedText {
            cacheFullText(loadedText, for: item.id)
            return loadedText
        }

        return item.textContent
    }

    func matchesSearch(_ item: ClipboardItem, normalizedQuery: String) -> Bool {
        guard !normalizedQuery.isEmpty else { return true }

        if Self.normalizeSearchText(item.type.rawValue).contains(normalizedQuery) {
            return true
        }

        switch item.type {
        case .text:
            if let inlineText = item.textContent,
               Self.normalizeSearchText(inlineText).contains(normalizedQuery) {
                return true
            }

            if item.isFileBacked,
               let fullText = normalizedFullTextForSearch(for: item),
               fullText.contains(normalizedQuery) {
                return true
            }
        case .image:
            if let ocrText = item.ocrText,
               Self.normalizeSearchText(ocrText).contains(normalizedQuery) {
                return true
            }
        }

        if let sourceApp = item.sourceApp,
           Self.normalizeSearchText(sourceApp).contains(normalizedQuery) {
            return true
        }

        return false
    }

    static func normalizeSearchText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
    
    /// Load a chunk of text content, reading only what's necessary
    func textChunk(for item: ClipboardItem, charCount: Int) -> (text: String, totalBytes: Int, reachedEOF: Bool)? {
        Self.readTextChunk(from: textChunkSource(for: item), charCount: charCount)
    }

    func textChunkSource(for item: ClipboardItem) -> ClipboardTextChunkSource {
        if let filename = item.textFilename {
            return ClipboardTextChunkSource(
                fileURL: textsDirectory.appendingPathComponent(filename),
                inlineText: "",
                originalSizeBytes: item.originalSizeBytes
            )
        } else {
            return ClipboardTextChunkSource(
                fileURL: nil,
                inlineText: item.textContent ?? "",
                originalSizeBytes: item.originalSizeBytes
            )
        }
    }

    static func readTextChunk(from source: ClipboardTextChunkSource, charCount: Int) -> (text: String, totalBytes: Int, reachedEOF: Bool)? {
        if let url = source.fileURL {
            // File-backed large text
            do {
                // Get total size from attributes without reading file
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let totalBytes = attributes[.size] as? Int ?? 0
                
                // Read a chunk that should contain enough characters
                // UTF-8 can be up to 4 bytes per character, so we read charCount * 4
                // to guarantee we have enough bytes for the requested characters
                let maximumBytesToRead = min(charCount * 4, totalBytes)
                
                let fileHandle = try FileHandle(forReadingFrom: url)
                defer { try? fileHandle.close() }
                
                let data = try fileHandle.read(upToCount: maximumBytesToRead) ?? Data()
                
                // Decode to string and take exact requested characters
                let fullChunkStr = String(decoding: data, as: UTF8.self)
                let exactChunkStr = String(fullChunkStr.prefix(charCount))
                
                // If the decoded string length is less than requested, we hit EOF
                let reachedEOF = fullChunkStr.count < charCount
                
                return (exactChunkStr, totalBytes, reachedEOF)
                
            } catch {
                print("[clippie] Failed to read text chunk: \(error)")
                return nil
            }
        } else {
            // Inline text
            let content = source.inlineText
            let totalBytes = source.originalSizeBytes ?? content.utf8.count
            
            let prefix = String(content.prefix(charCount))
            let reachedEOF = content.count <= charCount
            
            return (prefix, totalBytes, reachedEOF)
        }
    }
    
    /// Get the total size of an item (in bytes) for UI display
    func itemSize(for item: ClipboardItem) -> Int? {
        if let original = item.originalSizeBytes {
            return original
        }
        
        switch item.type {
        case .text:
            if let filename = item.textFilename {
                let url = textsDirectory.appendingPathComponent(filename)
                let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                return attributes?[.size] as? Int
            } else {
                return item.textContent?.utf8.count
            }
        case .image:
            if let filename = item.imageFilename {
                let url = imagesDirectory.appendingPathComponent(filename)
                let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                return attributes?[.size] as? Int
            }
        }
        return nil
    }
    
    // MARK: - Private
    
    private func ensureDirectoriesExist() {
        try? fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: textsDirectory, withIntermediateDirectories: true)
    }
    
    private func loadHistory() {
        guard fileManager.fileExists(atPath: historyFileURL.path) else { 
            print("[clippie] No history file found")
            return 
        }
        
        do {
            let data = try Data(contentsOf: historyFileURL)
            let loadedItems = try JSONDecoder().decode([ClipboardItem].self, from: data)
            let retentionResult = applyingHistoryRetention(to: loadedItems)
            clearCachedFullText()
            clearCachedSearchText()
            self.items = retentionResult.retained
            retentionResult.removed.forEach(deleteAssociatedFiles(for:))
            if !retentionResult.removed.isEmpty {
                scheduleHistorySave(retentionResult.retained)
            }
            print("[clippie] Loaded \(retentionResult.retained.count) items from history")
        } catch {
            print("[clippie] Failed to load history: \(error)")
        }
    }
    
    /// Wait for the newest history snapshot to reach disk. Call this during app termination.
    func flushPendingHistorySave() {
        scheduleHistorySave(items)
        saveQueue.sync {}
    }

    private func scheduleHistorySave(_ snapshot: [ClipboardItem]) {
        saveStateLock.lock()
        pendingHistorySnapshot = snapshot
        let shouldStartWorker = !isHistorySaveWorkerRunning
        if shouldStartWorker {
            isHistorySaveWorkerRunning = true
        }
        saveStateLock.unlock()

        guard shouldStartWorker else { return }
        saveQueue.async { [self] in
            drainPendingHistorySaves()
        }
    }

    private func drainPendingHistorySaves() {
        while let snapshot = takePendingHistorySnapshot() {
            saveHistoryToDisk(snapshot)
        }
    }

    private func takePendingHistorySnapshot() -> [ClipboardItem]? {
        saveStateLock.lock()
        defer { saveStateLock.unlock() }

        guard let snapshot = pendingHistorySnapshot else {
            isHistorySaveWorkerRunning = false
            return nil
        }

        pendingHistorySnapshot = nil
        return snapshot
    }

    private func saveHistoryToDisk(_ itemsToSave: [ClipboardItem]) {
        do {
            let data = try JSONEncoder().encode(itemsToSave)
            try data.write(to: historyFileURL, options: .atomic)
        } catch {
            print("[clippie] Failed to save history: \(error)")
        }
    }
    
    private func deleteImageFile(for item: ClipboardItem) {
        guard item.type == .image, let filename = item.imageFilename else { return }
        let url = imagesDirectory.appendingPathComponent(filename)
        try? fileManager.removeItem(at: url)
    }
    
    private func deleteTextFile(for item: ClipboardItem) {
        guard let filename = item.textFilename else { return }
        let url = textsDirectory.appendingPathComponent(filename)
        try? fileManager.removeItem(at: url)
    }
    
    /// Delete all associated files (images and text files) for an item
    private func deleteAssociatedFiles(for item: ClipboardItem) {
        deleteImageFile(for: item)
        deleteTextFile(for: item)
    }

    private func isImageOrLargeText(_ item: ClipboardItem) -> Bool {
        item.type == .image || item.isFileBacked || item.isTruncated
    }

    private func normalizedFullTextForSearch(for item: ClipboardItem) -> String? {
        guard let filename = item.textFilename else {
            return item.textContent.map(Self.normalizeSearchText)
        }

        if let cached = cachedSearchText(for: item.id) {
            return cached
        }

        do {
            let text = try loadFullTextFromDisk(filename: filename)
            let normalizedText = Self.normalizeSearchText(text)
            cacheSearchText(normalizedText, for: item.id)
            return normalizedText
        } catch {
            print("[clippie] Failed to load text for search: \(error)")
            return item.textContent.map(Self.normalizeSearchText)
        }
    }

    private func cachedSearchText(for id: UUID) -> String? {
        fileTextSearchCacheQueue.sync {
            fileTextSearchCache[id]
        }
    }

    private func cachedFullText(for item: ClipboardItem) -> String? {
        fullTextCacheQueue.sync {
            fullTextCache[item.id]
        } ?? loadAndCacheFullText(for: item)
    }

    private func loadAndCacheFullText(for item: ClipboardItem) -> String? {
        guard let filename = item.textFilename else {
            return item.textContent
        }

        do {
            let text = try loadFullTextFromDisk(filename: filename)
            cacheFullText(text, for: item.id)
            return text
        } catch {
            print("[clippie] Failed to load text file: \(error)")
            return item.textContent
        }
    }

    private func loadFullTextFromDisk(filename: String) throws -> String {
        let url = textsDirectory.appendingPathComponent(filename)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func cacheFullText(_ text: String, for id: UUID) {
        fullTextCacheQueue.async(flags: .barrier) {
            self.fullTextCache[id] = text
        }
    }

    private func cacheSearchText(_ text: String, for id: UUID) {
        fileTextSearchCacheQueue.async(flags: .barrier) {
            self.fileTextSearchCache[id] = text
        }
    }

    private func invalidateCachedFullText(for id: UUID) {
        fullTextCacheQueue.async(flags: .barrier) {
            self.fullTextCache.removeValue(forKey: id)
        }
    }

    private func invalidateCachedSearchText(for id: UUID) {
        fileTextSearchCacheQueue.async(flags: .barrier) {
            self.fileTextSearchCache.removeValue(forKey: id)
        }
    }

    private func clearCachedFullText() {
        fullTextCacheQueue.async(flags: .barrier) {
            self.fullTextCache.removeAll()
        }
    }

    private func clearCachedSearchText() {
        fileTextSearchCacheQueue.async(flags: .barrier) {
            self.fileTextSearchCache.removeAll()
        }
    }

    private func applyHistoryRetention(persist: Bool = true) {
        let retentionResult = applyingHistoryRetention(to: items)
        guard retentionResult.removed.isEmpty == false else { return }

        retentionResult.removed.forEach(deleteAssociatedFiles(for:))
        retentionResult.removed.forEach { invalidateCachedFullText(for: $0.id) }
        retentionResult.removed.forEach { invalidateCachedSearchText(for: $0.id) }
        items = retentionResult.retained

        guard persist else { return }
        scheduleHistorySave(retentionResult.retained)
    }

    private func applyingHistoryRetention(to items: [ClipboardItem], referenceDate: Date = Date()) -> (retained: [ClipboardItem], removed: [ClipboardItem]) {
        let cutoffDate = SettingsManager.shared.historyLimit.cutoffDate(relativeTo: referenceDate)
        let retained = items.filter { $0.timestamp >= cutoffDate }
        let removedIDs = Set(retained.map(\.id))
        let removed = items.filter { !removedIDs.contains($0.id) }
        return (retained, removed)
    }
}
