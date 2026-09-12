import AppKit
import Foundation
import Testing
@testable import Clippie

@Test func selfWriteSuppressionMatchesOnlyTheRecordedChange() {
    var tracker = PasteboardChangeTracker(currentChangeCount: 10)

    tracker.recordSelfWrite(changeCount: 11)

    let shouldCaptureSelfWrite = tracker.shouldCapture(changeCount: 11)
    let shouldCaptureNextWrite = tracker.shouldCapture(changeCount: 12)

    #expect(!shouldCaptureSelfWrite)
    #expect(shouldCaptureNextWrite)
}

@Test func userCopyAfterAnUnobservedSelfWriteIsCaptured() {
    var tracker = PasteboardChangeTracker(currentChangeCount: 20)

    tracker.recordSelfWrite(changeCount: 21)

    let shouldCaptureUserWrite = tracker.shouldCapture(changeCount: 22)
    let shouldCaptureSameWriteAgain = tracker.shouldCapture(changeCount: 22)

    #expect(shouldCaptureUserWrite)
    #expect(!shouldCaptureSameWriteAgain)
}

@Test func unrecordedWriteIsCaptured() {
    var tracker = PasteboardChangeTracker(currentChangeCount: 30)

    let shouldCaptureWrite = tracker.shouldCapture(changeCount: 31)

    #expect(shouldCaptureWrite)
}

@Test func signaturesUseTheFullPayloadAndContentType() {
    let commonPrefix = String(repeating: "a", count: 10_000)
    let firstText = Data((commonPrefix + "x").utf8)
    let secondText = Data((commonPrefix + "y").utf8)

    #expect(ClipboardContentSignature.text(utf8Data: firstText) != .text(utf8Data: secondText))
    #expect(ClipboardContentSignature.text(utf8Data: firstText) != .image(pngData: firstText))
}

@Test func fullPreviewIsDeferredOnlyForLongOrFileBackedText() {
    #expect(!HistoryPreviewLoadingPolicy.shouldDeferFullTextPreview(characterCount: 1_000, isFileBacked: false))
    #expect(HistoryPreviewLoadingPolicy.shouldDeferFullTextPreview(characterCount: 1_001, isFileBacked: false))
    #expect(HistoryPreviewLoadingPolicy.shouldDeferFullTextPreview(characterCount: 20, isFileBacked: true))
}

@Test func exactSnippetWaitsOnlyWhenAnotherTriggerContinuesIt() {
    let exact = Snippet(title: "", trigger: "mail", content: "Personal email")
    let longer = Snippet(title: "", trigger: "mailwork", content: "Work email")
    let unrelated = Snippet(title: "", trigger: "email", content: "Other email")

    #expect(!SnippetExpansionPolicy.shouldAutoExpand(exact, among: [exact, longer]))
    #expect(SnippetExpansionPolicy.shouldAutoExpand(exact, among: [exact, unrelated]))
}

@Test func historyRowPreviewCollapsesWhitespaceAndKeepsWholeCharacters() {
    #expect(ClipboardItem.text("  one\t two\r\nthree  ").previewText == "one two three")
    #expect(ClipboardItem.text("\n\t ").previewText == "")
    #expect(ClipboardItem.image(filename: "unused.png").previewText == "Image")
    let emoji = String(repeating: "👨‍👩‍👧‍👦", count: 50)
    #expect(ClipboardItem.text(emoji + "  ").previewText == emoji)
    #expect(ClipboardItem.text(emoji + " next").previewText == emoji + "…")
    let prefix = String(repeating: "a", count: 49)
    #expect(ClipboardItem.text(prefix + "  next").previewText == prefix + " …")
}

@Test func fileBackedHistorySearchAndExportPreserveCompleteText() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ClipboardStore(storageDirectory: directory)
    let text = String(repeating: "Prefix ", count: 1_000) + "Café ending"
    let filename = try #require(store.saveText(Data(text.utf8)))
    let item = ClipboardItem.largeText(
        preview: "Prefix",
        filename: filename,
        originalSizeBytes: text.utf8.count,
        sourceApp: "Éditor"
    )
    store.items = [item]

    #expect(await store.combinedTextRepresentationForExport() == text)
    for query in ["CAFE", "editor", "text"] {
        let scan = store.search([item], normalizedQuery: ClipboardStore.normalizeSearchText(query))
        #expect(scan?.matches.map(\.id) == [item.id])
    }
    #expect(store.search([item], normalizedQuery: "missing")?.matches.isEmpty == true)
    let json = try #require(await store.combinedJSONRepresentationForExport())
    let exported = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
    #expect(exported?.first?["textContent"] as? String == text)
}

