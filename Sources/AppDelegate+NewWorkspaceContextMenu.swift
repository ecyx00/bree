import CmuxCloud
import AppKit
import Foundation

// MARK: - New-workspace plus-button context menu

@MainActor
final class NewWorkspaceContextMenuActionBox: NSObject {
    let windowId: UUID
    let action: CmuxResolvedConfigAction

    init(windowId: UUID, action: CmuxResolvedConfigAction) {
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
              let cmuxConfigStore = context.cmuxConfigStore else {
            return false
        }

        guard let menu = makeNewWorkspaceContextMenu(
            context: context,
            cmuxConfigStore: cmuxConfigStore
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
              let cmuxConfigStore = context.cmuxConfigStore else {
            return false
        }

        guard let menu = makeNewWorkspaceContextMenu(
            context: context,
            cmuxConfigStore: cmuxConfigStore
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
        cmuxConfigStore: CmuxConfigStore,
        isAuthenticated: Bool? = nil
    ) -> NSMenu? {
        let isAuthenticated = isAuthenticated ?? (AppDelegate.shared?.auth?.accountFlow.isAuthenticated == true)
        let model = NewWorkspaceMenuModel.build(
            newWorkspaceContextMenuItems: cmuxConfigStore.newWorkspaceContextMenuItems.filter { item in
                guard case .action(let menuAction) = item,
                      case .builtIn(let builtIn) = menuAction.action.action else { return true }
                return Self.isBuiltInActionAvailableInNewWorkspaceMenu(builtIn, isAuthenticated: isAuthenticated)
            },
            templateNames: savedLayoutNames(),
            loadedActions: cmuxConfigStore.loadedActions,
            newWorkspaceActionID: cmuxConfigStore.newWorkspaceActionID,
            deletable: { [weak self, weak cmuxConfigStore] action in
                guard let self, let cmuxConfigStore else { return false }
                return isDeletableGlobalAction(action, cmuxConfigStore: cmuxConfigStore)
            }
        )
        return renderNewWorkspaceContextMenu(
            model: model,
            context: context,
            cmuxConfigStore: cmuxConfigStore
        )
    }

    /// Feature gates for built-in plus-menu rows, evaluated when the menu
    /// opens (not at config load) so flag and setting flips apply at once.
    /// Mirrors the command palette's gates for the same actions.
    static func isBuiltInActionAvailableInNewWorkspaceMenu(
        _ action: CmuxSurfaceTabBarBuiltInAction,
        isAuthenticated: Bool? = nil
    ) -> Bool {
        switch action {
        case .newBrowser:
            return BrowserAvailabilitySettings.isEnabled()
        case .toggleFiles, .toggleArchitecture, .toggleWiki:
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
            didExecute = executeConfiguredCmuxAction(box.action, context: context, preferredWindow: window)
        }
        guard didExecute else {
            NSSound.beep()
            return
        }
    }
}
