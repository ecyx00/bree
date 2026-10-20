import Foundation

/// Socket v2 surface for the Bree features that used to be reachable only by
/// clicking: `bottom_panel.*`, `attention.*`, `quick_view.*` and `pins.*`.
///
/// Threading: every handler touches AppKit or SwiftUI-backed model state, so the
/// body runs through `v2MainSync` (the same hop `file.open` uses). Parameters are
/// parsed before the hop.
///
/// Focus: none of these methods focuses anything unless the caller passes
/// `focus: true`; the methods that accept it are listed in
/// `explicitFocusParamV2Methods`, which is what lets `v2FocusAllowed` say yes.
///
/// Remote relay: none of these methods is allowlisted in `RemoteRelayCommandPolicy`,
/// so a `bree ssh` session cannot reach them.
extension TerminalController {
    enum BreeBottomPanelAction {
        case status, open, close, toggle
    }

    // MARK: - Shared helpers

    private func v2BreeError(_ code: String, _ message: String) -> V2CallResult {
        .err(code: code, message: message, data: nil)
    }

    private func v2BreeWorkspaceNotFound() -> V2CallResult {
        v2BreeError("not_found", String(
            localized: "socket.bree.error.workspaceNotFound",
            defaultValue: "Workspace not found."
        ))
    }

