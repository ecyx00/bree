import AppKit
import BreeFoundation
import SwiftUI
import WebKit

/// SwiftUI view that renders a MarkdownPanel's content in a WKWebView using
/// marked.js + github-markdown-css + highlight.js.
///
/// We render through a web view (rather than the previous MarkdownUI path)
/// so that:
///   - Native browser text selection works across the entire document
///     (Cmd+A / drag-select span paragraphs, headings, code blocks, etc.).
///     MarkdownUI rendered each block as an isolated SwiftUI `Text`, which
///     made it impossible to select more than one block at a time.
///   - Rendering uses GitHub's actual markdown CSS, so tables, task lists,
///     nested lists, blockquotes, and code blocks look identical to what
///     users see on github.com.
///   - We can copy the rendered HTML straight from the same source the user
///     is reading.
struct MarkdownPanelView: View {
    @Environment(\.breeAccentColor) private var breeAccent
    @ObservedObject var panel: MarkdownPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void
    /// Quick View has its own titlebar button, so it turns this header one off.
    var showsObsidianButton = true

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0
    @State private var copyConfirmation: CopyConfirmation? = nil
    @State private var copyConfirmationGeneration: Int = 0
    /// Debounced source for the split-mode preview; nil outside split mode.
    @State private var splitRenderedMarkdown: String?
    /// Measured header row width; picks the header variant deterministically.
    @State private var headerWidth: CGFloat = 600
    @AppStorage(FilePreviewWordWrapSettings.key) private var fileEditorWordWrap = FilePreviewWordWrapSettings.defaultEnabled

    private enum CopyConfirmation: Equatable {
        case markdown
        case html

