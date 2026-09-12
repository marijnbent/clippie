import AppKit
import Foundation
import ImageIO

final class ClipboardImageCache: @unchecked Sendable {
    private let imagesDirectory: URL
    private let thumbnailQueue = DispatchQueue(label: "com.clippie.thumbnails", qos: .userInitiated)
    private let thumbnailCache = NSCache<NSUUID, NSImage>()
    private let appIconCache = NSCache<NSString, NSImage>()

    init(imagesDirectory: URL) {
        self.imagesDirectory = imagesDirectory
        thumbnailCache.totalCostLimit = 8 * 1_024 * 1_024
        thumbnailCache.countLimit = 512
        appIconCache.countLimit = 128
    }

    func invalidateThumbnail(for id: UUID) {
        thumbnailCache.removeObject(forKey: id as NSUUID)
    }

    func removeAllThumbnails() {
        thumbnailCache.removeAllObjects()
    }

    func thumbnail(for item: ClipboardItem) async -> NSImage? {
        guard let filename = item.imageFilename, !Task.isCancelled else { return nil }
        let cancellation = ClipboardImageCancellation()
        let image: NSImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                thumbnailQueue.async { [self] in
                    guard !cancellation.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }
                    if let cached = thumbnailCache.object(forKey: item.id as NSUUID) {
                        continuation.resume(returning: cached)
                        return
                    }
                    let url = imagesDirectory.appendingPathComponent(filename)
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 56,
                            kCGImageSourceShouldCacheImmediately: true
                          ] as CFDictionary) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                    thumbnailCache.setObject(thumbnail, forKey: item.id as NSUUID, cost: image.bytesPerRow * image.height)
                    continuation.resume(returning: thumbnail)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        return Task.isCancelled ? nil : image
    }

    func sourceAppIcon(for item: ClipboardItem) async -> NSImage? {
        guard let identifier = item.sourceBundleIdentifier ?? item.sourceApp, !Task.isCancelled else { return nil }
        let key = (item.sourceBundleIdentifier == nil ? "name:" : "bundle:") + identifier
        let cancellation = ClipboardImageCancellation()
        let image: NSImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                thumbnailQueue.async { [self] in
                    guard !cancellation.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }
                    if let cached = appIconCache.object(forKey: key as NSString) {
                        continuation.resume(returning: cached)
                        return
                    }
                    let appURL = item.sourceBundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                        ?? NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == item.sourceApp })?.bundleURL
                    guard let appURL else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                    icon.size = NSSize(width: 16, height: 16)
                    appIconCache.setObject(icon, forKey: key as NSString)
                    continuation.resume(returning: icon)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        return Task.isCancelled ? nil : image
    }
}

private final class ClipboardImageCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
