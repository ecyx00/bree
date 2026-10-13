import AppKit
import BreeFoundation
import BreeWorkspaces
import Foundation
import SwiftUI

/// Action surface for one pure-AppKit sidebar workspace row.
///
/// Mirrors the TabItemView action methods (selection with live modifier
/// handling, close families, notification marks, colors, moves) and builds the
/// row's full context menu as NSMenu. Menu construction runs on demand at
/// menu-open time, so reading `tab`/`tabManager` here is allowed — the
/// snapshot-boundary rule constrains render inputs, not action handlers.
@MainActor
struct SidebarWorkspaceRowCommands {
    let tab: Workspace
    weak var tabManager: TabManager?
    weak var notificationStore: TerminalNotificationStore?
    let index: Int
    let contextMenuWorkspaceIds: [UUID]
    let remoteContextMenuWorkspaceIds: [UUID]
    let allRemoteContextMenuTargetsConnecting: Bool
    let allRemoteContextMenuTargetsDisconnected: Bool
    let contextMenuPinState: WorkspaceActionDispatcher.PinState?
    let workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot
    /// Resolved bree scheme used for menu swatches.
    let colorScheme: ColorScheme
    /// Re-runs the row's snapshot pump (pin/notification mutations that don't
    /// flow through the observation publishers).
    let refreshSnapshot: () -> Void
    /// Sidebar-container selection state writers (captured SwiftUI bindings).
    let readSelectedTabIds: () -> Set<UUID>
    let writeSelectedTabIds: (Set<UUID>) -> Void
    let readLastSelectionIndex: () -> Int?
    let writeLastSelectionIndex: (Int?) -> Void
    let setSelectionToTabs: () -> Void
    /// Latest row snapshot for menu-time reads (SSH error, finder path).
    let snapshotProvider: () -> SidebarWorkspaceSnapshotBuilder.Snapshot?

    // MARK: Selection (parity with TabItemView.updateSelection)

    func updateSelection(modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
#if DEBUG
        breeDebugLog("sidebar.select.enter workspace=\(tab.id.uuidString.prefix(5)) hasTabManager=\(tabManager != nil)")
#endif
        guard let tabManager else { return }
        let isCommand = modifiers.contains(.command)
        let isShift = modifiers.contains(.shift)
        let wasSelected = tabManager.selectedTabId == tab.id
#if DEBUG
        breeDebugLog("sidebar.select workspace=\(tab.id.uuidString.prefix(5)) source=appKitRow")
#endif
        var selectedTabIds = readSelectedTabIds()
        let workspaceIds = tabManager.tabs.map(\.id)
        let anchorIds = Set(tabManager.workspaceGroups.compactMap(\.liveAnchorWorkspaceId))
        let selectionKindPolicy = SidebarSelectionKindPolicy()
        let shiftAnchorIndex = isShift
            ? SidebarWorkspaceSelectionSyncPolicy().shiftClickAnchorIndex(
                existingAnchorIndex: readLastSelectionIndex(),
                selectedWorkspaceIds: selectedTabIds,
                focusedWorkspaceId: tabManager.selectedTabId,
                liveWorkspaceIds: workspaceIds
            )
            : nil

        if isShift, let anchorIndex = shiftAnchorIndex {
            let lower = min(anchorIndex, index)
            let upper = max(anchorIndex, index)
            // Filter out workspaces hidden inside collapsed groups so a
            // Shift-click range never silently includes rows the user
            // can't see.
            let collapsedGroupIds: Set<UUID> = Set(
                tabManager.workspaceGroups
                    .filter { $0.isCollapsed }
                    .map(\.id)
            )
            let anchorIdsByGroup: [UUID: UUID] = Dictionary(
                uniqueKeysWithValues: tabManager.workspaceGroups.compactMap { group in
                    group.liveAnchorWorkspaceId.map { (group.id, $0) }
                }
            )
            let visibleRangeIds = tabManager.tabs[lower...upper].compactMap { tab -> UUID? in
                if let gid = tab.groupId,
                   collapsedGroupIds.contains(gid),
                   anchorIdsByGroup[gid] != tab.id {
                    return nil
                }
                return tab.id
            }
            selectedTabIds = Set(selectionKindPolicy.workspaceShiftRangeIds(
                rangeIds: Array(selectedTabIds),
                anchorIds: anchorIds
            ))
            let rangeIds = selectionKindPolicy.workspaceShiftRangeIds(
                rangeIds: visibleRangeIds,
                anchorIds: anchorIds
            )
            if isCommand {
                selectedTabIds.formUnion(rangeIds)
            } else {
                selectedTabIds = Set(rangeIds)
            }
        } else if isCommand {
            selectedTabIds = selectionKindPolicy.workspaceCmdClickSelection(
                current: selectedTabIds,
                clickedId: tab.id,
                anchorIds: anchorIds
            )
        } else {
            selectedTabIds = [tab.id]
        }
        writeSelectedTabIds(selectedTabIds)

        writeLastSelectionIndex(SidebarWorkspaceSelectionSyncPolicy().anchorIndexAfterWorkspaceClick(
            isShiftClick: isShift,
            resolvedShiftAnchorIndex: shiftAnchorIndex,
            clickedIndex: index
        ))
        tabManager.selectTab(tab)
        if wasSelected, !isCommand, !isShift {
            tabManager.dismissNotificationOnDirectInteraction(
                tabId: tab.id,
                surfaceId: tabManager.focusedSurfaceId(for: tab.id)
            )
        }
        setSelectionToTabs()
    }

