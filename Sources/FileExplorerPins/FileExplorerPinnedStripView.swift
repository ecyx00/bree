import AppKit
import CmuxFoundation
import Combine

/// "Pinned" section at the top of the Files sidebar: a collapsible list of the
/// project's pinned files. Hidden (zero height) when the project has no pins.
/// Missing files stay listed, dimmed, with a Remove button.
@MainActor
final class FileExplorerPinnedStripView: NSView {
    private static let headerHeight: CGFloat = 24
    private static let rowHeight: CGFloat = 22

    /// Opens an absolute path through the Quick View file-open path.
    var onOpen: ((String) -> Void)?

    private let store = PinnedFilesStore()
    private let headerButton = NSButton()
    private let rowsStack = NSStackView()
    private let separator = NSBox()
    private var heightConstraint: NSLayoutConstraint!
    private var root: String?
    private var renderedSignature: [String] = []
    private var changeSubscription: AnyCancellable?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        headerButton.translatesAutoresizingMaskIntoConstraints = false
        headerButton.isBordered = false
        headerButton.imagePosition = .imageLeading
        headerButton.alignment = .left
        headerButton.font = BreeType.nsFont(.caption, weight: .medium)
        headerButton.contentTintColor = Self.secondaryTextColor
        headerButton.target = self
        headerButton.action = #selector(toggleCollapsed)
        headerButton.setAccessibilityIdentifier("FileExplorerPinnedHeader")
        addSubview(headerButton)

        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        addSubview(rowsStack)

        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        addSubview(separator)

        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightConstraint,
            headerButton.topAnchor.constraint(equalTo: topAnchor),
            headerButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            headerButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            headerButton.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            rowsStack.topAnchor.constraint(equalTo: headerButton.bottomAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        changeSubscription = NotificationCenter.default
            .publisher(for: .pinnedFilesDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Palette `textSecondary` (4.5:1 floor on every surface).
    private static var secondaryTextColor: NSColor { FileExplorerPalette.textSecondary }

    /// Points the strip at a project root; nil (remote or unknown) hides it.
    func update(root newRoot: String?) {
        root = newRoot
        reload()
    }

    private struct Pin {
        let relativePath: String
        let absolutePath: String
        let exists: Bool
    }

    private func currentPins() -> [Pin] {
        guard let root else { return [] }
        return store.pins(forRoot: root).map { relative in
            let absolute = PinnedFilesStore.absolutePath(for: relative, root: root)
            return Pin(
                relativePath: relative,
                absolutePath: absolute,
                exists: FileManager.default.fileExists(atPath: absolute)
            )
        }
    }

    private func reload() {
        let pins = currentPins()
        let collapsed = store.isSectionCollapsed
        let signature = pins.map { "\($0.relativePath)|\($0.exists ? 1 : 0)" } + [collapsed ? "c" : "e", root ?? ""]
        guard signature != renderedSignature else { return }
        renderedSignature = signature

        isHidden = pins.isEmpty
        guard !pins.isEmpty else {
            heightConstraint.constant = 0
            rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            return
        }

        let title = String(localized: "fileExplorer.pinned.header", defaultValue: "Pinned")
        headerButton.title = "\(title) (\(pins.count))"
        headerButton.image = NSImage(
            systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
            accessibilityDescription: nil
        )
        headerButton.setAccessibilityLabel(title)
        headerButton.setAccessibilityExpanded(!collapsed)

        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if !collapsed {
            for pin in pins {
                let row = PinnedRowView(
                    relativePath: pin.relativePath,
                    absolutePath: pin.absolutePath,
                    exists: pin.exists,
                    onOpen: { [weak self] path in self?.onOpen?(path) },
                    onRemove: { [weak self] relative in self?.remove(relativePath: relative) }
                )
                rowsStack.addArrangedSubview(row)
                row.leadingAnchor.constraint(equalTo: rowsStack.leadingAnchor).isActive = true
                row.trailingAnchor.constraint(equalTo: rowsStack.trailingAnchor).isActive = true
                row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
            }
        }
        let rows = collapsed ? 0 : pins.count
        heightConstraint.constant = Self.headerHeight + CGFloat(rows) * Self.rowHeight + 1
    }

    @objc private func toggleCollapsed() {
        store.isSectionCollapsed.toggle()
        reload()
    }

    private func remove(relativePath: String) {
        guard let root else { return }
        store.unpin(relativePath: relativePath, root: root)
    }
}

/// One pinned file: a button that opens it, plus a Remove button when missing.
@MainActor
private final class PinnedRowView: NSView {
    private let relativePath: String
    private let absolutePath: String
    private let exists: Bool
    private let onOpen: (String) -> Void
    private let onRemove: (String) -> Void

    init(
        relativePath: String,
        absolutePath: String,
        exists: Bool,
        onOpen: @escaping (String) -> Void,
        onRemove: @escaping (String) -> Void
    ) {
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.exists = exists
        self.onOpen = onOpen
        self.onRemove = onRemove
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let openButton = NSButton()
        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.isBordered = false
        openButton.alignment = .left
        openButton.imagePosition = .imageLeading
        openButton.lineBreakMode = .byTruncatingMiddle
        openButton.font = BreeType.nsFont(.body)
        openButton.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        openButton.title = (relativePath as NSString).lastPathComponent
        openButton.toolTip = relativePath
        openButton.target = self
        openButton.action = #selector(open)
        openButton.setAccessibilityLabel(openButton.title)
        openButton.setAccessibilityHelp(relativePath)
        openButton.setAccessibilityIdentifier("FileExplorerPinnedRow")
        // Missing files are dimmed; they stay listed so they can be removed.
        openButton.alphaValue = exists ? 1 : 0.45
        openButton.isEnabled = exists
        // On the row, not the button: a disabled (missing) button swallows right-clicks.
        menu = makeMenu()
        addSubview(openButton)

        var constraints = [
            openButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            openButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if exists {
            constraints.append(openButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8))
        } else {
            let removeButton = NSButton(
                title: String(localized: "fileExplorer.pinned.remove", defaultValue: "Remove"),
                target: self,
                action: #selector(remove)
            )
            removeButton.translatesAutoresizingMaskIntoConstraints = false
            removeButton.isBordered = false
            removeButton.font = BreeType.nsFont(.caption)
            removeButton.contentTintColor = FileExplorerPalette.activeIndicator
            removeButton.setAccessibilityIdentifier("FileExplorerPinnedRemove")
            addSubview(removeButton)
            constraints += [
                removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                openButton.trailingAnchor.constraint(lessThanOrEqualTo: removeButton.leadingAnchor, constant: -6),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let title = exists
            ? String(localized: "fileExplorer.contextMenu.unpin", defaultValue: "Unpin")
            : String(localized: "fileExplorer.pinned.remove", defaultValue: "Remove")
        let item = NSMenuItem(title: title, action: #selector(remove), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func open() {
        guard exists else { return }
        onOpen(absolutePath)
    }

    @objc private func remove() {
        onRemove(relativePath)
    }
}
