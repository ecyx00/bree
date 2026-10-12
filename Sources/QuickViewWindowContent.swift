import AppKit
import Bonsplit
import CmuxFoundation
import SwiftUI

/// Quick View chrome in the transparent title bar over the existing panel view:
/// `[<] [>] title/path ... [Pin] [Open Externally] [x]`.
struct QuickViewWindowContent: View {
    let resource: QuickViewResource
    let panel: any Panel
    let initialAppearance: PanelAppearance
    let canGoBack: Bool
    let canGoForward: Bool
    let onBack: () -> Void
    let onForward: () -> Void
    let onPin: () -> Void
    let onOpenExternally: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.breePalette) private var palette
    /// Rebuilt when the theme or palette changes, so the window follows live theme edits.
    @State private var liveAppearance: PanelAppearance?

    /// The panel appearance with the content background replaced by `surfaceOverlay`.
    private static func overlayAppearance(_ base: PanelAppearance) -> PanelAppearance {
        PanelAppearance(
            backgroundColor: BreeChromePalette.currentSnapshot.ns.surfaceOverlay,
            foregroundColor: base.foregroundColor,
            dividerColor: base.dividerColor,
            unfocusedOverlayNSColor: base.unfocusedOverlayNSColor,
            unfocusedOverlayOpacity: base.unfocusedOverlayOpacity,
            usesClearContentBackground: base.usesClearContentBackground
        )
    }

    private var appearance: PanelAppearance { liveAppearance ?? Self.overlayAppearance(initialAppearance) }

    var body: some View {
        // Content sits below the transparent title bar (safe area); Pin/x live in the bar itself.
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.surfaceOverlay.ignoresSafeArea())
            .breeSurfaceColorScheme()
            .overlay(alignment: .top) { titlebar }
            .onReceive(NotificationCenter.default.publisher(for: BreeChromePaletteStore.didChangeNotification)) { _ in
                liveAppearance = Self.overlayAppearance(PanelAppearance.fromConfig(
                    WorkspaceContentView.resolveGhosttyAppearanceConfig(reason: "quickViewTheme")
                ))
            }
        .id(panel.id)
    }

    private var titlebar: some View {
        HStack(spacing: 8) {
            QuickViewIconButton(
                systemName: "chevron.left",
                label: String(localized: "quickView.back", defaultValue: "Back"),
                shortcut: "Cmd+[", isDisabled: !canGoBack, action: onBack
            )
            QuickViewIconButton(
                systemName: "chevron.right",
                label: String(localized: "quickView.forward", defaultValue: "Forward"),
                shortcut: "Cmd+]", isDisabled: !canGoForward, action: onForward
            )
            Text(resource.title).breeFont(.body, weight: .medium)
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1).truncationMode(.middle)
            Text(resource.subtitle).breeFont(.secondary).foregroundStyle(palette.textSecondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if case .file(let path, _, _) = resource { OpenInObsidianButton(path: path) }
            if let artifact = panel as? ArtifactPanel { ArtifactToolbarItems(panel: artifact) }
            if let markdown = panel as? MarkdownPanel { MarkdownSourceToggleButton(panel: markdown) }
            if case .folder = resource {} else {
                Button(action: onPin) {
                    Text(String(localized: "quickView.pin", defaultValue: "Pin"))
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "quickView.pin", defaultValue: "Pin"))
                .help(String(localized: "quickView.pin.help", defaultValue: "Keep as a tab (Cmd+Return)"))
            }
            QuickViewIconButton(
                systemName: "arrow.up.forward.square",
                label: String(localized: "filePreview.openExternally", defaultValue: "Open Externally"),
                action: onOpenExternally
            )
            QuickViewIconButton(
                systemName: "xmark",
                label: String(localized: "quickView.close", defaultValue: "Close Quick View"),
                shortcut: "Esc", action: onClose
            )
        }
        .buttonStyle(.borderless)
        .padding(.leading, 78) // clears the traffic lights
        .padding(.trailing, 10)
        .frame(height: 28)
        .background(QuickViewWindowDragArea())
        .help(resource.detail)
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder
    private var content: some View {
        if let panel = panel as? MarkdownPanel {
            MarkdownPanelView(
                panel: panel, isFocused: true, isVisibleInUI: true, portalPriority: 1,
                appearance: appearance, onRequestPanelFocus: {}, showsObsidianButton: false
            )
        } else if let panel = panel as? FilePreviewPanel {
            FilePreviewPanelView(
                panel: panel, isFocused: true, isVisibleInUI: true, portalPriority: 1,
                appearance: appearance, onRequestPanelFocus: {}
            )
        } else if let panel = panel as? ArtifactPanel {
            ArtifactPanelView(panel: panel, appearance: appearance)
        } else if let panel = panel as? BrowserPanel {
            BrowserPanelView(
                panel: panel, paneId: PaneID(), isFocused: true, isVisibleInUI: true, portalPriority: 1,
                paneOwnershipOverride: true,
                resolvedColorScheme: colorScheme, inheritedColorScheme: colorScheme,
                resolvedThemeBackgroundColor: appearance.backgroundColor,
                onRequestPanelFocus: {}
            )
            .id(panel.id)
        }
    }
}

/// "Open in Obsidian" for markdown notes inside a vault. Disabled, with a tooltip, when no app handles `obsidian://`.
struct OpenInObsidianButton: View {
    let path: String
    /// Render as a panel header icon (Markdown panel header) instead of a titlebar button.
    var asHeaderIcon = false

    var body: some View {
        if ObsidianVault.isVaultMarkdown(path) {
            let isInstalled = ObsidianVault.installedAppURL() != nil
            let help = isInstalled
                ? String(localized: "quickView.openInObsidian.help", defaultValue: "Open in Obsidian")
                : String(localized: "quickView.openInObsidian.unavailable", defaultValue: "Obsidian is not installed")
            if asHeaderIcon {
                PanelHeaderIconButton(systemName: "diamond", label: help, isDisabled: !isInstalled, action: open)
            } else {
                Button(action: open) {
                    Image(systemName: "diamond")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.breeIcon)
                .disabled(!isInstalled)
                .accessibilityLabel(help)
                .help(help)
            }
        }
    }

    private func open() {
        if let url = ObsidianVault.openURL(forPath: path) { NSWorkspace.shared.open(url) }
    }
}

/// Lets the titlebar row drag the window; buttons above it keep their clicks.
private struct QuickViewWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