    func closeWorkspace() {
        tabManager?.closeWorkspaceWithConfirmation(tab)
    }

    func reconnectRemoteConnection() {
        tab.reconnectRemoteConnection()
    }

    // MARK: Shared mutation helpers

    func syncSelectionAfterMutation() {
        guard let tabManager else { return }
        var selectedTabIds = readSelectedTabIds()
        let existingIds = Set(tabManager.tabs.map { $0.id })
        selectedTabIds = selectedTabIds.filter { existingIds.contains($0) }
        if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
            selectedTabIds = [selectedId]
        }
        writeSelectedTabIds(selectedTabIds)
        if let selectedId = tabManager.selectedTabId {
            writeLastSelectionIndex(tabManager.tabs.firstIndex { $0.id == selectedId })
        }
    }

    func moveBy(_ delta: Int) {
        guard let tabManager, tabManager.reorderWorkspace(tabId: tab.id, by: delta) else { return }
        writeSelectedTabIds([tab.id])
        writeLastSelectionIndex(tabManager.tabs.firstIndex { $0.id == tab.id })
        tabManager.selectTab(tab)
        setSelectionToTabs()
    }

    func closeTabs(_ targetIds: [UUID], allowPinned: Bool) {
        tabManager?.closeWorkspacesWithConfirmation(targetIds, allowPinned: allowPinned)
        syncSelectionAfterMutation()
    }

    /// Parity with TabItemView.beginWorkspaceDescriptionEditFromContextMenu.
    func beginDescriptionEdit() {
        guard let tabManager else { return }
        writeSelectedTabIds([tab.id])
        writeLastSelectionIndex(index)
        tabManager.selectTab(tab)
        setSelectionToTabs()
        _ = AppDelegate.shared?.requestEditWorkspaceDescriptionViaCommandPalette()
    }

    /// Parity with TabItemView.applyTabColor.
    func applyTabColor(_ hex: String?) {
        tabManager?.applyWorkspaceColor(hex, toWorkspaceIds: contextMenuWorkspaceIds)
    }

    func promptCustomColor() {
        guard let hex = WorkspaceCustomColorPrompt.run(
            currentHex: tab.customColor,
            presentingWindow: AppDelegate.shared?.mainWindowContainingWorkspace(tab.id)
        ) else { return }
        applyTabColor(hex)
    }

    /// Parity with TabItemView.moveWorkspaces(_:toWindow:).
    func moveWorkspaces(toWindow windowId: UUID) {
        guard let tabManager, let app = AppDelegate.shared else { return }
        let orderedWorkspaceIds = tabManager.tabs.compactMap { contextMenuWorkspaceIds.contains($0.id) ? $0.id : nil }
        guard !orderedWorkspaceIds.isEmpty else { return }
        for (index, workspaceId) in orderedWorkspaceIds.enumerated() {
            let shouldFocus = index == orderedWorkspaceIds.count - 1
            _ = app.moveWorkspaceToWindow(workspaceId: workspaceId, windowId: windowId, focus: shouldFocus)
        }
        writeSelectedTabIds(readSelectedTabIds().subtracting(orderedWorkspaceIds))
        syncSelectionAfterMutation()
    }

    /// Parity with TabItemView.moveWorkspacesToNewWindow.
    func moveWorkspacesToNewWindow() {
        guard let tabManager, let app = AppDelegate.shared else { return }
        let orderedWorkspaceIds = tabManager.tabs.compactMap { contextMenuWorkspaceIds.contains($0.id) ? $0.id : nil }
        guard let firstWorkspaceId = orderedWorkspaceIds.first else { return }
        let shouldFocusImmediately = orderedWorkspaceIds.count == 1
        guard let newWindowId = app.moveWorkspaceToNewWindow(workspaceId: firstWorkspaceId, focus: shouldFocusImmediately) else {
            return
        }
        if orderedWorkspaceIds.count > 1 {
            for (offset, workspaceId) in orderedWorkspaceIds.dropFirst().enumerated() {
                let isLast = offset == orderedWorkspaceIds.count - 2
                _ = app.moveWorkspaceToWindow(workspaceId: workspaceId, windowId: newWindowId, focus: isLast)
            }
        }
        writeSelectedTabIds(readSelectedTabIds().subtracting(orderedWorkspaceIds))
        syncSelectionAfterMutation()
    }

    // MARK: Menu

    /// - Parameter beginInlineRename: Starts the row's inline title editor;
    ///   "Rename Workspace…" edits in place because the row is on screen.
    func makeContextMenu(
        onOpen: @escaping () -> Void,
        onClose: @escaping () -> Void,
        beginInlineRename: @escaping () -> Void
    ) -> NSMenu {
        SidebarWorkspaceRowMenuBuilder(commands: self).build(
            onOpen: onOpen,
            onClose: onClose,
            beginInlineRename: beginInlineRename
        )
    }
}

