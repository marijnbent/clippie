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
