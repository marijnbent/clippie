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
    #expect(!FileManager.default.fileExists(atPath: texts.appendingPathComponent("old.txt").path))
    store.moveToTop(second)
    store.flushPendingHistorySave()

    let saved = try JSONDecoder().decode([ClipboardItem].self, from: Data(contentsOf: directory.appendingPathComponent("history.json")))
    #expect(saved.map(\.id) == [second.id, first.id])
    #expect(saved.map(\.textContent) == ["second", "first"])
}