/// Builds the workspace row context menu with exact SwiftUI parity
/// (section order, labels, pluralization, disable rules, submenus).
@MainActor
struct SidebarWorkspaceRowMenuBuilder {
    let commands: SidebarWorkspaceRowCommands

    private var tab: Workspace { commands.tab }
    private var targetIds: [UUID] { commands.contextMenuWorkspaceIds }
    private var isMulti: Bool { targetIds.count > 1 }

    private func label(multi: String, single: String) -> String {
        isMulti ? multi : single
    }

    func build(
        onOpen: @escaping () -> Void,
        onClose: @escaping () -> Void,
        beginInlineRename: @escaping () -> Void
    ) -> NSMenu {
        let menu = SidebarRowTrackedMenu()
        menu.autoenablesItems = false
        menu.onOpen = onOpen
        menu.onClose = onClose
        menu.delegate = menu
        guard let tabManager = commands.tabManager else { return menu }

        // Everyday items first; rare ones live under "More". Disabled items are hidden, not greyed.
        addPinItem(to: menu, tabManager: tabManager)
        if let notificationStore = commands.notificationStore {
            addNotificationMuteItem(to: menu, notificationStore: notificationStore)
            addMarkReadUnreadItem(to: menu, notificationStore: notificationStore)
        }
        menu.addItem(.separator())
        addRenameAndDescriptionItems(
            to: menu,
            tabManager: tabManager,
            beginInlineRename: beginInlineRename
        )
        addColorMenu(to: menu)
        addRemoteSection(to: menu, tabManager: tabManager)
        addSSHErrorItem(to: menu)
        menu.addItem(.separator())
        addGroupSection(to: menu, tabManager: tabManager)
        addMoveItems(to: menu, tabManager: tabManager)
        addCopyAndFinderItems(to: menu, tabManager: tabManager)
        menu.addItem(.separator())
        addCloseItems(to: menu, tabManager: tabManager)
        menu.addItem(.separator())
        addMoreMenu(to: menu, tabManager: tabManager)
        return menu
    }

