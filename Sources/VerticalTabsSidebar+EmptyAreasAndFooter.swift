import AppKit
import BreeAppKitSupportUI
import BreeFoundation
import BreeSidebar
import BreeSidebarProviderKit
import BreeWorkspaces
import SwiftUI

/// Footer debug controls and empty-area drop targets for the vertical tabs sidebar, extracted from `ContentView.swift`, which sits at its file-length budget.
struct SidebarFooterIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarFooterIconButtonStyleBody(configuration: configuration)
    }
}

enum SidebarFooterButtonMetrics {
    static let buttonSize: CGFloat = 22
    static let hoverOpacity = 0.08
}

enum SidebarFooterControl: CaseIterable, Equatable {
    case shortcutDiscovery
    case extensions
}

enum SidebarFooterPresentationPolicy {
    static func isVisible(
        _ control: SidebarFooterControl,
        presentationMode: WorkspacePresentationModeSettings.Mode
    ) -> Bool {
        presentationMode != .minimal
    }
}

#if DEBUG
enum SidebarFooterIconButtonDebugSettings {
    static let hoverOpacityKey = "debug.sidebarFooterIconButton.hoverOpacity"
    static let defaultHoverOpacity = SidebarFooterButtonMetrics.hoverOpacity
}

#endif

private struct SidebarFooterIconButtonStyleBody: View {
    let configuration: SidebarFooterIconButtonStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
#if DEBUG
    @AppStorage(SidebarFooterIconButtonDebugSettings.hoverOpacityKey)
    private var debugHoverOpacity = SidebarFooterIconButtonDebugSettings.defaultHoverOpacity
#endif

    @Environment(\.breePalette) private var palette

    private var fillColor: Color {
        guard isEnabled else { return .clear }
        if configuration.isPressed { return palette.pressedFill }
        return isHovered ? palette.hoverFill : .clear
    }

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: BreeMetrics.radiusControl, style: .continuous)
                    .fill(fillColor)
            )
            .onHover { hovering in
                isHovered = hovering
            }
            .chromeRevealAnimation(isVisible: isHovered, fadeOut: .easeOut(duration: 0.12))
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

#if DEBUG
struct SidebarDevFooter: View {
    @Environment(\.breePalette) private var palette
    @ObservedObject var fileExplorerState: FileExplorerState
    let modifierKeyMonitor: WindowScopedShortcutHintModifierMonitor
    @AppStorage(DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
    private var showSidebarDevBuildBanner = DevBuildBannerDebugSettings.defaultShowSidebarBanner

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SidebarFooterButtons(fileExplorerState: fileExplorerState, modifierKeyMonitor: modifierKeyMonitor)
            if showSidebarDevBuildBanner {
                Text(String(localized: "debug.devBuildBanner.title", defaultValue: "THIS IS A DEV BUILD"))
                    .breeFont(.title)
                    .foregroundColor(palette.signalError)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.bottom, 6)
    }
}
#endif

struct SidebarEmptyArea: View {
    @Environment(\.breeAccentColor) private var breeAccent
    @EnvironmentObject var tabManager: TabManager
    let rowSpacing: CGFloat
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let dragAutoScrollController: SidebarDragAutoScrollController
    // Value snapshot + closure bundles instead of an @Observable store
    // reference (snapshot-boundary rule).
    let topDropIndicatorVisible: Bool
    var tabDropDelegate: SidebarTabDropDelegate? = nil
    let bonsplitDropIndicator: Binding<SidebarDropIndicator?>
    var expandsVertically = true
    var minimumHeight: CGFloat? = nil

    var body: some View {
        dropTarget
            .overlay {
                SidebarBonsplitTabNewWorkspaceDropOverlay(
                    tabManager: tabManager,
                    selectedTabIds: $selectedTabIds,
                    lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                    dropIndicator: bonsplitDropIndicator
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .top) {
                if topDropIndicatorVisible {
                    Rectangle()
                        .fill(breeAccent.color)
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .offset(y: -(rowSpacing / 2))
                }
            }
    }

    @ViewBuilder
    private var dropTarget: some View {
        let base = hitTarget
            .onTapGesture(count: 2) {
                // Both sidebar implementations (this one and the AppKit table)
                // share one entry point so a configured `ui.newWorkspace.action`,
                // and the remote-tmux mirror routing, behave identically here and
                // for the `+` button.
                if let appDelegate = AppDelegate.shared {
                    appDelegate.performSidebarEmptyAreaNewWorkspaceAction(tabManager: tabManager)
                } else {
                    tabManager.addWorkspaceIfActive(placementOverride: .end)
                }
                if let selectedId = tabManager.selectedTabId {
                    selectedTabIds = [selectedId]
                    lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
                }
                selection = .tabs
            }
        if let tabDropDelegate {
            base
                .sidebarEmptyAreaWorkspaceGroupContextMenu(tabManager: tabManager)
                .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: tabDropDelegate)
        } else {
            base
                .sidebarEmptyAreaWorkspaceGroupContextMenu(tabManager: tabManager)
        }
    }

