import AppKit
import Foundation
import Quartz

/// Quick Look large view for TextBox image attachments. Quick Look supplies
/// left/right browsing, Esc to close and zoom. The checklist controller is
/// typed to `WorkspaceChecklistAttachment`, so this is a small URL-based sibling.
@MainActor
final class TextBoxAttachmentQuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = TextBoxAttachmentQuickLookController()

    private var items: [TextBoxAttachmentQuickLookItem] = []

    var isShown: Bool {
        guard let panel = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil else {
            return false
        }
        return panel.isVisible && panel.dataSource === self
    }

    func present(entries: [(url: URL, title: String)], selectedIndex: Int) {
        let available = entries.enumerated().filter {
            FileManager.default.fileExists(atPath: $0.element.url.path)
        }
        guard !available.isEmpty, let panel = QLPreviewPanel.shared() else {
            NSSound.beep()
            return
        }
        items = available.map { TextBoxAttachmentQuickLookItem(url: $0.element.url, title: $0.element.title) }
        // Entries may have been filtered out; map the requested index to the filtered list.
        let start = available.firstIndex { $0.offset == selectedIndex } ?? 0
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = start
        panel.makeKeyAndOrderFront(nil)
    }

    /// Opens every image attachment with a local file, starting at `selectedId`.
    func present(attachments: [TextBoxAttachment], selectedId: UUID) {
        let images = attachments.filter { $0.isImage && $0.localURL != nil }
        present(
            entries: images.compactMap { attachment in
                attachment.localURL.map { (url: $0, title: attachment.displayName) }
            },
            selectedIndex: images.firstIndex { $0.id == selectedId } ?? 0
        )
    }

    /// Closes the panel if it shows our items (message submitted, temp files going away).
    func dismiss() {
        if isShown, let panel = QLPreviewPanel.shared() {
            panel.orderOut(nil)
        }
        items = []
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            items.indices.contains(index) ? items[index] : nil
        }
    }
}

private final class TextBoxAttachmentQuickLookItem: NSObject, QLPreviewItem {
    private let url: URL
    private let title: String

    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    var previewItemURL: URL? { url }
    var previewItemTitle: String? { title }
}