    private func item(
        _ title: String,
        enabled: Bool = true,
        shortcut: StoredShortcut? = nil,
        action: @escaping () -> Void
    ) -> NSMenuItem {
        let item = SidebarRowMenuActionItem(title: title, run: action)
        item.isEnabled = enabled
        if let shortcut, let keyEquivalent = shortcut.menuItemKeyEquivalent {
            item.keyEquivalent = keyEquivalent
            item.keyEquivalentModifierMask = shortcut.modifierFlags
        }
        return item
    }

    private func addPinItem(to menu: NSMenu, tabManager: TabManager) {
        let shouldPin = commands.contextMenuPinState?.pinned ?? !tab.isPinned
        let pinLabel = shouldPin
            ? label(
                multi: String(localized: "contextMenu.pinWorkspaces", defaultValue: "Pin Workspaces"),
                single: String(localized: "contextMenu.pinWorkspace", defaultValue: "Pin Workspace"))
            : label(
                multi: String(localized: "contextMenu.unpinWorkspaces", defaultValue: "Unpin Workspaces"),
                single: String(localized: "contextMenu.unpinWorkspace", defaultValue: "Unpin Workspace"))
        menu.addItem(item(pinLabel, enabled: commands.contextMenuPinState != nil) { [commands] in
            guard let pinState = commands.contextMenuPinState, let tabManager = commands.tabManager else {
                NSSound.beep()
                return
            }
            let result = WorkspaceActionDispatcher.performPinAction(pinState, in: tabManager)
            if result.changedWorkspaceIds.isEmpty {
                commands.refreshSnapshot()
            }
            commands.syncSelectionAfterMutation()
        })
    }