@Test func cancelledHistorySearchStopsBeforeScanningItems() async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ClipboardStore(storageDirectory: directory)
    let scan = await Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        return store.search([.text("needle")], normalizedQuery: "needle")
    }.value
    #expect(scan == nil)
}

@Test func historyRetentionRemovesOnlyExpiredItemsAndPersistsReordering() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let texts = directory.appendingPathComponent("texts")
    try FileManager.default.createDirectory(at: texts, withIntermediateDirectories: true)
    let expired = ClipboardItem(type: .text, timestamp: .distantPast, textContent: "old", textFilename: "old.txt")
    let first = ClipboardItem.text("first")
    let second = ClipboardItem.text("second")
    try Data("old".utf8).write(to: texts.appendingPathComponent("old.txt"))
    try JSONEncoder().encode([first, expired, second]).write(to: directory.appendingPathComponent("history.json"))

    let store = ClipboardStore(storageDirectory: directory)
    #expect(store.items.map(\.id) == [first.id, second.id])
    #expect(store.flushPendingHistorySave())
    #expect(!FileManager.default.fileExists(atPath: texts.appendingPathComponent("old.txt").path))
    store.moveToTop(second)
    store.flushPendingHistorySave()

    let saved = try JSONDecoder().decode([ClipboardItem].self, from: Data(contentsOf: directory.appendingPathComponent("history.json")))
    #expect(saved.map(\.id) == [second.id, first.id])
    #expect(saved.map(\.textContent) == ["second", "first"])
}

@Test @MainActor func failedHistoryWriteKeepsPayloadsUntilTheRetrySucceeds() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let texts = directory.appendingPathComponent("texts")
    try FileManager.default.createDirectory(at: texts, withIntermediateDirectories: true)
    let item = ClipboardItem.largeText(preview: "preview", filename: "saved.txt", originalSizeBytes: 4)
    let historyURL = directory.appendingPathComponent("history.json")
    let textURL = texts.appendingPathComponent("saved.txt")
    try Data("full".utf8).write(to: textURL)
    try JSONEncoder().encode([item]).write(to: historyURL)
    let control = ClipboardWriteControl(fails: true)
    let store = ClipboardStore(storageDirectory: directory, writeHistory: control.write)

    store.delete(item)
    #expect(!store.flushPendingHistorySave())
    #expect(FileManager.default.fileExists(atPath: textURL.path))
    #expect(try JSONDecoder().decode([ClipboardItem].self, from: Data(contentsOf: historyURL)).map(\.id) == [item.id])
    control.setFailure(false)
    #expect(store.flushPendingHistorySave())
    #expect(!FileManager.default.fileExists(atPath: textURL.path))
    #expect(try JSONDecoder().decode([ClipboardItem].self, from: Data(contentsOf: historyURL)).isEmpty)
    #expect(!control.wroteOnMainThread)
}

@Test @MainActor func terminationFlushRetriesATransientWriteFailure() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let control = ClipboardWriteControl(failuresRemaining: 1)
    let store = ClipboardStore(storageDirectory: directory, writeHistory: control.write)
    let item = ClipboardItem.text("latest")
    store.items = [item]
    #expect(store.flushPendingHistorySave())
    let saved = try JSONDecoder().decode([ClipboardItem].self, from: Data(contentsOf: directory.appendingPathComponent("history.json")))
    #expect(saved.map(\.id) == [item.id])
}

