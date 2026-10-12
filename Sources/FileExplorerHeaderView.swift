import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation

/// Pure AppKit header bar with folder icon, path label, and hidden files toggle.
final class FileExplorerHeaderView: NSView {
    private let iconView = CmuxResolvedIconImageView()
    private let retryButton = NSButton()
    private var retry: (() -> Void)?
    private let pathLabel = NSTextField(labelWithString: "")
    private let pathControl = NSPathControl()
    /// Set for local roots to make breadcrumb components clickable.
    var onNavigate: ((String) -> Void)?
    private var localRootPath: String?
    private var heightConstraint: NSLayoutConstraint?
    private var displayPath = ""
    private var quickSearchQuery: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        applyFonts()
        pathLabel.textColor = FileExplorerPalette.textSecondary
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.pathStyle = .standard
        pathControl.backgroundColor = .clear
        pathControl.focusRingType = .none
        pathControl.target = self
        pathControl.action = #selector(pathItemClicked)
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathControl.isHidden = true

        addSubview(iconView)
        addSubview(pathLabel)
        addSubview(pathControl)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        retryButton.bezelStyle = .inline
        retryButton.isBordered = false
        retryButton.target = self
        retryButton.action = #selector(retryFiles)
        retryButton.toolTip = String(localized: "common.retry", defaultValue: "Retry")
        retryButton.setAccessibilityLabel(retryButton.toolTip)
        addSubview(retryButton)

        let heightConstraint = heightAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.secondaryBarHeight)
        self.heightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            heightConstraint,

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: RightSidebarChromeMetrics.contentIconLeadingPadding),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.contentIconFrameSize),
            iconView.heightAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.contentIconFrameSize),

            pathLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: RightSidebarChromeMetrics.contentIconTextSpacing),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: retryButton.leadingAnchor, constant: -8),
            pathControl.leadingAnchor.constraint(equalTo: pathLabel.leadingAnchor),
            pathControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathControl.trailingAnchor.constraint(equalTo: pathLabel.trailingAnchor),
            retryButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            retryButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            retryButton.widthAnchor.constraint(equalToConstant: 18),
        ])
        applyHeaderState()
    }

    func applyFonts() {
        pathLabel.font = BreeType.nsFont(.mono)
        pathControl.font = pathLabel.font
        heightConstraint?.constant = RightSidebarChromeMetrics.secondaryBarHeight
    }

    @objc private func retryFiles() { retry?() }

    @objc private func pathItemClicked() {
        guard let url = pathControl.clickedPathItem?.url else { return }
        onNavigate?(url.path)
    }

    func update(displayPath: String, localRootPath: String? = nil, retry: (() -> Void)? = nil) {
        self.retry = retry
        retryButton.isHidden = retry == nil
        guard self.displayPath != displayPath || self.localRootPath != localRootPath else { return }
        self.displayPath = displayPath
        self.localRootPath = localRootPath
        applyHeaderState()
    }

    func updateQuickSearch(query: String?) {
        guard quickSearchQuery != query else { return }
        quickSearchQuery = query
        applyHeaderState()
    }

    func applyHeaderState() {
        assert(Thread.isMainThread, "AppKit image updates must run on the main thread")
        if let quickSearchQuery {
            iconView.apply(CmuxResolvedIconRequest(
                source: .systemSymbol(name: "magnifyingglass", accessibilityDescription: nil),
                size: NSSize(width: 14, height: 14),
                tintColor: FileExplorerPalette.textSecondary,
                symbolWeight: .regular
            ))
            pathLabel.stringValue = "/" + quickSearchQuery
            pathLabel.toolTip = pathLabel.stringValue
            pathLabel.isHidden = false
            pathControl.isHidden = true
        } else {
            iconView.apply(CmuxResolvedIconRequest(
                source: .systemSymbol(name: "folder", accessibilityDescription: nil),
                size: NSSize(width: 14, height: 14),
                tintColor: FileExplorerPalette.textSecondary,
                symbolWeight: .regular
            ))
            pathLabel.stringValue = displayPath
            pathLabel.toolTip = displayPath
        }
        if quickSearchQuery == nil, let localRootPath, !localRootPath.isEmpty {
            pathControl.url = URL(fileURLWithPath: localRootPath)
            // Plain text path: drop the Finder disk/folder icons NSPathControl adds per component.
            var items = pathControl.pathItems.map { item -> NSPathControlItem in
                item.image = nil
                return item
            }
            // Start at ~ (or / outside home) instead of the volume name, which clipped.
            let home = (NSHomeDirectory() as NSString).standardizingPath
            if let homeIndex = items.firstIndex(where: { $0.url?.standardizedFileURL.path == home }) {
                items = Array(items[homeIndex...])
                items[0].title = "~"
            } else if items.count > 1 {
                items[0].title = "/"
            }
            pathControl.pathItems = items
            pathLabel.isHidden = true
            pathControl.isHidden = false
        } else if quickSearchQuery == nil {
            pathLabel.isHidden = false
            pathControl.isHidden = true
        }
    }
}
