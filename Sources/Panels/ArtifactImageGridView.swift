import AppKit
import QuickLookThumbnailing
import SwiftUI

/// In-memory thumbnail cache for the folder grid. Bounded by cost (about 64 MB of bitmap data) and
/// emptied when a Quick View window closes, so the grid never holds RAM after it is gone.
@MainActor
final class ArtifactThumbnailCache {
    static let shared = ArtifactThumbnailCache()
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    func image(forKey key: String) -> NSImage? { cache.object(forKey: key as NSString) }

    func store(_ image: NSImage, cost: Int, forKey key: String) {
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    func removeAll() { cache.removeAllObjects() }
}

/// Folder image grid: NSCollectionView with arrow-key selection, Space/Return/double-click to open,
/// file name captions and QLThumbnailGenerator thumbnails.
struct ArtifactImageGridView: View {
    @ObservedObject var panel: ArtifactPanel

    var body: some View {
        ArtifactImageGridRepresentable(panel: panel)
            .overlay {
                if panel.images.isEmpty {
                    Text(String(localized: "artifact.grid.empty", defaultValue: "No images in this folder"))
                        .foregroundStyle(.secondary)
                }
            }
    }
}

private struct ArtifactImageGridRepresentable: NSViewRepresentable {
    @ObservedObject var panel: ArtifactPanel

    func makeCoordinator() -> Coordinator { Coordinator(panel: panel) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 8, left: 12, bottom: 12, right: 12)
        let collection = ArtifactGridCollectionView()
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = false
        collection.backgroundColors = [.clear]
        collection.dataSource = coordinator
        collection.delegate = coordinator
        collection.register(ArtifactGridItem.self, forItemWithIdentifier: ArtifactGridItem.identifier)
        collection.onOpen = { [weak coordinator] in coordinator?.openSelected() }
        coordinator.collection = collection
        coordinator.apply(images: panel.images, size: panel.thumbnailSize, initial: true)
        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.apply(images: panel.images, size: panel.thumbnailSize, initial: false)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.collection?.dataSource = nil
        coordinator.collection?.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
        let panel: ArtifactPanel
        weak var collection: ArtifactGridCollectionView?
        private var images: [ArtifactGridImage] = []
        private var size: CGFloat = 0

        init(panel: ArtifactPanel) { self.panel = panel }

        /// Pushes panel state into the collection view, keeping the selection by file name.
        func apply(images newImages: [ArtifactGridImage], size newSize: CGFloat, initial: Bool) {
            guard let collection, initial || newImages != images || newSize != size else { return }
            let current = selectedIndex.flatMap { images.indices.contains($0) ? images[$0].name : nil }
            let restoring = current == nil
            let selectedName = current ?? ArtifactGridMemory.shared.selectedName(forFolder: panel.path)
            if newSize != size { ArtifactThumbnailCache.shared.removeAll() }
            images = newImages
            size = newSize
            (collection.collectionViewLayout as? NSCollectionViewFlowLayout)?.itemSize = NSSize(width: newSize, height: newSize + 24)
            collection.reloadData()
            guard let selectedName, let index = images.firstIndex(where: { $0.name == selectedName }) else { return }
            select(index, scroll: false, collection: collection)
            if restoring {
                // Layout is not final until the scroll view has a size: center the restored item then.
                DispatchQueue.main.async { [weak collection] in
                    collection?.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .centeredVertically)
                }
            }
        }

        var selectedIndex: Int? { collection?.selectionIndexPaths.first?.item }

        func select(_ index: Int, scroll: Bool, collection: NSCollectionView) {
            let path = IndexPath(item: index, section: 0)
            collection.selectionIndexPaths = [path]
            if scroll { collection.scrollToItems(at: [path], scrollPosition: .nearestVerticalEdge) }
            ArtifactGridMemory.shared.setSelectedName(images[index].name, forFolder: panel.path)
        }

