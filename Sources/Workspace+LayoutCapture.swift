import Bonsplit
import Foundation

enum SavedLayoutCaptureError: Error, Equatable, LocalizedError {
    case unsupportedSplitOrientation(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSplitOrientation(let orientation):
            return "Unsupported split orientation in layout capture: \(orientation)"
        }
    }
}

struct BreeWorkspaceLayoutCapture {
    var workspace: BreeWorkspaceDefinition
    var unsupportedSurfaceCount: Int
}

extension Workspace {
    func captureLayoutDefinition() throws -> BreeWorkspaceLayoutCapture {
        var unsupportedSurfaceCount = 0
        let baseCwd = currentDirectory
        let root = try captureLayoutNode(
            from: bonsplitController.treeSnapshot(),
            baseCwd: baseCwd,
            unsupportedSurfaceCount: &unsupportedSurfaceCount
        )
        let workspaceDefinition = BreeWorkspaceDefinition(
            name: nil,
            cwd: baseCwd,
            color: customColor,
            env: workspaceEnvironment.isEmpty ? nil : workspaceEnvironment,
            layout: root
        )
        return BreeWorkspaceLayoutCapture(
            workspace: workspaceDefinition,
            unsupportedSurfaceCount: unsupportedSurfaceCount
        )
    }

    private func captureLayoutNode(
        from node: ExternalTreeNode,
        baseCwd: String,
        unsupportedSurfaceCount: inout Int
    ) throws -> BreeLayoutNode {
        switch node {
        case .split(let split):
            let direction: BreeSplitDirection
            switch split.orientation.lowercased() {
            case "horizontal":
                direction = .horizontal
            case "vertical":
                direction = .vertical
            default:
                throw SavedLayoutCaptureError.unsupportedSplitOrientation(split.orientation)
            }
            return .split(
                BreeSplitDefinition(
                    direction: direction,
                    split: Self.clampedSavedLayoutSplit(split.dividerPosition),
                    children: [
                        try captureLayoutNode(from: split.first, baseCwd: baseCwd, unsupportedSurfaceCount: &unsupportedSurfaceCount),
                        try captureLayoutNode(from: split.second, baseCwd: baseCwd, unsupportedSurfaceCount: &unsupportedSurfaceCount),
                    ]
                )
            )
        case .pane(let pane):
            let surfaces = captureSurfaces(
                from: pane,
                baseCwd: baseCwd,
                unsupportedSurfaceCount: &unsupportedSurfaceCount
            )
            return .pane(BreePaneDefinition(surfaces: surfaces.isEmpty ? [BreeSurfaceDefinition(type: .terminal)] : surfaces))
        }
    }

    private func captureSurfaces(
        from pane: ExternalPaneNode,
        baseCwd: String,
        unsupportedSurfaceCount: inout Int
    ) -> [BreeSurfaceDefinition] {
        guard let paneUUID = UUID(uuidString: pane.id) else {
            unsupportedSurfaceCount += pane.tabs.count
            return []
        }
        var surfaces: [BreeSurfaceDefinition] = []
        surfaces.reserveCapacity(max(pane.tabs.count, 1))
        for tab in bonsplitController.tabs(inPane: PaneID(id: paneUUID)) {
            guard let panelId = panelIdFromSurfaceId(tab.id),
                  let panel = panels[panelId] else {
                unsupportedSurfaceCount += 1
                surfaces.append(BreeSurfaceDefinition(type: .terminal))
                continue
            }
            surfaces.append(
                captureSurfaceDefinition(
                    panelId: panelId,
                    panel: panel,
                    baseCwd: baseCwd,
                    unsupportedSurfaceCount: &unsupportedSurfaceCount
                )
            )
        }
        return surfaces
    }

    private func captureSurfaceDefinition(
        panelId: UUID,
        panel: any Panel,
        baseCwd: String,
        unsupportedSurfaceCount: inout Int
    ) -> BreeSurfaceDefinition {
        var definition: BreeSurfaceDefinition
        switch panel.panelType {
        case .terminal:
            definition = BreeSurfaceDefinition(
                type: .terminal,
                name: savedLayoutPanelName(panelId),
                command: nil,
                cwd: savedLayoutTerminalCwd(panelId: panelId, baseCwd: baseCwd),
                env: nil,
                url: nil,
                focus: nil
            )
        case .browser:
            definition = BreeSurfaceDefinition(
                type: .browser,
                name: savedLayoutPanelName(panelId),
                command: nil,
                cwd: nil,
                env: nil,
                url: browserPanel(for: panelId)?.currentURL?.absoluteString,
                focus: nil
            )
        case .project:
            // Apply-side rebuilds project panes from `url ?? cwd`; a project
            // surface without a path cannot be restored, so emit a counted
            // placeholder terminal instead of an unrestorable node.
            let projectPath = (panel as? ProjectPanel)?.projectURL.path ?? ""
            if projectPath.isEmpty {
                unsupportedSurfaceCount += 1
                definition = BreeSurfaceDefinition(type: .terminal)
            } else {
                definition = BreeSurfaceDefinition(
                    type: .project,
                    name: savedLayoutPanelName(panelId),
                    command: nil,
                    cwd: Self.savedLayoutRelocatablePath(projectPath, baseCwd: baseCwd) ?? ".",
                    env: nil,
                    url: nil,
                    focus: nil
                )
            }
        case .markdown, .filePreview, .rightSidebarTool, .customSidebar, .extensionBrowser, .workspaceTodo, .notifications:
            unsupportedSurfaceCount += 1
            definition = BreeSurfaceDefinition(type: .terminal)
        }
        // The declarative schema models only the single focused surface
        // (`focus`); per-pane tab selection is not representable without a
        // schema extension, so non-focused multi-tab panes reopen with their
        // first tab selected (tracked in
        // https://github.com/ecyx00/bree/issues/7444).
        if focusedPanelId == panelId {
            definition.focus = true
        }
        return definition
    }

    private func savedLayoutPanelName(_ panelId: UUID) -> String? {
        let trimmed = panelCustomTitles[panelId]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func savedLayoutTerminalCwd(panelId: UUID, baseCwd: String) -> String? {
        let candidates = [
            panelDirectories[panelId],
            terminalPanel(for: panelId)?.directory,
            terminalPanel(for: panelId)?.requestedWorkingDirectory,
        ]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { continue }
            return Self.savedLayoutRelocatablePath(trimmed, baseCwd: baseCwd)
        }
        return nil
    }

    /// Store paths so `applyCustomLayout`'s `resolveCwd` re-roots them under a
    /// different base cwd: nil at the base itself, a relative path under the
    /// base, and absolute only for paths outside the base (which should not
    /// relocate).
    private static func savedLayoutRelocatablePath(_ path: String, baseCwd: String) -> String? {
        let normalized = (path as NSString).standardizingPath
        let base = (baseCwd as NSString).standardizingPath
        if normalized == base { return nil }
        if !base.isEmpty, normalized.hasPrefix(base + "/") {
            return String(normalized.dropFirst(base.count + 1))
        }
        return normalized
    }

    private static func clampedSavedLayoutSplit(_ value: Double) -> Double {
        min(0.9, max(0.1, value))
    }
}
