import AppKit
import Combine
import CryptoKit
import Foundation

struct PasteboardChangeTracker {
    private(set) var lastObservedChangeCount: Int
    private var selfWriteChangeCounts: Set<Int> = []

    init(currentChangeCount: Int) {
        lastObservedChangeCount = currentChangeCount
    }

    mutating func recordSelfWrite(changeCount: Int) {
        guard changeCount > lastObservedChangeCount else { return }
        selfWriteChangeCounts.insert(changeCount)
    }

    mutating func shouldCapture(changeCount: Int) -> Bool {
        guard changeCount != lastObservedChangeCount else { return false }

        lastObservedChangeCount = changeCount
        let isSelfWrite = selfWriteChangeCounts.remove(changeCount) != nil
        selfWriteChangeCounts = selfWriteChangeCounts.filter { $0 > changeCount }
        return !isSelfWrite
    }

    mutating func reset(changeCount: Int) {
        lastObservedChangeCount = changeCount
        selfWriteChangeCounts.removeAll()
    }
}

struct ClipboardContentSignature: Equatable, Sendable {
    private enum Kind: UInt8 {
        case text = 1
        case image = 2
    }

    private let digest: [UInt8]

    static func text(utf8Data: Data) -> ClipboardContentSignature {
        ClipboardContentSignature(kind: .text, data: utf8Data)
    }

    static func image(pngData: Data) -> ClipboardContentSignature {
        ClipboardContentSignature(kind: .image, data: pngData)
    }

    private init(kind: Kind, data: Data) {
        var hasher = SHA256()
        hasher.update(data: Data([kind.rawValue]))

        var byteCount = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &byteCount) { bytes in
            hasher.update(data: Data(bytes))
        }

        hasher.update(data: data)
        digest = Array(hasher.finalize())
    }
}

private enum ClipboardImageData: Sendable {
    case png(Data)
    case tiff(Data)
}

private enum ClipboardPayload: Sendable {
    case text(String)
    case image(ClipboardImageData)
}

private struct ClipboardCapture: Sendable {
    let payload: ClipboardPayload
    let sourceApp: String?
    let sourceBundleIdentifier: String?
}

/// Monitors the system clipboard for changes and captures new content.
class ClipboardWatcher: ObservableObject {
    @Published private(set) var isPaused = false

    private let store: ClipboardStore
    private let processingQueue = DispatchQueue(label: "com.clippie.clipboard-processing", qos: .utility)
    private let pendingItemsLock = NSLock()
    private var pendingItems: [ClipboardItem] = []
    private var isPendingItemDeliveryScheduled = false
    private var timer: Timer?
    private var changeTracker: PasteboardChangeTracker
    private var lastContentSignature: ClipboardContentSignature?

    private let pollInterval: TimeInterval = 0.5
    private let inlineTextLimit = 10_000
    private let previewLength = 500

    init(store: ClipboardStore) {
        self.store = store
        changeTracker = PasteboardChangeTracker(currentChangeCount: NSPasteboard.general.changeCount)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePasteboardWrite(_:)),
            name: .bufferDidWritePasteboard,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handlePasteboardWrite(_ notification: Notification) {
        guard let changeCount = notification.object as? NSNumber else { return }
        changeTracker.recordSelfWrite(changeCount: changeCount.intValue)
    }

    func startWatching() {
        guard timer == nil else { return }

        timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }

        RunLoop.main.add(timer!, forMode: .common)
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    /// Finish captured clipboard work and apply its results before the history store is flushed.
    /// Processing never waits for the main queue, so this is safe to call during termination.
    func finishPendingProcessing() {
        processingQueue.sync {}
        deliverPendingItems()
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
        changeTracker.reset(changeCount: NSPasteboard.general.changeCount)
    }