        func openSelected() {
            guard let index = selectedIndex, images.indices.contains(index) else { return }
            ArtifactGridMemory.shared.setSelectedName(images[index].name, forFolder: panel.path)
            _ = QuickViewWindowController.openLink(images[index].path, fromPanelId: panel.id)
        }

        // MARK: Data source

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { images.count }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: ArtifactGridItem.identifier, for: indexPath)
            if let item = item as? ArtifactGridItem, images.indices.contains(indexPath.item) {
                item.configure(with: images[indexPath.item], size: size)
            }
            return item
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            if let index = indexPaths.first?.item, images.indices.contains(index) {
                ArtifactGridMemory.shared.setSelectedName(images[index].name, forFolder: panel.path)
            }
        }
    }
}

/// Collection view with keyboard navigation (arrows, Space/Return open) that owns first responder on attach.
final class ArtifactGridCollectionView: NSCollectionView {
    var onOpen: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
        if event.clickCount == 2 { onOpen?() }
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        let count = numberOfItems(inSection: 0)
        switch event.keyCode {
        case 49, 36, 76: // space, return, keypad enter
            if selectionIndexPaths.isEmpty, count > 0 { selectionIndexPaths = [IndexPath(item: 0, section: 0)] }
            onOpen?()
        case 123: move(by: -1, count: count)
        case 124: move(by: 1, count: count)
        case 125: move(by: columns, count: count)
        case 126: move(by: -columns, count: count)
        default: super.keyDown(with: event)
        }
    }

    private var columns: Int {
        guard let layout = collectionViewLayout as? NSCollectionViewFlowLayout else { return 1 }
        let usable = bounds.width - layout.sectionInset.left - layout.sectionInset.right
        return max(1, Int((usable + layout.minimumInteritemSpacing) / (layout.itemSize.width + layout.minimumInteritemSpacing)))
    }

    private func move(by delta: Int, count: Int) {
        guard count > 0 else { return }
        let current = selectionIndexPaths.first?.item
        let target = current.map { min(max($0 + delta, 0), count - 1) } ?? 0
        let path = IndexPath(item: target, section: 0)
        selectionIndexPaths = [path]
        scrollToItems(at: [path], scrollPosition: .nearestVerticalEdge)
        delegate?.collectionView?(self, didSelectItemsAt: [path])
    }
}

/// Thumbnail plus file name caption.
final class ArtifactGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ArtifactGridItem")
    private let thumbnailView = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private var request: QLThumbnailGenerator.Request?
    private var representedPath: String?

    override var isSelected: Bool {
        didSet { view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor : nil }
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 6
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        caption.font = .systemFont(ofSize: 11)
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingMiddle
        caption.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(thumbnailView)
        root.addSubview(caption)
        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            thumbnailView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            thumbnailView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            thumbnailView.bottomAnchor.constraint(equalTo: caption.topAnchor, constant: -2),
            caption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            caption.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
            caption.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
        ])
        view = root
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelRequest()
        representedPath = nil
        thumbnailView.image = nil
    }

    private func cancelRequest() {
        if let request { QLThumbnailGenerator.shared.cancel(request) }
        request = nil
    }

    @MainActor
    func configure(with image: ArtifactGridImage, size: CGFloat) {
        _ = view
        cancelRequest()
        representedPath = image.path
        caption.stringValue = image.name
        view.toolTip = image.name
        thumbnailView.setAccessibilityLabel(image.name)
        let key = "\(image.path)|\(image.modified)|\(Int(size))"
        if let cached = ArtifactThumbnailCache.shared.image(forKey: key) {
            thumbnailView.image = cached
            return
        }
        thumbnailView.image = nil
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: image.path),
            size: CGSize(width: size, height: size),
            scale: scale,
            representationTypes: .thumbnail
        )
        self.request = request
        let path = image.path
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let cgImage = representation?.cgImage else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
                    ArtifactThumbnailCache.shared.store(nsImage, cost: cgImage.bytesPerRow * cgImage.height, forKey: key)
                    guard let self, self.representedPath == path else { return }
                    self.thumbnailView.image = nsImage
                }
            }
        }
    }
}
