import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import SwiftUI

/// Stacks the workspace's main split above its bottom panel and owns the
/// draggable divider. The main content keeps a stable position in the stack, so
/// opening or closing the panel never remounts its terminals.
struct WorkspaceBottomPanelLayout<Main: View>: View {
    @ObservedObject var workspace: Workspace
    let isWorkspaceVisible: Bool
    let rightSidebarOwnsInputFocus: Bool
    let windowAppearance: WindowAppearanceSnapshot
    @ViewBuilder let main: () -> Main

    @State private var dragStartHeight: CGFloat?
    @State private var isHoveringDivider = false

    /// Hit area of the divider; the visible line stays 1 pt (2 pt while hovered).
    private static var dividerHitHeight: CGFloat { 8 }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                main()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let store = workspace._dockSplit, store.isBottomPanelOpen {
                    let panelHeight = store.resolvedBottomPanelHeight(forContentHeight: proxy.size.height)
                    divider(store: store, panelHeight: panelHeight, contentHeight: proxy.size.height)
                    DockPanelView(
                        store: store,
                        isPanelVisible: isWorkspaceVisible,
                        rootDirectory: nil,
                        windowAppearance: windowAppearance,
                        rightSidebarOwnsInputFocus: rightSidebarOwnsInputFocus,
                        unreadSource: TerminalNotificationStore.shared.sidebarUnread
                    )
                    .id("bottomPanel.\(store.workspaceId.uuidString)")
                    .frame(maxWidth: .infinity)
                    .frame(height: panelHeight)
                }
            }
        }
    }

    private func divider(store: DockSplitStore, panelHeight: CGFloat, contentHeight: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(isHoveringDivider ? BreeChromePaletteStore.shared.palette.activeIndicator : BreeChromePaletteStore.shared.palette.separator)
                .frame(height: isHoveringDivider ? 2 : 1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.dividerHitHeight)
        .contentShape(Rectangle())
            .onHover { inside in
                guard inside != isHoveringDivider else { return }
                isHoveringDivider = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartHeight ?? panelHeight
                        dragStartHeight = start
                        let maxHeight = max(
                            DockSplitStore.bottomPanelMinHeight,
                            contentHeight * DockSplitStore.bottomPanelMaxHeightFraction
                        )
                        let proposed = start - value.translation.height
                        store.bottomPanelHeight = Double(
                            min(max(proposed, DockSplitStore.bottomPanelMinHeight), maxHeight)
                        )
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
            .accessibilityIdentifier("BottomPanelDivider")
    }
}
