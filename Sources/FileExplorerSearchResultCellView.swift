import AppKit
import BreeFoundation

final class FileExplorerSearchResultCellView: NSTableCellView {
    private let pathLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    static var preferredRowHeight: CGFloat {
        max(
            46,
            ceil(
                13 +
                    lineHeight(for: BreeType.nsFont(.title)) +
                    lineHeight(for: BreeType.nsFont(.mono))
            )
        )
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.textColor = FileExplorerPalette.textPrimary
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1

        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.textColor = FileExplorerPalette.textSecondary
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 1

        addSubview(pathLabel)
        addSubview(previewLabel)

        NSLayoutConstraint.activate([
            pathLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            pathLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            pathLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),

            previewLabel.leadingAnchor.constraint(equalTo: pathLabel.leadingAnchor),
            previewLabel.trailingAnchor.constraint(equalTo: pathLabel.trailingAnchor),
            previewLabel.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 2),
        ])
    }

    func configure(with result: FileSearchResult) {
        pathLabel.font = BreeType.nsFont(.title)
        previewLabel.font = BreeType.nsFont(.mono)
        pathLabel.stringValue = "\(result.relativePath):\(result.lineNumber)"
        previewLabel.stringValue = result.preview.isEmpty ? " " : result.preview
        toolTip = "\(result.path):\(result.lineNumber):\(result.columnNumber)"
    }

    private static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }
}
