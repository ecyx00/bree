import AppKit
import BreeFoundation
import BreeAppKitSupportUI
import UniformTypeIdentifiers

final class FileExplorerCellView: NSTableCellView {
    private let iconView = BreeResolvedIconImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let loadingIndicator = NSProgressIndicator()
    /// Git status letter (M, A, D, R, U): the non-colour cue for the name colour.
    private let statusLabel = NSTextField(labelWithString: "")
    private var statusWidthConstraint: NSLayoutConstraint!
    private var trackingArea: NSTrackingArea?
    var onHover: ((Bool) -> Void)?
    private var nameLabelTrailingToLoadingConstraint: NSLayoutConstraint!
    private var nameLabelTrailingToContainerConstraint: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var iconWidthConstraint: NSLayoutConstraint!
    private var iconHeightConstraint: NSLayoutConstraint!
    private var iconToTextConstraint: NSLayoutConstraint!
    private var loadingWidthConstraint: NSLayoutConstraint!

    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.textColor = FileExplorerPalette.textPrimary
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isHidden = true
        loadingIndicator.setAccessibilityIdentifier("FileExplorerLoadingIndicator")

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(loadingIndicator)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        statusLabel.alignment = .center
        statusLabel.setAccessibilityElement(false)
        addSubview(statusLabel)
        statusWidthConstraint = statusLabel.widthAnchor.constraint(equalToConstant: 0)

        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 16)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 16)
        iconToTextConstraint = nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4)
        loadingWidthConstraint = loadingIndicator.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidthConstraint,
            iconHeightConstraint,

            iconToTextConstraint,
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            loadingIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            loadingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            loadingWidthConstraint,
            loadingIndicator.heightAnchor.constraint(equalToConstant: 12),

            statusLabel.trailingAnchor.constraint(equalTo: loadingIndicator.leadingAnchor, constant: -2),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusWidthConstraint,
        ])

        nameLabelTrailingToLoadingConstraint = nameLabel.trailingAnchor.constraint(
            equalTo: loadingIndicator.leadingAnchor,
            constant: -2
        )
        nameLabelTrailingToContainerConstraint = nameLabel.trailingAnchor.constraint(
            equalTo: statusLabel.leadingAnchor,
            constant: -2
        )
        NSLayoutConstraint.activate([
            nameLabelTrailingToLoadingConstraint,
            nameLabelTrailingToContainerConstraint
        ])
        nameLabelTrailingToLoadingConstraint.isActive = false
    }

    func configure(with node: FileExplorerNode, gitStatus: GitFileStatus? = nil) {
        assert(Thread.isMainThread, "AppKit image updates must run on the main thread")
        let style = FileExplorerStyle.current
        nameLabel.stringValue = node.name
        nameLabel.font = style.nameFont
        iconWidthConstraint.constant = style.iconSize
        iconHeightConstraint.constant = style.iconSize
        iconToTextConstraint.constant = style.iconToTextSpacing

        if style == .finder {
            // Native Finder icon pixels miss 3:1 in light mode; use their masks with the dynamic palette tint.
            if node.isDirectory {
                iconView.apply(BreeResolvedIconRequest(
                    source: .workspaceIcon(.folder),
                    size: NSSize(width: style.iconSize, height: style.iconSize),
                    tintColor: style.folderIconTint
                ))
            } else {
                let pathExtension = (node.name as NSString).pathExtension
                iconView.apply(BreeResolvedIconRequest(
                    source: .workspaceIcon(Self.contentType(forExtension: pathExtension)),
                    size: NSSize(width: style.iconSize, height: style.iconSize),
                    tintColor: style.fileIconTint
                ))
            }
        } else {
            if node.isDirectory {
                iconView.apply(BreeResolvedIconRequest(
                    source: .systemSymbol(name: "folder", accessibilityDescription: nil),
                    size: NSSize(width: style.iconSize, height: style.iconSize),
                    tintColor: style.folderIconTint,
                    symbolWeight: style.iconWeight
                ))
            } else {
                iconView.apply(BreeResolvedIconRequest(
                    source: .systemSymbol(name: "doc", accessibilityDescription: nil),
                    size: NSSize(width: style.iconSize, height: style.iconSize),
                    tintColor: style.fileIconTint,
                    symbolWeight: style.iconWeight
                ))
            }
        }

        if node.isLoading {
            loadingWidthConstraint.constant = 12
            loadingIndicator.isHidden = false
            loadingIndicator.startAnimation(nil)
            nameLabelTrailingToLoadingConstraint.isActive = true
            nameLabelTrailingToContainerConstraint.isActive = false
        } else {
            loadingWidthConstraint.constant = 0
            loadingIndicator.isHidden = true
            loadingIndicator.stopAnimation(nil)
            nameLabelTrailingToLoadingConstraint.isActive = false
            nameLabelTrailingToContainerConstraint.isActive = true
        }

        if let error = node.error {
            baseNameColor = FileExplorerPalette.signalError
            nameLabel.toolTip = error
        } else if let gitStatus {
            baseNameColor = style.gitColor(for: gitStatus)
            nameLabel.toolTip = node.path
        } else {
            baseNameColor = FileExplorerPalette.textPrimary
            nameLabel.toolTip = node.path
        }
        let letter = node.error == nil ? gitStatus.map(Self.statusLetter) : nil
        statusLabel.stringValue = letter ?? ""
        statusWidthConstraint.constant = letter == nil ? 0 : 12
        applyNameColor()
    }

    private static func statusLetter(_ status: GitFileStatus) -> String {
        switch status {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "U"
        }
    }

    /// Extension to content type, memoized: `UTType(filenameExtension:)` consults the type database.
    private static var contentTypeByExtension: [String: UTType] = [:]
    private static func contentType(forExtension ext: String) -> UTType {
        let key = ext.lowercased()
        if let cached = contentTypeByExtension[key] { return cached }
        let resolved = UTType(filenameExtension: key) ?? .data
        if contentTypeByExtension.count >= 512 { contentTypeByExtension.removeAll() }
        contentTypeByExtension[key] = resolved
        return resolved
    }

    private var baseNameColor: NSColor = FileExplorerPalette.textPrimary

    /// White on the opaque selected fill (the row view reports `.emphasized`
    /// only while the tree has keyboard focus); the role colour otherwise.
    private func applyNameColor() {
        nameLabel.textColor = backgroundStyle == .emphasized ? .white : baseNameColor
        statusLabel.textColor = nameLabel.textColor
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyNameColor() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }
}
