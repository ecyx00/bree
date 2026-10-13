import BreeCloud
import AppKit
import Foundation

// MARK: - New-workspace plus-button context menu

@MainActor
final class NewWorkspaceContextMenuActionBox: NSObject {
    let windowId: UUID
    let action: BreeResolvedConfigAction

    init(windowId: UUID, action: BreeResolvedConfigAction) {
        self.windowId = windowId
        self.action = action
    }
}

extension AppDelegate {

    @discardableResult
    func showNewWorkspaceContextMenu(
        anchorView: NSView,
        event: NSEvent,
        debugSource: String = "titlebar.newWorkspace.contextMenu"
    ) -> Bool {
        let context = contextForMainWindow(anchorView.window)
            ?? mainWindowContext(forShortcutEvent: event, debugSource: debugSource)
            ?? preferredMainWindowContextForWorkspaceCreation(event: event, debugSource: debugSource)
        guard let context,
              let breeConfigStore = context.breeConfigStore else {
            return false
        }

        guard let menu = makeNewWorkspaceContextMenu(
            context: context,
            breeConfigStore: breeConfigStore
        ) else {
            return false
        }

        NSMenu.popUpContextMenu(menu, with: event, for: anchorView)
        return true
    }

    /// Pops the menu below `anchorView`, or at `location` (in `anchorView`
    /// coordinates) when the caller only knows where the click landed.
    @discardableResult
    func showNewWorkspaceContextMenu(
        anchorView: NSView,
        at location: NSPoint? = nil,
        debugSource: String = "titlebar.newWorkspace.contextMenu"
    ) -> Bool {
        let context = contextForMainWindow(anchorView.window)
            ?? preferredMainWindowContextForWorkspaceCreation(event: nil, debugSource: debugSource)
        guard let context,
              let breeConfigStore = context.breeConfigStore else {
            return false
        }

        guard let menu = makeNewWorkspaceContextMenu(
            context: context,
            breeConfigStore: breeConfigStore
        ) else {
            return false
        }

        menu.popUp(
            positioning: nil,
            at: location ?? NSPoint(x: 0, y: anchorView.bounds.maxY + 2),
            in: anchorView
        )
        return true
    }

    func makeNewWorkspaceContextMenu(
        context: MainWindowContext,
        breeConfigStore: BreeConfigStore,
        isAuthenticated: Bool? = nil
    ) -> NSMenu? {
        let isAuthenticated = isAuthenticated ?? (AppDelegate.shared?.auth?.accountFlow.isAuthenticated == true)
        let model = NewWorkspaceMenuModel.build(
            newWorkspaceContextMenuItems: breeConfigStore.newWorkspaceContextMenuItems.filter { item in
                guard case .action(let menuAction) = item,
                      case .builtIn(let builtIn) = menuAction.action.action else { return true }
                return Self.isBuiltInActionAvailableInNewWorkspaceMenu(builtIn, isAuthenticated: isAuthenticated)
            },
            templateNames: savedLayoutNames(),
            loadedActions: breeConfigStore.loadedActions,
            newWorkspaceActionID: breeConfigStore.newWorkspaceActionID,
            deletable: { [weak self, weak breeConfigStore] action in
                guard let self, let breeConfigStore else { return false }
                return isDeletableGlobalAction(action, breeConfigStore: breeConfigStore)
            }
        )
        return renderNewWorkspaceContextMenu(
            model: model,
            context: context,
            breeConfigStore: breeConfigStore
        )
    }

    /// Feature gates for built-in plus-menu rows, evaluated when the menu
    /// opens (not at config load) so flag and setting flips apply at once.
    /// Mirrors the command palette's gates for the same actions.
    static func isBuiltInActionAvailableInNewWorkspaceMenu(
        _ action: BreeSurfaceTabBarBuiltInAction,
        isAuthenticated: Bool? = nil
    ) -> Bool {
        switch action {
        case .newBrowser:
            return BrowserAvailabilitySettings.isEnabled()
        case .toggleFiles, .toggleArchitecture, .toggleWiki, .showBoard:
            return false
        case .newWorkspace, .newTerminal, .splitRight, .splitDown,
             .copyWorkingDirectory, .copyProjectRoot, .copyScreen, .newWindow:
            return true
        }
    }

    private func savedLayoutNames() -> [String] {
        ((try? SavedLayoutStore().list()) ?? []).map(\.name)
    }

    @objc func performNewWorkspaceContextMenuItem(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? NewWorkspaceContextMenuActionBox,
              let context = mainWindowContexts.values.first(where: { $0.windowId == box.windowId }),
              let window = resolvedWindow(for: context) else {
            NSSound.beep()
            return
        }
        let didExecute: Bool
        if case .builtIn(.newWorkspace) = box.action.action {
            // This menu row is an explicit local override of the context-following
            // New Workspace command. Do not inherit a Cloud-only working directory.
            didExecute = context.tabManager.addWorkspaceIfActive(
                inheritWorkingDirectory: context.tabManager.selectedWorkspace?.cloudVMID == nil
                    && context.tabManager.selectedWorkspace?.cloudVMBinding == nil
            ) != nil
        } else {
            didExecute = executeConfiguredBreeAction(box.action, context: context, preferredWindow: window)
        }
        guard didExecute else {
            NSSound.beep()
            return
        }
    }
}
