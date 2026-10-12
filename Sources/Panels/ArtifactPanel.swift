import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// What an ``ArtifactPanel`` renders.
enum ArtifactKind: Equatable {
    case html
    case csv(delimiter: UInt8)
    case jsonl
    case folder

    /// The artifact renderer for a file path, or nil when the regular file preview handles it.
    static func kind(forFilePath path: String) -> ArtifactKind? {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm", "xhtml": .html
        case "csv": .csv(delimiter: UInt8(ascii: ","))
        case "tsv": .csv(delimiter: UInt8(ascii: "\t"))
        case "jsonl", "ndjson": .jsonl
        default: nil
        }
    }
}

/// A Quick View-only panel (never registered in a workspace) for artifacts the
/// file preview shows poorly: rendered HTML, CSV/TSV tables, JSONL records and
/// folder image grids. Source view reuses a `FilePreviewPanel`.
@MainActor
final class ArtifactPanel: Panel, ObservableObject {
    let id = UUID()
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    /// Quick View panels are not persisted; this only has to be a valid value.
    let panelType: PanelType = .filePreview
    let kind: ArtifactKind
    let path: String
    let workspaceId: UUID
    private let fileContentChangeCoordinator: FileContentChangeCoordinator?

    @Published private(set) var showSource = false
    @Published private(set) var sourcePanel: FilePreviewPanel?

    // HTML
    @Published var remoteContentBlocked = false
    @Published var allowsRemoteContent = false

    // CSV / JSONL (nil while loading)
    @Published private(set) var table: ArtifactCSVParser.Result?
    @Published private(set) var records: ArtifactJSONLParser.Result?
    private var loadTask: Task<Void, Never>?
    private var didStartFolder = false

    // Folder grid
    @Published private(set) var thumbnailSize: CGFloat
    @Published private(set) var images: [ArtifactGridImage] = []
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadWorkItem: DispatchWorkItem?

    static let thumbnailSizes: [CGFloat] = [64, 96, 128, 160, 200, 260, 340]

    init(kind: ArtifactKind, path: String, workspaceId: UUID, fileContentChangeCoordinator: FileContentChangeCoordinator?) {
        self.kind = kind
        self.path = path
        self.workspaceId = workspaceId
        self.fileContentChangeCoordinator = fileContentChangeCoordinator
        self.thumbnailSize = ArtifactGridMemory.shared.thumbnailSize(forFolder: path)
    }

    var displayTitle: String { (path as NSString).lastPathComponent }

    var displayIcon: String? {
        switch kind {
        case .html: "globe"
        case .csv: "tablecells"
        case .jsonl: "list.bullet.rectangle"
        case .folder: "square.grid.3x3"
        }
    }

    /// Folders have no source; every file kind does.
    var supportsSourceToggle: Bool { kind != .folder }

    func toggleSource() {
        guard supportsSourceToggle else { return }
        if sourcePanel == nil {
            sourcePanel = FilePreviewPanel(
                workspaceId: workspaceId,
                filePath: path,
                fileContentChangeCoordinator: fileContentChangeCoordinator
            )
        }
        showSource.toggle()
    }

    // MARK: - Loading

    /// Starts the kind-specific load once; the view calls this from `.task`.
    func load() {
        guard loadTask == nil, !didStartFolder else { return }
        switch kind {
        case .csv(let delimiter):
            let path = path
            loadTask = Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) { () -> ArtifactCSVParser.Result in
                    let data = (try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)) ?? Data()
                    return ArtifactCSVParser.parse(data, delimiter: delimiter)
                }.value
                self?.table = result
            }
        case .jsonl:
            let path = path
            loadTask = Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) { () -> ArtifactJSONLParser.Result in
                    let data = (try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)) ?? Data()
                    return ArtifactJSONLParser.parse(data)
                }.value
                self?.records = result
            }
        case .folder:
            didStartFolder = true
            reloadImages()
            startWatching()
        case .html:
            break
        }
    }

    // MARK: - Folder grid

    func zoom(by step: Int) {
        let sizes = Self.thumbnailSizes
        let current = sizes.enumerated().min { abs($0.element - thumbnailSize) < abs($1.element - thumbnailSize) }?.offset ?? 3
        let next = min(max(current + step, 0), sizes.count - 1)
        guard sizes[next] != thumbnailSize else { return }
        thumbnailSize = sizes[next]
        ArtifactGridMemory.shared.setThumbnailSize(thumbnailSize, forFolder: path)
    }

    var canZoomIn: Bool { thumbnailSize < Self.thumbnailSizes.last! }
    var canZoomOut: Bool { thumbnailSize > Self.thumbnailSizes.first! }

    private func reloadImages() {
        let folder = path
        Task { [weak self] in
            let listing = await Task.detached(priority: .userInitiated) { ArtifactGridImage.list(folder: folder) }.value
            guard let self, self.images != listing else { return }
            self.images = listing
        }
    }

    private func startWatching() {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete, .link],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // Debounce: agents write many files in a burst.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadWorkItem?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { self?.reloadImages() }
                }
                self.reloadWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        watcher = source
    }

    // MARK: - Panel protocol

    func close() {
        loadTask?.cancel()
        loadTask = nil
        reloadWorkItem?.cancel()
        watcher?.cancel()
        watcher = nil
        sourcePanel?.close()
        sourcePanel = nil
    }

    func focus() {}
    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }
}

/// One image file of a grid folder.
struct ArtifactGridImage: Equatable {
    let path: String
    let modified: TimeInterval
    var name: String { (path as NSString).lastPathComponent }

    /// Non-recursive, visible image files sorted by name (numbers in natural order).
    nonisolated static func list(folder: String) -> [ArtifactGridImage] {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { entry -> ArtifactGridImage? in
            guard let type = UTType(filenameExtension: entry.pathExtension), type.conforms(to: .image),
                  let values = try? entry.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return ArtifactGridImage(path: entry.path, modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Grid selection and thumbnail size per folder, so Back from a single image
/// lands on the same item. Cleared when a Quick View window closes.
@MainActor
final class ArtifactGridMemory {
    static let shared = ArtifactGridMemory()
    private var selected: [String: String] = [:]
    private var sizes: [String: CGFloat] = [:]

    func selectedName(forFolder path: String) -> String? { selected[path] }
    func setSelectedName(_ name: String?, forFolder path: String) { selected[path] = name }
    func thumbnailSize(forFolder path: String) -> CGFloat { sizes[path] ?? 160 }
    func setThumbnailSize(_ size: CGFloat, forFolder path: String) { sizes[path] = size }
    func removeAll() {
        selected.removeAll()
        sizes.removeAll()
    }
}