    /// New-group, move-to-group and remove-from-group in one place. With no groups yet it is
    /// a single "New Group" item; otherwise a "Workspace Group" submenu. "New Empty Workspace
    /// Group" is not here: it needs no row (File menu, empty sidebar area, its shortcut).
    private func addGroupSection(to menu: NSMenu, tabManager: TabManager) {
        let targetWorkspaces = targetIds.compactMap { id in
            tabManager.tabs.first(where: { $0.id == id })
        }
        let existingAnchorIds = Set(tabManager.workspaceGroups.compactMap(\.liveAnchorWorkspaceId))
        let eligibleTargets = targetWorkspaces.filter { !existingAnchorIds.contains($0.id) }
        let eligibleTargetIds = eligibleTargets.map(\.id)
        guard !eligibleTargetIds.isEmpty else { return }

        let groups = commands.workspaceGroupMenuSnapshot.items
        let moveToGroupMenuState = WorkspaceGroupMoveToMenuState(groups: groups)
        let allTargetsInSameGroup: UUID? = {
            let groupIds = eligibleTargets.map(\.groupId)
            guard let first = groupIds.first, groupIds.allSatisfy({ $0 == first }) else { return nil }
            return first
        }()
        let hasAnyGroupedTarget = eligibleTargets.contains { $0.groupId != nil }

        let groupSelectedLabel = isMulti
            ? String(localized: "contextMenu.workspaceGroup.newFromSelection", defaultValue: "New Group from Selection")
            : String(localized: "contextMenu.workspaceGroup.newFromWorkspace", defaultValue: "New Group from Workspace")
        let newGroupItem = item(
            groupSelectedLabel,
            shortcut: KeyboardShortcutSettings.shortcut(for: .groupSelectedWorkspaces)
        ) { [weak tabManager] in
            guard let tabManager, !eligibleTargetIds.isEmpty else { return }
            tabManager.createWorkspaceGroup(name: "", childWorkspaceIds: eligibleTargetIds)
        }
        guard moveToGroupMenuState.rendersSubmenu || hasAnyGroupedTarget else {
            menu.addItem(newGroupItem)
            return
        }

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(newGroupItem)
        if moveToGroupMenuState.rendersSubmenu {
            let moveMenu = NSMenu()
            moveMenu.autoenablesItems = false
            for group in groups {
                moveMenu.addItem(item(group.name, enabled: allTargetsInSameGroup != group.id) { [weak tabManager] in
                    guard let tabManager else { return }
                    for id in eligibleTargetIds {
                        tabManager.addWorkspaceToGroup(workspaceId: id, groupId: group.id)
                    }
                })
            }
            let moveParent = item(
                String(localized: "contextMenu.workspaceGroup.moveTo", defaultValue: "Move to Group")
            ) {}
            moveParent.submenu = moveMenu
            submenu.addItem(moveParent)
        }
        if hasAnyGroupedTarget {
            submenu.addItem(item(
                String(localized: "contextMenu.workspaceGroup.remove", defaultValue: "Remove from Group")
            ) { [weak tabManager] in
                guard let tabManager else { return }
                for id in eligibleTargetIds {
                    tabManager.removeWorkspaceFromGroup(workspaceId: id)
                }
            })
        }
        let parent = item(String(localized: "contextMenu.workspaceGroup", defaultValue: "Workspace Group")) {}
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func addRenameAndDescriptionItems(
        to menu: NSMenu,
        tabManager: TabManager,
        beginInlineRename: @escaping () -> Void
    ) {
        menu.addItem(item(
            String(localized: "contextMenu.renameWorkspace", defaultValue: "Rename Workspace…"),
            shortcut: KeyboardShortcutSettings.shortcut(for: .renameWorkspace),
            action: beginInlineRename
        ))

        if !isMulti {
            menu.addItem(item(
                String(localized: "contextMenu.editWorkspaceDescription", defaultValue: "Edit Workspace Description…"),
                shortcut: KeyboardShortcutSettings.shortcut(for: .editWorkspaceDescription)
            ) { [commands] in
                commands.beginDescriptionEdit()
            })
        }
    }

    private func addRemoteSection(to menu: NSMenu, tabManager: TabManager) {
        guard !commands.remoteContextMenuWorkspaceIds.isEmpty else { return }
        menu.addItem(.separator())
        let remoteWorkspaces: () -> [Workspace] = { [weak tabManager, commands] in
            guard let tabManager else { return [] }
            return commands.remoteContextMenuWorkspaceIds.compactMap { workspaceId in
                tabManager.tabs.first(where: { $0.id == workspaceId })
            }
        }
        let reconnectLabel = label(
            multi: String(localized: "contextMenu.reconnectWorkspaces", defaultValue: "Reconnect Workspaces"),
            single: String(localized: "contextMenu.reconnectWorkspace", defaultValue: "Reconnect Workspace"))
        menu.addItem(item(reconnectLabel, enabled: !commands.allRemoteContextMenuTargetsConnecting) {
            for workspace in remoteWorkspaces() {
                workspace.reconnectRemoteConnection()
            }
        })
        let disconnectLabel = label(
            multi: String(localized: "contextMenu.disconnectWorkspaces", defaultValue: "Disconnect Workspaces"),
            single: String(localized: "contextMenu.disconnectWorkspace", defaultValue: "Disconnect Workspace"))
        menu.addItem(item(disconnectLabel, enabled: !commands.allRemoteContextMenuTargetsDisconnected) {
            for workspace in remoteWorkspaces() {
                workspace.disconnectRemoteConnection(clearConfiguration: false)
            }
        })
    }

    private func addColorMenu(to menu: NSMenu) {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let palette = WorkspaceTabColorSettings.palette()

        if tab.customColor != nil {
            let clearItem = item(String(localized: "contextMenu.clearColor", defaultValue: "Clear Color")) { [commands] in
                commands.applyTabColor(nil)
            }
            clearItem.image = RenderableSystemSymbol.configuredAppKitImage(
                systemName: "xmark.circle", pointSize: 13, weight: nil
            )
            submenu.addItem(clearItem)
        }

        let customItem = item(String(localized: "contextMenu.chooseCustomColor", defaultValue: "Choose Custom Color…")) { [commands] in
            commands.promptCustomColor()
        }
        customItem.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "paintpalette", pointSize: 13, weight: nil
        )
        submenu.addItem(customItem)

        if !palette.isEmpty {
            submenu.addItem(.separator())
        }
        SidebarWorkspaceRowColorMenu(
            currentColorHex: tab.customColor,
            colorScheme: commands.colorScheme
        ).addPaletteItems(
            to: submenu,
            palette: palette,
            apply: { [commands] hex in
                commands.applyTabColor(hex)
            }
        )
        let parent = item(String(localized: "contextMenu.workspaceColor", defaultValue: "Workspace Color")) {}
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func addSSHErrorItem(to menu: NSMenu) {
        guard let sshError = commands.snapshotProvider()?.copyableSidebarSSHError else { return }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "contextMenu.copySshError", defaultValue: "Copy SSH Error")) {
            WorkspaceSurfaceIdentifierClipboardText.copy(sshError)
        })
    }

    private func addMoveItems(to menu: NSMenu, tabManager: TabManager) {
        let referenceWindowId = AppDelegate.shared?.windowId(for: tabManager)
        let windowMoveTargets = AppDelegate.shared?.windowMoveTargets(referenceWindowId: referenceWindowId) ?? []
        let moveMenuTitle = isMulti
            ? String(localized: "contextMenu.moveWorkspacesToWindow", defaultValue: "Move Workspaces to Window")
            : String(localized: "contextMenu.moveWorkspaceToWindow", defaultValue: "Move Workspace to Window")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(item(
            String(localized: "contextMenu.newWindow", defaultValue: "New Window"),
            enabled: !targetIds.isEmpty
        ) { [commands] in
            commands.moveWorkspacesToNewWindow()
        })
        if !windowMoveTargets.isEmpty {
            submenu.addItem(.separator())
        }
        for target in windowMoveTargets {
            submenu.addItem(item(
                target.label,
                enabled: !(target.isCurrentWindow || targetIds.isEmpty)
            ) { [commands] in
                commands.moveWorkspaces(toWindow: target.windowId)
            })
        }
        let parent = item(moveMenuTitle, enabled: !targetIds.isEmpty) {}
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func addCloseItems(to menu: NSMenu, tabManager: TabManager) {
        let closeLabel = label(
            multi: String(localized: "contextMenu.closeWorkspaces", defaultValue: "Close Workspaces"),
            single: String(localized: "contextMenu.closeWorkspace", defaultValue: "Close Workspace"))
        menu.addItem(item(
            closeLabel,
            enabled: !targetIds.isEmpty,
            shortcut: KeyboardShortcutSettings.shortcut(for: .closeWorkspace)
        ) { [commands] in
            commands.closeTabs(commands.contextMenuWorkspaceIds, allowPinned: true)
        })
        // Bulk closes are rare: one submenu, and only the entries that apply.
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        if !(tabManager.tabs.count <= 1 || targetIds.count == tabManager.tabs.count) {
            submenu.addItem(item(
                String(localized: "contextMenu.closeOtherWorkspaces", defaultValue: "Close Other Workspaces")
            ) { [weak tabManager, commands] in
                guard let tabManager else { return }
                let keepIds = Set(commands.contextMenuWorkspaceIds)
                let idsToClose = tabManager.tabs.compactMap { keepIds.contains($0.id) ? nil : $0.id }
                commands.closeTabs(idsToClose, allowPinned: true)
            })
        }
        if commands.index < tabManager.tabs.count - 1 {
            submenu.addItem(item(
                String(localized: "contextMenu.closeWorkspacesBelow", defaultValue: "Close Workspaces Below")
            ) { [weak tabManager, commands] in
                guard let tabManager,
                      let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == commands.tab.id }) else { return }
                let idsToClose = tabManager.tabs.suffix(from: anchorIndex + 1).map { $0.id }
                commands.closeTabs(idsToClose, allowPinned: true)
            })
        }
        if commands.index != 0 {
            submenu.addItem(item(
                String(localized: "contextMenu.closeWorkspacesAbove", defaultValue: "Close Workspaces Above")
            ) { [weak tabManager, commands] in
                guard let tabManager,
                      let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == commands.tab.id }) else { return }
                let idsToClose = tabManager.tabs.prefix(upTo: anchorIndex).map { $0.id }
                commands.closeTabs(idsToClose, allowPinned: true)
            })
        }
        guard !submenu.items.isEmpty else { return }
        let parent = item(String(localized: "contextMenu.closeMultiple", defaultValue: "Close Multiple")) {}
        parent.submenu = submenu
        menu.addItem(parent)
    }

    /// Rare and technical items, kept reachable but off the first level.
    private func addMoreMenu(to menu: NSMenu, tabManager: TabManager) {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(item(
            String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top"),
            enabled: !targetIds.isEmpty
        ) { [weak tabManager, commands] in
            guard let tabManager else { return }
            tabManager.moveTabsToTop(Set(commands.contextMenuWorkspaceIds))
            commands.syncSelectionAfterMutation()
        })
        if tab.hasCustomTitle {
            submenu.addItem(item(
                String(localized: "contextMenu.removeCustomWorkspaceName", defaultValue: "Remove Custom Workspace Name")
            ) { [weak tabManager, tab] in
                tabManager?.clearCustomTitle(tabId: tab.id)
            })
        }
        if !isMulti, tab.hasCustomDescription {
            submenu.addItem(item(
                String(localized: "contextMenu.clearWorkspaceDescription", defaultValue: "Clear Workspace Description")
            ) { [weak tabManager, tab] in
                tabManager?.clearCustomDescription(tabId: tab.id)
            })
        }
        if let notificationStore = commands.notificationStore {
            addClearLatestNotificationItem(to: submenu, notificationStore: notificationStore)
        }
        addPauseResumeItem(to: submenu)
        let parent = item(String(localized: "contextMenu.more", defaultValue: "More")) {}
        parent.submenu = submenu
        menu.addItem(parent)
    }

    /// Resource guard: SIGSTOP/SIGCONT the selected pane's foreground process group.
    private func addPauseResumeItem(to menu: NSMenu) {
        guard !isMulti, let workspace = commands.tabManager?.tabs.first(where: { $0.id == tab.id }) else { return }
        let paused = ResourceGuard.shared.isPaused(workspaceId: workspace.id)
        let title = paused
            ? String(localized: "contextMenu.resumeProcess", defaultValue: "Resume Suspended Process")
            : String(localized: "contextMenu.pauseProcess", defaultValue: "Suspend Running Process (SIGSTOP)")
        menu.addItem(item(title) { [weak workspace] in
            guard let workspace else { return }
            ResourceGuard.shared.togglePause(workspace: workspace)
        })
    }

    /// One entry instead of two: "Mark as Read" when the workspace has unread items, else "Mark as Unread".
    private func addMarkReadUnreadItem(to menu: NSMenu, notificationStore: TerminalNotificationStore) {
        if notificationStore.canMarkWorkspaceRead(forTabIds: targetIds) {
            menu.addItem(item(label(
                multi: String(localized: "contextMenu.markWorkspacesRead", defaultValue: "Mark Workspaces as Read"),
                single: String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read"))
            ) { [weak notificationStore, commands] in
                guard let notificationStore else { return }
                for id in commands.contextMenuWorkspaceIds where
                    notificationStore.canMarkWorkspaceRead(forTabIds: [id]) {
                    notificationStore.markRead(forTabId: id)
                }
            })
        } else if notificationStore.canMarkWorkspaceUnread(forTabIds: targetIds) {
            menu.addItem(item(label(
                multi: String(localized: "contextMenu.markWorkspacesUnread", defaultValue: "Mark Workspaces as Unread"),
                single: String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread"))
            ) { [weak notificationStore, commands] in
                guard let notificationStore else { return }
                for id in commands.contextMenuWorkspaceIds where
                    notificationStore.canMarkWorkspaceUnread(forTabIds: [id]) {
                    notificationStore.markUnread(forTabId: id)
                }
            })
        }
    }

    private func addClearLatestNotificationItem(to menu: NSMenu, notificationStore: TerminalNotificationStore) {
        guard targetIds.contains(where: { notificationStore.latestNotification(forTabId: $0) != nil }) else { return }
        menu.addItem(item(label(
            multi: String(localized: "contextMenu.clearLatestNotifications", defaultValue: "Clear Latest Notifications"),
            single: String(localized: "contextMenu.clearLatestNotification", defaultValue: "Clear Latest Notification"))
        ) { [weak notificationStore, commands] in
            guard let notificationStore else { return }
            for id in commands.contextMenuWorkspaceIds {
                notificationStore.clearLatestNotification(forTabId: id)
            }
        })
    }

    private func addNotificationMuteItem(
        to menu: NSMenu,
        notificationStore: TerminalNotificationStore
    ) {
        let allMuted = notificationStore.allWorkspaceNotificationsMuted(forTabIds: targetIds)
        let title = allMuted
            ? (isMulti ? NotificationMuteMenuOption.unmuteWorkspaces : .unmuteWorkspace).title
            : (isMulti ? NotificationMuteMenuOption.muteWorkspaces : .muteWorkspace).title
        let item = item(title, enabled: !targetIds.isEmpty) { [weak notificationStore, commands] in
            guard let notificationStore else { return }
            let shouldMute = !notificationStore.allWorkspaceNotificationsMuted(
                forTabIds: commands.contextMenuWorkspaceIds
            )
            _ = notificationStore.setWorkspaceNotificationsMuted(
                shouldMute,
                forTabIds: commands.contextMenuWorkspaceIds
            )
            commands.refreshSnapshot()
        }
        item.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: allMuted ? "bell" : "bell.slash",
            pointSize: 13,
            weight: nil
        )
        menu.addItem(item)
    }

    private func addCopyAndFinderItems(to menu: NSMenu, tabManager: TabManager) {
        if !isMulti, let finderPath = commands.snapshotProvider()?.finderDirectoryPath {
            menu.addItem(item(
                String(localized: "contextMenu.showWorkspaceInFinder", defaultValue: "Show in Finder")
            ) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: finderPath, isDirectory: true)])
            })
        }
    }

    /// Parity with TabItemView.coloredCircleImage.
    static func coloredCircleImage(color: NSColor, diameter: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        return image
    }
}

/// NSMenu subclass reporting open/close so the controller keeps hover stable.
@MainActor
final class SidebarRowTrackedMenu: NSMenu, NSMenuDelegate {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    func menuWillOpen(_ menu: NSMenu) {
        onOpen?()
    }

    func menuDidClose(_ menu: NSMenu) {
        onClose?()
    }
}

/// Closure-carrying menu item (no target/selector plumbing per item).
@MainActor
final class SidebarRowMenuActionItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(execute), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func execute() {
        run()
    }
}