    /// Resolves the target workspace (`window_id` / `workspace_id`, default: the selected
    /// workspace of the active window) and runs `body` on the main actor.
    private func v2BreeWithWorkspace(
        params: [String: Any],
        _ body: @MainActor (TabManager, Workspace) -> V2CallResult
    ) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return v2BreeWorkspaceNotFound()
        }
        return v2MainSync {
            guard let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return v2BreeWorkspaceNotFound()
            }
            return body(tabManager, workspace)
        }
    }

    @MainActor
    private func v2BreeIdentity(tabManager: TabManager, workspace: Workspace) -> [String: Any] {
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return [
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": workspace.id.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
        ]
    }

    private func v2BreeRemoteWorkspaceError() -> V2CallResult {
        v2BreeError("unsupported", String(
            localized: "socket.bree.error.remoteWorkspace",
            defaultValue: "This command only works on local workspaces."
        ))
    }

    /// An absolute path (after `~` expansion and standardizing), or the error to return.
    private func v2BreeAbsolutePath(_ params: [String: Any]) -> (path: String?, error: V2CallResult?) {
        let raw = (v2String(params, "path") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let path = NSString(string: NSString(string: raw).expandingTildeInPath).standardizingPath
        guard !raw.isEmpty, path.hasPrefix("/") else {
            return (nil, v2BreeError("invalid_params", String(
                localized: "socket.bree.error.absolutePathRequired",
                defaultValue: "An absolute path is required."
            )))
        }
        return (path, nil)
    }

    private func v2BreePathNotFound(_ path: String) -> V2CallResult {
        .err(
            code: "not_found",
            message: String(localized: "socket.bree.error.pathNotFound", defaultValue: "Path not found."),
            data: ["path": path]
        )
    }

    // MARK: - bottom_panel.*

    /// `bottom_panel.status|open|close|toggle`. Status returns `open` and `height`
    /// (points; null while the panel still uses its default 30% of the content height).
    /// `open` and `toggle` accept `focus` (default false).
    func v2BottomPanel(params: [String: Any], action: BreeBottomPanelAction) -> V2CallResult {
        let wantsFocus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)
        return v2BreeWithWorkspace(params: params) { tabManager, workspace in
            let opening: Bool?
            switch action {
            case .status: opening = nil
            case .open: opening = true
            case .close: opening = false
            case .toggle: opening = !workspace.isBottomPanelOpen
            }
            if let opening {
                if opening, wantsFocus {
                    v2MaybeFocusWindow(for: tabManager)
                    v2MaybeSelectWorkspace(tabManager, workspace: workspace)
                }
                // Closing an already closed panel reports false; that is not an error.
                let changed = workspace.setBottomPanelOpen(opening, focus: wantsFocus, seedTerminal: true)
                if opening, !changed, !workspace.isBottomPanelOpen {
                    return v2BreeError("unavailable", String(
                        localized: "socket.bree.error.bottomPanelUnavailable",
                        defaultValue: "The bottom panel could not be opened."
                    ))
                }
            }
            var payload = v2BreeIdentity(tabManager: tabManager, workspace: workspace)
            payload["open"] = workspace.isBottomPanelOpen
            payload["height"] = v2OrNull(workspace._dockSplit?.bottomPanelHeight)
            return .ok(payload)
        }
    }

    // MARK: - attention.*

    private func v2BreeAttentionStateName(_ state: AttentionState?) -> Any {
        switch state {
        case .thermal: return "thermal"
        case .needsInput: return "needs_input"
        case .failed: return "failed"
        case .done: return "done"
        case .running: return "running"
        case nil: return NSNull()
        }
    }

    /// `attention.list`: the Attention Center rows, ranked as the panel shows them.
    /// A row with `state: null` is a changes-only row (files changed while away).
    func v2AttentionList() -> V2CallResult {
        v2MainSync {
            let items = AttentionStore.shared.rankedItems().map { item -> [String: Any] in
                [
                    "id": item.id,
                    "workspace_id": item.workspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: item.workspaceId),
                    "surface_id": v2OrNull(item.panelId?.uuidString),
                    "surface_ref": v2Ref(kind: .surface, uuid: item.panelId),
                    "workspace_title": item.workspaceTitle,
                    "pane_title": v2OrNull(item.paneTitle),
                    "agent": v2OrNull(item.agentName),
                    "state": v2BreeAttentionStateName(item.state),
                    "since_ms": v2OrNull(item.sinceMs),
                    "last_prompt": v2OrNull(item.lastPrompt),
                    "last_output": v2OrNull(item.lastOutput),
                    "needs_approval": item.needsApproval,
                    "label": v2OrNull(AttentionStyle.word(for: item.state, needsApproval: item.needsApproval)),
                    "changed_count": item.changedCount,
                ]
            }
            return .ok(["items": items, "count": items.count])
        }
    }

    /// `attention.clear [id]`: dismisses the away-change lists, the only part of the
    /// Attention Center the user can clear (Delete on a row). Agent rows come from live
    /// agent state and go away when the agent does. With `id` it dismisses the list of
    /// that row's workspace, exactly like Delete on the row; without it, every list.
    func v2AttentionClear(params: [String: Any]) -> V2CallResult {
        let rawId = v2String(params, "id")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return v2MainSync {
            let store = AttentionStore.shared
            guard let rawId, !rawId.isEmpty else {
                let workspaceIds = Array(store.changeLogs.keys)
                for workspaceId in workspaceIds { store.dismissChanges(workspaceId: workspaceId) }
                return .ok(["cleared": workspaceIds.count])
            }
            guard let item = store.rankedItems().first(where: { $0.id == rawId }) else {
                return v2BreeError("not_found", String(
                    localized: "socket.bree.error.attentionItemNotFound",
                    defaultValue: "No Attention item with that id."
                ))
            }
            let hadChanges = store.changeLogs[item.workspaceId] != nil
            store.dismissChanges(workspaceId: item.workspaceId)
            return .ok(["cleared": hadChanges ? 1 : 0, "id": rawId])
        }
    }

    // MARK: - quick_view.*

    /// `quick_view.open path [focus]`: opens a file (or folder grid) in Quick View for the
    /// target workspace through `QuickViewResource.open`, the call the Files sidebar makes.
    /// Without `focus: true` the window is ordered front but does not take key focus.
    func v2QuickViewOpen(params: [String: Any]) -> V2CallResult {
        let resolved = v2BreeAbsolutePath(params)
        if let error = resolved.error { return error }
        guard let path = resolved.path else { return v2BreeWorkspaceNotFound() }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return v2BreePathNotFound(path)
        }
        let isFolder = isDirectory.boolValue
        let activate = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)
        return v2BreeWithWorkspace(params: params) { tabManager, workspace in
            guard !workspace.usesRemoteDirectoryProvenance else { return v2BreeRemoteWorkspaceError() }
            let resource: QuickViewResource = isFolder ? .folder(path: path) : .file(path: path)
            resource.open(from: workspace, activate: activate)
            var payload = v2BreeIdentity(tabManager: tabManager, workspace: workspace)
            payload["path"] = path
            payload["kind"] = isFolder ? "folder" : "file"
            payload["open"] = QuickViewWindowController.hasVisibleWindow
            return .ok(payload)
        }
    }

    /// `quick_view.close`: closes every visible Quick View window.
    func v2QuickViewClose() -> V2CallResult {
        v2MainSync { .ok(["closed": QuickViewWindowController.closeAllVisibleWindows()]) }
    }

    /// `quick_view.status`: whether Quick View is on screen and what it shows.
    func v2QuickViewStatus() -> V2CallResult {
        v2MainSync {
            let windows = QuickViewWindowController.visibleSummaries.map {
                ["title": $0.title, "path": $0.detail]
            }
            return .ok(["open": !windows.isEmpty, "windows": windows])
        }
    }

    // MARK: - pins.*

    @MainActor
    private func v2BreePinsPayload(
        tabManager: TabManager,
        workspace: Workspace,
        root: String,
        extra: [String: Any] = [:]
    ) -> V2CallResult {
        let pins = PinnedFilesStore().pins(forRoot: root).map { relative -> [String: Any] in
            let absolute = PinnedFilesStore.absolutePath(for: relative, root: root)
            return [
                "path": relative,
                "absolute_path": absolute,
                "exists": FileManager.default.fileExists(atPath: absolute),
            ]
        }
        var payload = v2BreeIdentity(tabManager: tabManager, workspace: workspace)
        payload["root"] = root
        payload["pins"] = pins
        for (key, value) in extra { payload[key] = value }
        return .ok(payload)
    }

    /// `pins.list|add|remove`: the pinned files of the target workspace's project root
    /// (nearest `.git` ancestor of its current directory). `add` takes an existing file
    /// inside the root, like the Files sidebar's Pin item; `remove` also works for a
    /// file that no longer exists.
    func v2Pins(params: [String: Any], action: String) -> V2CallResult {
        let absolutePath: String?
        if action != "list" {
            let resolved = v2BreeAbsolutePath(params)
            if let error = resolved.error { return error }
            absolutePath = resolved.path
        } else {
            absolutePath = nil
        }
        return v2BreeWithWorkspace(params: params) { tabManager, workspace in
            guard !workspace.usesRemoteDirectoryProvenance else { return v2BreeRemoteWorkspaceError() }
            let root = PinnedFilesStore.projectRoot(forDirectory: workspace.currentDirectory)
            let store = PinnedFilesStore()
            guard let path = absolutePath else {
                return v2BreePinsPayload(tabManager: tabManager, workspace: workspace, root: root)
            }
            let changed: Bool
            if action == "add" {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                    return v2BreePathNotFound(path)
                }
                guard !isDirectory.boolValue, PinnedFilesStore.relativePath(for: path, root: root) != nil else {
                    return v2BreeError("invalid_params", String(
                        localized: "socket.bree.error.pinNotAllowed",
                        defaultValue: "Only files inside the project can be pinned."
                    ))
                }
                changed = store.pin(path: path, root: root)
            } else {
                let wasPinned = store.isPinned(path: path, root: root)
                store.unpin(path: path, root: root)
                changed = wasPinned
            }
            return v2BreePinsPayload(
                tabManager: tabManager,
                workspace: workspace,
                root: root,
                extra: ["changed": changed]
            )
        }
    }
}