    /// Pasteboard access stays on the main thread. Expensive processing uses a serial utility queue.
    private func checkClipboard() {
        guard !isPaused else { return }

        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount
        guard changeTracker.shouldCapture(changeCount: currentChangeCount) else { return }

        let payload: ClipboardPayload
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            payload = .text(text)
        } else if let pngData = pasteboard.data(forType: .png) {
            payload = .image(.png(pngData))
        } else if let tiffData = pasteboard.data(forType: .tiff) {
            payload = .image(.tiff(tiffData))
        } else {
            return
        }

        let sourceApplication = NSWorkspace.shared.frontmostApplication
        let capture = ClipboardCapture(
            payload: payload,
            sourceApp: sourceApplication?.localizedName,
            sourceBundleIdentifier: sourceApplication?.bundleIdentifier
        )

        processingQueue.async { [weak self] in
            self?.process(capture)
        }
    }

    private func process(_ capture: ClipboardCapture) {
        switch capture.payload {
        case .text(let text):
            processText(
                text,
                sourceApp: capture.sourceApp,
                sourceBundleIdentifier: capture.sourceBundleIdentifier
            )
        case .image(let imageData):
            processImage(
                imageData,
                sourceApp: capture.sourceApp,
                sourceBundleIdentifier: capture.sourceBundleIdentifier
            )
        }
    }

    private func processText(
        _ text: String,
        sourceApp: String?,
        sourceBundleIdentifier: String?
    ) {
        let utf8Data = Data(text.utf8)
        let signature = ClipboardContentSignature.text(utf8Data: utf8Data)
        guard signature != lastContentSignature else { return }

        let item: ClipboardItem
        if utf8Data.count <= inlineTextLimit {
            item = .text(
                text,
                sourceApp: sourceApp,
                sourceBundleIdentifier: sourceBundleIdentifier
            )
        } else {
            guard let filename = store.saveText(utf8Data) else { return }
            item = .largeText(
                preview: String(text.prefix(previewLength)),
                filename: filename,
                sourceApp: sourceApp,
                sourceBundleIdentifier: sourceBundleIdentifier
            )
            print("[clippie] Large text (\(utf8Data.count / 1024) KB) saved to file: \(filename)")
        }

        lastContentSignature = signature
        enqueueForDelivery(item)
    }

    private func processImage(
        _ imageData: ClipboardImageData,
        sourceApp: String?,
        sourceBundleIdentifier: String?
    ) {
        let pngData: Data
        switch imageData {
        case .png(let data):
            pngData = data
        case .tiff(let data):
            guard let convertedData = Self.convertTIFFToPNG(data) else { return }
            pngData = convertedData
        }

        let signature = ClipboardContentSignature.image(pngData: pngData)
        guard signature != lastContentSignature else { return }
        guard let filename = store.saveImage(pngData) else { return }

        let item = ClipboardItem.image(
            filename: filename,
            sourceApp: sourceApp,
            sourceBundleIdentifier: sourceBundleIdentifier
        )
        lastContentSignature = signature
        enqueueForDelivery(item)
    }

    private func enqueueForDelivery(_ item: ClipboardItem) {
        pendingItemsLock.lock()
        pendingItems.append(item)
        let shouldScheduleDelivery = !isPendingItemDeliveryScheduled
        if shouldScheduleDelivery {
            isPendingItemDeliveryScheduled = true
        }
        pendingItemsLock.unlock()

        guard shouldScheduleDelivery else { return }
        DispatchQueue.main.async { [weak self] in
            self?.deliverPendingItems()
        }
    }

    private func deliverPendingItems() {
        assert(Thread.isMainThread)

        pendingItemsLock.lock()
        let items = pendingItems
        pendingItems.removeAll(keepingCapacity: true)
        isPendingItemDeliveryScheduled = false
        pendingItemsLock.unlock()

        for item in items {
            store.add(item)
        }
    }

    private static func convertTIFFToPNG(_ data: Data) -> Data? {
        guard let bitmap = NSBitmapImageRep(data: data) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }
}