    @ViewBuilder
    private var hitTarget: some View {
        if expandsVertically {
            // This full-height background extends behind the rows. Keep it
            // SwiftUI-only so native hit testing cannot steal row presses;
            // the AppKit table and clip view own native-sidebar window drags.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        } else {
            Color.clear
                .frame(maxWidth: .infinity, minHeight: minimumHeight ?? 0)
                .contentShape(Rectangle())
        }
    }
}

private extension View {
    func sidebarEmptyAreaWorkspaceGroupContextMenu(tabManager: TabManager) -> some View {
        contextMenu {
            let newWorkspaceGroupShortcut = KeyboardShortcutSettings.shortcut(for: .newWorkspaceGroup)
            let newWorkspaceGroupLabel = String(
                localized: "contextMenu.workspaceGroup.newEmpty",
                defaultValue: "New Empty Workspace Group"
            )
            if let key = newWorkspaceGroupShortcut.keyEquivalent {
                Button(newWorkspaceGroupLabel) {
                    _ = AppDelegate.shared?.createEmptyWorkspaceGroup(tabManager: tabManager)
                }
                .keyboardShortcut(key, modifiers: newWorkspaceGroupShortcut.eventModifiers)
            } else {
                Button(newWorkspaceGroupLabel) {
                    _ = AppDelegate.shared?.createEmptyWorkspaceGroup(tabManager: tabManager)
                }
            }
        }
    }
}

struct ExtensionSidebarBrowserStackEmptyArea: View {
    @Environment(\.breeAccentColor) private var breeAccent
    let rowSpacing: CGFloat
    let orderedRows: [ExtensionSidebarBrowserStackDropRow]
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var draggedTabId: UUID?
    @Binding var dropIndicator: SidebarDropIndicator?
    let onNewTab: () -> Void
    let onMove: (BreeSidebarProviderWorkspaceMove) -> Bool

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture(count: 2, perform: onNewTab)
            .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: ExtensionSidebarBrowserStackEndDropDelegate(
                orderedRows: orderedRows,
                draggedTabId: $draggedTabId,
                dragAutoScrollController: dragAutoScrollController,
                dropIndicator: $dropIndicator,
                onMove: onMove
            ))
            .overlay(alignment: .top) {
                if shouldShowTopDropIndicator {
                    Rectangle()
                        .fill(breeAccent.color)
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .offset(y: -(rowSpacing / 2))
                }
            }
    }

    private var shouldShowTopDropIndicator: Bool {
        guard let indicator = dropIndicator else { return false }
        if indicator.tabId == nil {
            return true
        }
        guard indicator.edge == .bottom, let lastWorkspaceId = orderedRows.last?.workspaceId else { return false }
        return indicator.tabId == lastWorkspaceId
    }
}

private struct ExtensionSidebarBrowserStackEndDropDelegate: DropDelegate {
    let orderedRows: [ExtensionSidebarBrowserStackDropRow]
    @Binding var draggedTabId: UUID?
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var dropIndicator: SidebarDropIndicator?
    let onMove: (BreeSidebarProviderWorkspaceMove) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier])
            && draggedTabId != nil
            && orderedRows.count > 1
    }

    func dropEntered(info: DropInfo) {
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator()
    }

    func dropExited(info: DropInfo) {
        if dropIndicator?.tabId == nil {
            dropIndicator = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator()
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedTabId = nil
            dropIndicator = nil
            dragAutoScrollController.stop()
        }
        guard let draggedTabId,
              let insertionPosition = insertionPositionForEndMove(draggedWorkspaceId: draggedTabId),
              let move = ExtensionSidebarBrowserStackDropPlanner(orderedRows: orderedRows).move(
                draggedWorkspaceId: draggedTabId,
                insertionPosition: insertionPosition
              ) else {
            return false
        }
        return onMove(move)
    }

    private func updateDropIndicator() {
        let workspaceIds = orderedRows.map(\.workspaceId)
        let nextIndicator = SidebarDropPlanner().indicator(
            draggedTabId: draggedTabId,
            targetTabId: nil,
            tabIds: workspaceIds,
            pinnedTabIds: []
        )
        guard dropIndicator != nextIndicator else { return }
        dropIndicator = nextIndicator
    }

    private func insertionPositionForEndMove(draggedWorkspaceId: UUID) -> Int? {
        let workspaceIds = orderedRows.map(\.workspaceId)
        guard workspaceIds.contains(draggedWorkspaceId) else { return nil }
        guard SidebarDropPlanner().indicator(
            draggedTabId: draggedWorkspaceId,
            targetTabId: nil,
            tabIds: workspaceIds,
            pinnedTabIds: []
        ) != nil else {
            return nil
        }
        return workspaceIds.count
    }
}