        var label: String {
            switch self {
            case .markdown:
                return String(localized: "markdown.copyConfirm.markdown", defaultValue: "Copied as Markdown")
            case .html:
                return String(localized: "markdown.copyConfirm.html", defaultValue: "Copied as HTML")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filePathHeader

            Divider()

            if panel.isFileUnavailable {
                fileUnavailableView
            } else {
                markdownBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(contentBackgroundColor)
        .overlay {
            WorkspaceAttentionFlashRingView(opacity: focusFlashOpacity)
        }
        .onChange(of: panel.focusFlashToken) {
            triggerFocusFlashAnimation()
        }
        .environment(\.colorScheme, themeColorScheme)
    }

    // MARK: - Content

    @ViewBuilder
    private var markdownBody: some View {
        GeometryReader { geometry in
        // Split keeps the single panel-owned web view mounted at the same spot
        // and only shifts it right; the editor takes the left half.
        let isSplit = panel.displayMode == .split
        let showsPreview = panel.displayMode != .text
        ZStack(alignment: .leading) {
            MarkdownWebRenderer(
                markdown: isSplit ? (splitRenderedMarkdown ?? panel.content) : panel.content,
                theme: MarkdownWebTheme.resolve(backgroundColor: themeBackgroundColor),
                backgroundColor: appearance.contentBackgroundColor,
                isVisibleInUI: isVisibleInUI && showsPreview,
                panelId: panel.id,
                workspaceId: panel.workspaceId,
                filePath: panel.filePath,
                fontSize: panel.fontSize,
                fontFamily: panel.fontFamily,
                maxContentWidth: panel.maxContentWidth,
                session: panel.rendererSession,
                onRequestPanelFocus: onRequestPanelFocus,
                onViewAttachedToWindow: { [weak panel] in
                    panel?.replayPendingPreviewFocusAfterWindowAttach()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, isSplit ? geometry.size.width / 2 : 0)
            .opacity(showsPreview ? 1 : 0)
            .allowsHitTesting(showsPreview)
            .accessibilityHidden(!showsPreview)

            if panel.displayMode != .preview {
                FilePreviewTextEditor(
                    panel: panel,
                    isVisibleInUI: isVisibleInUI,
                    themeBackgroundColor: appearance.contentBackgroundColor,
                    themeForegroundColor: themeForegroundColor,
                    drawsBackground: appearance.drawsContentBackground,
                    gutterBackgroundColor: appearance.backgroundColor,
                    wordWrap: fileEditorWordWrap,
                    filePath: panel.filePath
                )
                .frame(width: isSplit ? geometry.size.width / 2 : geometry.size.width)
                .frame(maxHeight: .infinity)
            }

            if panel.displayMode == .preview, let searchState = panel.searchState {
                BrowserSearchOverlay(
                    panelId: panel.id,
                    searchState: searchState,
                    focusRequestGeneration: panel.searchFocusRequestGeneration,
                    canApplyFocusRequest: { generation in
                        panel.canApplySearchFocusRequest(generation)
                    },
                    onNext: { panel.findNext() },
                    onPrevious: { panel.findPrevious() },
                    onClose: { panel.hideFind() },
                    onFieldDidFocus: {}
                )
            }
        }
        }
        .task(id: panel.content) {
            guard panel.displayMode == .split else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            splitRenderedMarkdown = panel.content
        }
        .onChange(of: panel.displayMode) { splitRenderedMarkdown = nil }
    }

    private var filePathHeader: some View {
        PanelFilePathHeader(
            iconSystemName: panel.displayIcon ?? "doc.richtext",
            filePath: panel.filePath,
            foregroundColor: themeForegroundColor
        ) {
            // Variant chosen from the measured header width (not ideal sizes).
            if headerWidth >= 560 {
                HStack(spacing: 8) {
                    editControls
                    if panel.displayMode == .preview {
                        MarkdownTypographyControl(panel: panel)
                        PanelHeaderIconButton(
                            systemName: "arrow.clockwise",
                            label: String(localized: "filePreview.refresh", defaultValue: "Refresh"),
                            action: { panel.reloadFromDisk() }
                        )
                    }
                    markdownModeButton
                    if showsObsidianButton { OpenInObsidianButton(path: panel.filePath, asHeaderIcon: true) }
                    MarkdownPanelToolbar(
                        confirmation: copyConfirmation?.label,
                        onCopyMarkdown: { copyAsMarkdown() },
                        onCopyHTML: { copyAsHTML() }
                    )
                    FileExternalOpenMenu(
                        fileURL: URL(fileURLWithPath: panel.filePath),
                        isDisabled: panel.isFileUnavailable
                    )
                }
            // Constant, measured by click test: the segmented picker plus edit
            // controls and a readable path need about 440 pt.
            } else if headerWidth >= 440 {
                HStack(spacing: 8) {
                    editControls
                    markdownModeButton
                }
            } else {
                HStack(spacing: 8) {
                    editControls
                    markdownModeMenu
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { headerWidth = $0 }
    }

    @ViewBuilder
    private var editControls: some View {
        if panel.displayMode != .preview {
            PanelHeaderIconButton(
                systemName: "arrow.counterclockwise",
                label: String(localized: "markdown.toolbar.revert", defaultValue: "Revert"),
                isDisabled: !panel.isDirty,
                action: { panel.loadTextContent() }
            )

            PanelHeaderIconButton(
                systemName: "square.and.arrow.down",
                label: String(localized: "markdown.toolbar.save", defaultValue: "Save"),
                isDisabled: !panel.isDirty || panel.isSaving || panel.isReadOnly,
                action: { panel.saveTextContent() }
            )
            if panel.isReadOnly {
                PanelReadOnlyEditButton { panel.isReadOnly = false }
            }
        }
    }

    /// Last-resort mode switcher for very narrow panes: one icon-sized menu.
    private var markdownModeMenu: some View {
        let modes: [(MarkdownPanelDisplayMode, String, String)] = [
            (.preview, String(localized: "markdown.mode.rendered", defaultValue: "Rendered"), "doc.richtext"),
            (.text, String(localized: "markdown.mode.source", defaultValue: "Source"), "chevron.left.forwardslash.chevron.right"),
            (.split, String(localized: "markdown.mode.split", defaultValue: "Split"), "rectangle.split.2x1"),
        ]
        let current = modes.first { $0.0 == panel.displayMode } ?? modes[0]
        return Menu {
            ForEach(modes, id: \.0) { mode in
                Button {
                    panel.setDisplayMode(mode.0)
                } label: {
                    Label(mode.1, systemImage: mode.2)
                }
            }
        } label: {
            Image(systemName: current.2)
                .font(.system(size: RightSidebarChromeMetrics.headerIconSize))
                .foregroundColor(.secondary)
                .frame(
                    width: RightSidebarChromeMetrics.headerControlSize,
                    height: RightSidebarChromeMetrics.headerControlSize
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(current.1)
        .accessibilityLabel(current.1)
    }

    private var markdownModeButton: some View {
        Picker("", selection: Binding(
            get: { panel.displayMode },
            set: { panel.setDisplayMode($0) }
        )) {
            Text(String(localized: "markdown.mode.rendered", defaultValue: "Rendered")).tag(MarkdownPanelDisplayMode.preview)
            Text(String(localized: "markdown.mode.source", defaultValue: "Source")).tag(MarkdownPanelDisplayMode.text)
            Text(String(localized: "markdown.mode.split", defaultValue: "Split")).tag(MarkdownPanelDisplayMode.split)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .tint(breeAccent.selectedFillColor)
    }

    private var fileUnavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .scaledFont(size: 40)
                .foregroundColor(.secondary)
            Text(String(localized: "markdown.fileUnavailable.title", defaultValue: "File unavailable"))
                .scaledFont(.headline)
                .foregroundColor(.primary)
            Text(panel.filePath)
                .scaledFont(size: 12, design: .monospaced)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .copyOnlyTextSelection(for: panel.filePath)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Text(String(localized: "markdown.fileUnavailable.message", defaultValue: "The file may have been moved or deleted."))
                .scaledFont(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Theme

    private var contentBackgroundColor: Color {
        Color(nsColor: appearance.contentBackgroundColor)
    }

    private var themeBackgroundColor: NSColor {
        appearance.backgroundColor
    }

    private var themeForegroundColor: NSColor {
        appearance.foregroundColor
    }

    private var themeColorScheme: ColorScheme {
        themeBackgroundColor.isLightColor ? .light : .dark
    }

    // MARK: - Copy actions

    private func copyAsMarkdown() {
        guard GhosttyApp.terminalPasteboard.writeString(
            panel.content,
            to: .general
        ) else { return }
        flashCopyConfirmation(.markdown)
    }

    private func copyAsHTML() {
        Task { @MainActor in
            guard let html = await panel.rendererSession.renderedHTML(markdown: panel.content) else { return }
            let text = await panel.rendererSession.renderedText() ?? panel.content
            // public.html for rich-text-aware targets (Notes, Mail, Pages, ...)
            // and a plain-text fallback so plain editors still receive content.
            let item = NSPasteboardItem()
            _ = item.setString(html, forType: .html)
            _ = item.setString(text, forType: .string)
            guard GhosttyApp.terminalPasteboard.replaceContents(
                of: .general,
                with: [item]
            ) else { return }
            flashCopyConfirmation(.html)
        }
    }

    private func flashCopyConfirmation(_ kind: CopyConfirmation) {
        copyConfirmationGeneration &+= 1
        let generation = copyConfirmationGeneration
        copyConfirmation = kind
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard copyConfirmationGeneration == generation else { return }
            if copyConfirmation == kind {
                copyConfirmation = nil
            }
        }
    }

    // MARK: - Focus Flash

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.current.values.first ?? 0

        for segment in FocusFlashPattern.current.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        }
    }
}

// MARK: - Toolbar

private struct MarkdownPanelToolbar: View {
    let confirmation: String?
    let onCopyMarkdown: () -> Void
    let onCopyHTML: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let confirmation {
                Text(confirmation)
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }

            toolbarButton(
                title: String(localized: "markdown.toolbar.copyMarkdown", defaultValue: "Copy as Markdown"),
                systemImage: "doc.on.doc",
                action: onCopyMarkdown
            )
            toolbarButton(
                title: String(localized: "markdown.toolbar.copyHTML", defaultValue: "Copy as HTML"),
                systemImage: "chevron.left.forwardslash.chevron.right",
                action: onCopyHTML
            )
        }
        .animation(.easeOut(duration: 0.15), value: confirmation)
    }

    private func toolbarButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        PanelHeaderIconButton(
            systemName: systemImage,
            label: title,
            action: action
        )
    }
}
