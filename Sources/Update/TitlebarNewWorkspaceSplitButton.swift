import SwiftUI
import AppKit
import BreeFoundation
import BreeSettings

/// Geometry shared by the visible split button and the hidden minimal-mode
/// click lanes (`TitlebarControlsHitRegions`), so both stay in lockstep.
enum TitlebarNewWorkspaceSplitButtonMetrics {
    /// Both segments are at least a compact icon target (20 pt) wide; the bar height is unchanged.
    static func primaryWidth(config: TitlebarControlsStyleConfig) -> CGFloat {
        max(BreeMetrics.compactIconButtonSize, config.iconSize + 4, config.buttonSize - 3)
    }

    static func dropdownWidth(config: TitlebarControlsStyleConfig) -> CGFloat {
        max(BreeMetrics.compactIconButtonSize, floor(config.buttonSize * 0.70))
    }

    static func dropdownIconSize(config: TitlebarControlsStyleConfig) -> CGFloat { max(6, config.iconSize - 6) }

    static func totalWidth(config: TitlebarControlsStyleConfig) -> CGFloat { primaryWidth(config: config) + dropdownWidth(config: config) }
}

/// The titlebar "+" control: a primary segment that creates a workspace and a
/// caret segment that opens the New Workspace menu (the same menu right-click
/// shows on either segment).
struct TitlebarNewWorkspaceSplitButton: View {
    let config: TitlebarControlsStyleConfig
    let foregroundColor: Color
    let onNewTab: () -> Void
    @State private var menuAnchorView: NSView?
    @State private var hoveredSegment: TitlebarNewWorkspaceSplitButtonSegment?
    private var palette: BreeChromePalette { BreeChromePaletteStore.shared.palette }

    private var dropdownWidth: CGFloat {
        TitlebarNewWorkspaceSplitButtonMetrics.dropdownWidth(config: config)
    }

    private var primaryWidth: CGFloat {
        TitlebarNewWorkspaceSplitButtonMetrics.primaryWidth(config: config)
    }

    private var isHovering: Bool { hoveredSegment != nil }

    private var foregroundOpacity: Double {
        titlebarControlForegroundOpacity(isHovering: isHovering, isPressed: false, isEnabled: true)
    }

    private var borderOpacity: Double {
        titlebarControlBorderOpacity(config: config, isHovering: isHovering, isPressed: false, isEnabled: true)
    }

    /// Makes each segment's full frame interactive, including transparent label space.
    var body: some View {
        HStack(spacing: 0) {
            Button(action: onNewTab) {
                ZStack {
                    Rectangle()
                        .fill(Color.clear)
                    BreeSystemSymbolImage(
                        systemName: "plus",
                        pointSize: config.iconSize,
                        weight: .regular,
                        tint: foregroundColor.opacity(foregroundOpacity)
                    )
                }
                .frame(width: primaryWidth, height: config.buttonSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: primaryWidth, height: config.buttonSize)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("titlebarControl.newTab")
            .accessibilityLabel(String(localized: "titlebar.newWorkspace.accessibilityLabel", defaultValue: "New Workspace"))
            .overlay {
                TitlebarSplitButtonRightClickView { anchorView, event in
                    _ = AppDelegate.shared?.showNewWorkspaceContextMenu(anchorView: anchorView, event: event)
                }
            }
            .background(segmentBackground(for: .newTab))
            .onHover { hovering in
                updateHoveredSegment(.newTab, hovering: hovering)
            }
            .safeHelp(KeyboardShortcutSettings.Action.newTab.tooltip(String(localized: "titlebar.newWorkspace.tooltip", defaultValue: "New workspace")))

            Button(
                action: {
                    guard let menuAnchorView else { return }
                    _ = AppDelegate.shared?.showNewWorkspaceContextMenu(
                        anchorView: menuAnchorView,
                        debugSource: "titlebar.newWorkspace.menu"
                    )
                }
            ) {
                ZStack {
                    Rectangle()
                        .fill(Color.clear)
                    BreeSystemSymbolImage(
                        systemName: "chevron.down",
                        pointSize: TitlebarNewWorkspaceSplitButtonMetrics.dropdownIconSize(config: config),
                        weight: .regular,
                        tint: foregroundColor.opacity(foregroundOpacity)
                    )
                }
                .frame(width: dropdownWidth, height: config.buttonSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: dropdownWidth, height: config.buttonSize)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("titlebarControl.newWorkspaceMenu")
            .accessibilityLabel(String(localized: "titlebar.newWorkspace.menu.accessibilityLabel", defaultValue: "New Workspace Menu"))
            .background(TitlebarControlAnchorView { menuAnchorView = $0 })
            .overlay {
                TitlebarSplitButtonRightClickView { anchorView, event in
                    _ = AppDelegate.shared?.showNewWorkspaceContextMenu(
                        anchorView: anchorView,
                        event: event,
                        debugSource: "titlebar.newWorkspace.menu.rightClick"
                    )
                }
            }
            .background(segmentBackground(for: .menu))
            .onHover { hovering in
                updateHoveredSegment(.menu, hovering: hovering)
            }
            .safeHelp(String(localized: "titlebar.newWorkspace.menu.tooltip", defaultValue: "New workspace options"))
        }
        .foregroundStyle(foregroundColor.opacity(foregroundOpacity))
        .frame(width: primaryWidth + dropdownWidth, height: config.buttonSize)
        .background {
            if config.buttonBackground && !isHovering {
                RoundedRectangle(cornerRadius: config.buttonCornerRadius, style: .continuous)
                    .fill(palette.surfaceRaised)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: config.buttonCornerRadius, style: .continuous))
        .overlay {
            if borderOpacity > 0 {
                RoundedRectangle(cornerRadius: config.buttonCornerRadius, style: .continuous)
                    .stroke(palette.separator, lineWidth: 0.5)
            }
        }
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.12), value: hoveredSegment)
        .background(TitlebarChromeGeometryReporter(keyPrefix: "titlebarControl_newTabSplit"))
        .titlebarInteractiveControl()
    }

    /// Hovered segment gets `hoverFill`; the passive segment of a hovered
    /// pair stays unfilled (the old 1.6% tint was below visibility).
    private func segmentBackground(for segment: TitlebarNewWorkspaceSplitButtonSegment) -> Color {
        hoveredSegment == segment ? palette.hoverFill : .clear
    }

    private func updateHoveredSegment(
        _ segment: TitlebarNewWorkspaceSplitButtonSegment,
        hovering: Bool
    ) {
        guard titlebarControlsShouldTrackButtonHover(config: config) else { return }
        if hovering {
            hoveredSegment = segment
        } else if hoveredSegment == segment {
            hoveredSegment = nil
        }
    }
}

private enum TitlebarNewWorkspaceSplitButtonSegment: Equatable {
    case newTab
    case menu
}

private struct TitlebarSplitButtonRightClickView: NSViewRepresentable {
    let onRightMouseDown: (NSView, NSEvent) -> Void

    func makeNSView(context: Context) -> TitlebarSplitButtonRightClickNSView {
        let view = TitlebarSplitButtonRightClickNSView()
        view.onRightMouseDown = onRightMouseDown
        return view
    }

    func updateNSView(_ nsView: TitlebarSplitButtonRightClickNSView, context: Context) {
        nsView.onRightMouseDown = onRightMouseDown
    }
}

private final class TitlebarSplitButtonRightClickNSView: NSView {
    var onRightMouseDown: ((NSView, NSEvent) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point),
              NSApp.currentEvent?.type == .rightMouseDown else {
            return nil
        }
        return self
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightMouseDown?(self, event)
    }
}
