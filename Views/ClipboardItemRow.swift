import SwiftUI

/// Single row displaying a clipboard item - optimized for smooth scrolling
struct ClipboardItemRow: View {
    let item: ClipboardItem
    let store: ClipboardStore
    let isSelected: Bool
    
    @State private var isHovered = false
    @State private var thumbnail: NSImage?
    @State private var sourceAppIcon: NSImage?
    
    private var backgroundColor: Color {
        if isSelected {
            // Slightly more saturated than 0.25 so selected items read clearly
            // without feeling garish — pairs well with the accent strip
            return Color.accentColor.opacity(0.15)
        } else if isHovered {
            return Color.primary.opacity(0.05)
        }
        return Color.clear
    }

    private var backgroundCornerRadius: CGFloat {
        isSelected ? 0 : 4
    }
    
    var body: some View {
        HStack(spacing: 12) {
            if item.type == .image {
                icon
                    .frame(width: 28, height: 28)
            }

            // Slightly larger text with a bit more air so the list reads more comfortably.
            Text(item.previewText)
                .font(.system(size: 14))
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)

            // Source app icon — 16pt keeps it from competing with content
            if let app = item.sourceApp {
                Group {
                    if let icon = sourceAppIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .opacity(0.85)
                    } else {
                        Image(systemName: "app.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.4))
                    }
                }
                .frame(width: 18, height: 18)
                .help(app)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // Use a shaped background so the fill is explicitly rounded — avoids
        // potential clipping artefacts from stacking .background + .cornerRadius
        .background(
            backgroundColor,
            in: RoundedRectangle(cornerRadius: backgroundCornerRadius, style: .continuous)
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .task(id: item.id) {
            sourceAppIcon = nil
            if item.sourceBundleIdentifier != nil || item.sourceApp != nil {
                sourceAppIcon = await loadSourceAppIcon()
            }
            
            // Load thumbnail async off main thread
            if item.type == .image && thumbnail == nil {
                thumbnail = await loadThumbnail()
            }
        }
    }
    
    @ViewBuilder
    private var icon: some View {
        if item.type == .image {
            if let img = thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 28, height: 28)
            }
        }
    }
    
    /// Generate a small thumbnail asynchronously
    private func loadThumbnail() async -> NSImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let original = store.image(for: item) else {
                    continuation.resume(returning: nil)
                    return
                }
                
                // Create a tiny thumbnail (40x40 for retina)
                let thumbSize = NSSize(width: 56, height: 56)
                let thumb = NSImage(size: thumbSize)
                thumb.lockFocus()
                original.draw(
                    in: NSRect(origin: .zero, size: thumbSize),
                    from: NSRect(origin: .zero, size: original.size),
                    operation: .copy,
                    fraction: 1.0
                )
                thumb.unlockFocus()
                
                continuation.resume(returning: thumb)
            }
        }
    }

    private func loadSourceAppIcon() async -> NSImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                if let bundleIdentifier = item.sourceBundleIdentifier,
                   let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                    let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                    icon.size = NSSize(width: 16, height: 16)
                    continuation.resume(returning: icon)
                    return
                }

                if let appName = item.sourceApp,
                   let runningApp = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }),
                   let appURL = runningApp.bundleURL {
                    let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                    icon.size = NSSize(width: 16, height: 16)
                    continuation.resume(returning: icon)
                    return
                }

                continuation.resume(returning: nil)
            }
        }
    }
}
