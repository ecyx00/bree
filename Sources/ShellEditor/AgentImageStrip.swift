import AppKit
import CmuxFoundation
import ImageIO
import SwiftUI

/// One image Claude saved for a session (`.../<session_id>/images/<N>.png`).
struct AgentImageEntry: Equatable, Sendable, Identifiable {
    let url: URL
    /// The numeric file stem (`Image #N`), nil for non-numeric names.
    let number: Int?
    let modified: Date

    var id: String { url.path }
    private var label: String { number.map(String.init) ?? url.deletingPathExtension().lastPathComponent }
    var title: String {
        String(format: String(localized: "agentImageStrip.title", defaultValue: "Image #%@"), label)
    }
    var accessibilityTitle: String {
        String(format: String(localized: "agentImageStrip.accessibility", defaultValue: "Image %@"), label)
    }
}

enum AgentImageDiscovery {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    static func defaultRoot() -> URL {
        URL(fileURLWithPath: "/private/tmp/claude-\(getuid())", isDirectory: true)
    }

    /// Lists `<root>/*/<sessionID>/images/*`, keeps image extensions, sorts by the numeric stem
    /// (non-numeric names last, by name). Blocking file I/O: call off the main thread.
    static func discover(root: URL = defaultRoot(), sessionID: String) -> [AgentImageEntry] {
        guard !sessionID.isEmpty, !sessionID.contains("/") else { return [] }
        let fm = FileManager.default
        let projects = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var entries: [AgentImageEntry] = []
        for project in projects {
            let dir = project.appendingPathComponent(sessionID, isDirectory: true)
                .appendingPathComponent("images", isDirectory: true)
            let files = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            for file in files where imageExtensions.contains(file.pathExtension.lowercased()) {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                entries.append(AgentImageEntry(
                    url: file,
                    number: Int(file.deletingPathExtension().lastPathComponent),
                    modified: modified
                ))
            }
        }
        return sorted(entries)
    }

    static func sorted(_ entries: [AgentImageEntry]) -> [AgentImageEntry] {
        entries.sorted { a, b in
            switch (a.number, b.number) {
            case let (x?, y?): return x != y ? x < y : a.url.path < b.url.path
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.url.lastPathComponent < b.url.lastPathComponent
            }
        }
    }
}

private enum AgentThumbnailCache {
    static let cache = NSCache<NSString, NSImage>()
    static let displayHeight: CGFloat = 36
    static let maxWidth: CGFloat = 64

    /// Downsampled thumbnail keyed by path + modification date. Blocking: call off the main thread.
    static func thumbnail(for entry: AgentImageEntry) -> NSImage? {
        let key = "\(entry.url.path)|\(entry.modified.timeIntervalSince1970)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(entry.url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(displayHeight * 2 * 2),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Bottom-dock strip of the images pasted into the Claude session bound to a terminal panel.
/// Renders nothing until the session has at least one image.
struct AgentImageStrip: View {
    let surfaceID: UUID
    @ObservedObject private var lens = AgentLensStore.shared
    @State private var images: [AgentImageEntry] = []

    private var sessionID: String? {
        lens.cards.filter { $0.surfaceID == surfaceID && $0.claudeSessionID != nil }
            .max { $0.lastEventAt < $1.lastEventAt }?.claudeSessionID
    }

    var body: some View {
        Group {
            if images.isEmpty {
                Color.clear.frame(width: 0, height: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(images) { entry in
                                AgentImageThumbnail(entry: entry) {
                                    TextBoxAttachmentQuickLookController.shared.present(
                                        entries: images.map { (url: $0.url, title: $0.title) },
                                        selectedIndex: images.firstIndex(of: entry) ?? 0
                                    )
                                }
                                .id(entry.id)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                    }
                    .frame(height: AgentThumbnailCache.displayHeight + 4)
                    .onAppear { scrollToNewest(proxy) }
                    .onChange(of: images.last?.id) { _ in scrollToNewest(proxy) }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        .task(id: sessionID) {
            guard let sessionID else {
                if !images.isEmpty { images = [] }
                return
            }
            var logged = false
            while !Task.isCancelled {
                let found = await Task.detached(priority: .utility) {
                    AgentImageDiscovery.discover(sessionID: sessionID)
                }.value
                if found != images { images = found }
                #if DEBUG
                if !logged {
                    logged = true
                    cmuxDebugLog("agentImageStrip.load session=\(sessionID.prefix(8)) images=\(found.count)")
                }
                #endif
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func scrollToNewest(_ proxy: ScrollViewProxy) {
        guard let last = images.last else { return }
        proxy.scrollTo(last.id, anchor: .trailing)
    }
}

private struct AgentImageThumbnail: View {
    let entry: AgentImageEntry
    let onOpen: () -> Void
    @State private var image: NSImage?
    @State private var hovering = false
    @Environment(\.breePalette) private var palette

    var body: some View {
        Button(action: onOpen) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(palette.hoverFill)
                }
            }
            .frame(maxWidth: AgentThumbnailCache.maxWidth)
            .frame(height: AgentThumbnailCache.displayHeight)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(hovering ? palette.borderStrong : palette.separator, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(entry.title)
        .accessibilityLabel(entry.accessibilityTitle)
        .task(id: entry.id + "\(entry.modified.timeIntervalSince1970)") {
            let entry = entry
            image = await Task.detached(priority: .utility) { AgentThumbnailCache.thumbnail(for: entry) }.value
        }
    }
}