@Test @MainActor func queuedClearDeletesFilesOnlyAfterTheFinalHistoryIsSaved() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let texts = directory.appendingPathComponent("texts")
    try FileManager.default.createDirectory(at: texts, withIntermediateDirectories: true)
    let items = (0..<3).map { ClipboardItem.largeText(preview: "preview", filename: "\($0).txt", originalSizeBytes: 4) }
    for item in items {
        try Data("full".utf8).write(to: texts.appendingPathComponent(item.textFilename!))
    }
    let historyURL = directory.appendingPathComponent("history.json")
    try JSONEncoder().encode(items).write(to: historyURL)
    let control = ClipboardWriteControl(blocksFirstWrite: true)
    let store = ClipboardStore(storageDirectory: directory, writeHistory: control.write)
    store.delete(items[0])
    #expect(control.started.wait(timeout: .now() + 2) == .success)
    store.clear()
    #expect(try FileManager.default.contentsOfDirectory(atPath: texts.path).count == 3)
    control.allowWrite.signal()
    #expect(store.flushPendingHistorySave())
    #expect(try FileManager.default.contentsOfDirectory(atPath: texts.path).isEmpty)
    #expect(try JSONDecoder().decode([ClipboardItem].self, from: Data(contentsOf: historyURL)).isEmpty)
    #expect(!control.wroteOnMainThread)
}

@Test func preparedContentKeepsFullTextAndDoesNotUseAPreviewForAMissingFile() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ClipboardStore(storageDirectory: directory)
    let text = String(repeating: "Café 🌿 ", count: 5_000)
    let filename = try #require(store.saveText(Data(text.utf8)))
    let item = ClipboardItem.largeText(preview: "short", filename: filename, originalSizeBytes: text.utf8.count)
    #expect(try await store.prepareClipboardContent(for: item) == .text(text))
    let missing = ClipboardItem.largeText(preview: "partial", filename: "missing.txt", originalSizeBytes: 100)
    do {
        _ = try await store.prepareClipboardContent(for: missing)
        Issue.record("Missing full content was replaced by its preview")
    } catch {
        #expect(error is CocoaError)
    }
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await store.prepareClipboardContent(for: item)
    }
    do {
        _ = try await cancelled.value
        Issue.record("Cancelled preparation returned content")
    } catch {
        #expect(error is CancellationError)
    }
}

@Test func imagePreparationPreservesPixelsAndThumbnailReusesTheSmallImage() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 80, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.setColor(NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1), atX: 10, y: 10)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let store = ClipboardStore(storageDirectory: directory)
    let filename = try #require(store.saveImage(png))
    let item = ClipboardItem.image(filename: filename)
    let prepared = try await store.prepareClipboardContent(for: item)
    guard case .image(let preparedPNG, let tiff) = prepared else {
        Issue.record("Image preparation returned text")
        return
    }
    #expect(preparedPNG == png)
    let restored = try #require(NSBitmapImageRep(data: tiff))
    #expect(restored.pixelsWide == 160)
    #expect(restored.pixelsHigh == 80)
    #expect(restored.colorAt(x: 10, y: 10)?.redComponent == 1)
    let first = try #require(await store.imageCache.thumbnail(for: item))
    let second = try #require(await store.imageCache.thumbnail(for: item))
    #expect(first === second)
    #expect(first.size == NSSize(width: 56, height: 28))
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await store.imageCache.thumbnail(for: item)
    }
    #expect(await cancelled.value == nil)
}

private final class ClipboardWriteControl: @unchecked Sendable {
    private let lock = NSLock()
    private var fails: Bool
    private var failuresRemaining: Int
    private var blocksFirstWrite: Bool
    private var usedMainThread = false
    let started = DispatchSemaphore(value: 0)
    let allowWrite = DispatchSemaphore(value: 0)
    var wroteOnMainThread: Bool { lock.withLock { usedMainThread } }

    init(fails: Bool = false, blocksFirstWrite: Bool = false, failuresRemaining: Int = 0) {
        self.fails = fails
        self.failuresRemaining = failuresRemaining
        self.blocksFirstWrite = blocksFirstWrite
    }

    func setFailure(_ fails: Bool) { lock.withLock { self.fails = fails } }

    func write(_ data: Data, to url: URL) throws {
        let state = lock.withLock {
            usedMainThread = usedMainThread || Thread.isMainThread
            defer { blocksFirstWrite = false }
            let shouldFail = fails || failuresRemaining > 0
            failuresRemaining = max(0, failuresRemaining - 1)
            return (shouldFail, blocksFirstWrite)
        }
        if state.1 {
            started.signal()
            if allowWrite.wait(timeout: .now() + 5) != .success {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        if state.0 { throw CocoaError(.fileWriteNoPermission) }
        try data.write(to: url, options: .atomic)
    }
}
