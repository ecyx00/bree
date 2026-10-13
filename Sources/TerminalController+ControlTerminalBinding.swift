import BreeControlSocket
import BreeTerminal
import Foundation
import GhosttyKit
import OSLog

/// One control-plane terminal destination after workspace ownership and live
/// runtime identity have been reconciled.
///
/// The workspace panel remains the structural owner (pane placement,
/// hibernation state, close/respawn), while `surface` is the process registry's
/// canonical runtime model for socket I/O. They are normally identical. A
/// replacement overlap can make them differ briefly; I/O follows the registry
/// instead of pinning itself to the outgoing panel wrapper.
@MainActor
struct ControlTerminalSocketTarget {
    nonisolated private static let logger = Logger(
        subsystem: "com.bree.app",
        category: "socket.terminal-binding"
    )

    let surfaceID: UUID
    let panel: TerminalPanel
    let surface: TerminalSurface
    let bindingState: ControlTerminalSocketBindingState

    /// Sends socket text through the canonical surface while preserving the
    /// panel-owned hibernation resume path when both owners already agree.
    func sendInputResult(_ text: String) -> TerminalSurface.InputSendResult {
        if surface === panel.surface {
            return panel.sendInputResult(text)
        }
        return surface.sendInputResult(text)
    }

    /// Resumes a hibernated agent for a remote viewer's attach. Like explicit
    /// input, this goes through the panel only when both owners agree.
    func resumeAgentHibernationForRemoteAttach() {
        guard surface === panel.surface else { return }
        panel.resumeAgentHibernationForRemoteAttach()
    }

    /// Sends a bracketed-paste payload through the canonical surface.
    func sendText(_ text: String) -> Bool {
        sendTextResult(text).accepted
    }

    func sendTextResult(_ text: String) -> TerminalSurface.TextSendResult {
        if surface === panel.surface {
            return panel.sendTextResult(text)
        }
        return surface.sendTextResult(text)
    }

    /// Sends a named key through the canonical surface, retaining the panel's
    /// explicit-input resume behavior for an ordinary bound target.
    func sendNamedKeyResult(_ key: String) -> TerminalSurface.NamedKeySendResult {
        if surface === panel.surface {
            return panel.sendNamedKeyResult(key)
        }
        return surface.sendNamedKey(key)
    }

    /// Performs a Ghostty binding action against the canonical surface.
    func performBindingAction(_ action: String) -> Bool {
        guard surface.liveSurfaceForGhosttyAccess(
            reason: "socket.bindingAction"
        ) != nil else { return false }
        if surface === panel.surface {
            return panel.performBindingAction(action)
        }
        return surface.performExplicitInputBindingAction(action)
    }

    /// Performs a read-only/internal binding without emitting explicit-input
    /// notifications (used by VT export and snapshot capture).
    func performInternalBindingAction(_ action: String) -> Bool {
        guard surface.liveSurfaceForGhosttyAccess(
            reason: "socket.internalBindingAction"
        ) != nil else { return false }
        return surface.performInternalBindingAction(action)
    }

    /// Requests a renderer refresh from the canonical surface.
    func forceRefresh(reason: String) {
        surface.forceRefresh(reason: reason)
    }
}

@MainActor
extension Workspace {
    /// Reconciles an already-resolved workspace terminal with the canonical
    /// live registry surface without repeating topology projection.
    func controlSocketTerminalTarget(
        for owned: (surfaceID: UUID, panel: TerminalPanel)
    ) -> ControlTerminalSocketTarget? {
        ControlTerminalSocketTarget.resolve(
            surfaceID: owned.surfaceID,
            panel: owned.panel,
            workspaceID: id
        )
    }

    /// Resolves an explicitly addressed workspace terminal for socket I/O.
    func controlSocketTerminalTarget(for requestedSurfaceID: UUID) -> ControlTerminalSocketTarget? {
        guard let owned = controlTerminalTarget(for: requestedSurfaceID) else { return nil }
        return controlSocketTerminalTarget(for: owned)
    }

    /// Resolves a legacy input-style panel target, including active remote-tmux
    /// projection, against the canonical live registry surface.
    func controlSocketTerminalInputTarget(
        for requestedPanelID: UUID
    ) -> ControlTerminalSocketTarget? {
        guard let owned = terminalInputTarget(forPanelID: requestedPanelID) else {
            return nil
        }
        return controlSocketTerminalTarget(for: owned)
    }

    /// Resolves the pane-selected or focused workspace terminal for socket I/O.
    func controlDefaultSocketTerminalTarget(
        paneID: UUID?
    ) -> ControlTerminalSocketTarget? {
        guard let owned = controlDefaultTerminalTarget(paneID: paneID) else { return nil }
        return controlSocketTerminalTarget(for: owned)
    }
}

@MainActor
extension TerminalController {
    /// Resolves a legacy v1 surface argument to the canonical socket target.
    ///
    /// The v1 protocol accepts either a UUID or an ordered panel index and
    /// projects remote-tmux containers to their active pane. Keeping that
    /// topology resolution here lets every socket input verb share the same
    /// registry-backed rebinding path.
    func controlSocketTerminalTarget(
        fromLegacySurfaceArgument argument: String,
        tabManager: TabManager
    ) -> ControlTerminalSocketTarget? {
        guard let selectedID = tabManager.selectedTabId,
              let workspace = tabManager.tabs.first(where: { $0.id == selectedID }) else {
            return nil
        }

        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        let panelID: UUID
        if let uuid = UUID(uuidString: trimmed) {
            panelID = uuid
        } else if let index = Int(trimmed), index >= 0 {
            let panels = orderedPanels(in: workspace)
            guard index < panels.count else { return nil }
            panelID = panels[index].id
        } else {
            return nil
        }

        return workspace.controlSocketTerminalInputTarget(for: panelID)
    }

    /// Resolves a terminal request to its structural workspace and
    /// canonical live socket target in one main-actor hop.
    func mobileCanonicalTerminalTarget(
        params: [String: Any]
    ) -> (
        workspace: Workspace,
        surfaceID: UUID,
        target: ControlTerminalSocketTarget
    )? {
        guard let resolved = mobileResolveWorkspaceAndSurface(
            params: params,
            requireTerminal: true
        ), let surfaceID = resolved.surfaceId,
              let target = resolved.workspace.controlSocketTerminalInputTarget(
                  for: surfaceID
              ) else {
            return nil
        }
        return (resolved.workspace, surfaceID, target)
    }

    /// `terminal.paste`: deliver a composed block as a bracketed paste followed
    /// by an optional single submit key (`return`/`enter` default, `ctrl+enter`,
    /// or `none`). A `return` intent is upgraded to the agent-aware submit key
    /// once the surface is resolved. A submit-key failure after the text was
    /// accepted is reported as `submitted: false` plus `submit_error`, never as
    /// an RPC error, so a retry cannot paste the block twice.
    func v2TerminalPaste(params: [String: Any]) async -> V2CallResult {
        guard let text = v2RawString(params, "text"), !text.isEmpty else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        let submitKeyRaw = (v2String(params, "submit_key") ?? "return").lowercased()
        var submitKeyName: String?
        var submitKeyWasReturnIntent = false
        switch submitKeyRaw {
        case "", "return", "enter":
            submitKeyName = "return"
            submitKeyWasReturnIntent = true
        case "ctrl+enter":
            submitKeyName = "ctrl+enter"
        case "none":
            submitKeyName = nil
        default:
            return .err(code: "invalid_params", message: "Unsupported submit_key", data: ["submit_key": submitKeyRaw])
        }
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileCanonicalTerminalTarget(params: params) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }
        let surfaceId = resolved.surfaceID
        let terminalTarget = resolved.target
        let terminalPanel = terminalTarget.panel

        guard terminalPasteInFlightSurfaceIDs.insert(surfaceId).inserted else {
            return .err(code: "busy", message: "A prompt is already being submitted to this terminal", data: nil)
        }
        defer { terminalPasteInFlightSurfaceIDs.remove(surfaceId) }

        if submitKeyWasReturnIntent {
            submitKeyName = TextBoxAgentDetection.composedPromptSubmitKey(
                containsNewline: text.contains("\n") || text.contains("\r"),
                context: WorkspaceContentView.terminalAgentContext(panel: terminalPanel, workspace: resolved.workspace)
            )
        }

        let textResult = terminalTarget.sendTextResult(text)
        let failureData: [String: Any] = ["surface_id": surfaceId.uuidString]
        switch textResult {
        case .sent, .queued:
            break
        case .inputQueueFull:
            return .err(code: "input_queue_full", message: Self.terminalInputQueueFullMessage, data: failureData)
        case .surfaceUnavailable:
            return .err(code: "surface_unavailable", message: Self.terminalSurfaceUnavailableMessage, data: failureData)
        case .processExited:
            return .err(code: "process_exited", message: Self.terminalProcessExitedMessage, data: failureData)
        }

        var submitted = false
        var submitError: String?
        if let submitKeyName {
            // Keep the submit key in a separate input turn, with margin for
            // agent editors' paste-protection window.
            let generation = terminalTarget.surface.runtimeSurfaceGeneration
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return .ok([
                    "workspace_id": resolved.workspace.id.uuidString,
                    "surface_id": surfaceId.uuidString,
                    "submitted": false,
                    "submit_error": "cancelled",
                ])
            }
            // Closing/replacing a terminal during the suspension must never
            // send Enter into a different process or a newly created surface.
            guard let current = mobileCanonicalTerminalTarget(params: params)?.target,
                  current.surface === terminalTarget.surface,
                  current.surface.runtimeSurfaceGeneration == generation else {
                return .ok([
                    "workspace_id": resolved.workspace.id.uuidString,
                    "surface_id": surfaceId.uuidString,
                    "submitted": false,
                    "submit_error": "surface_changed",
                ])
            }
            let keyResult = current.sendNamedKeyResult(submitKeyName)
            if keyResult.accepted {
                submitted = true
            } else {
                switch keyResult {
                case .inputQueueFull:
                    submitError = "input_queue_full"
                case .surfaceUnavailable:
                    submitError = "surface_unavailable"
                case .processExited:
                    submitError = "process_exited"
                case .unknownKey, .sent, .queued:
                    // .sent / .queued are accepted results and unreachable in
                    // this else-branch; grouped only to keep the switch exhaustive.
                    submitError = "unknown_key"
                }
            }
        }

        terminalTarget.forceRefresh(reason: "terminal.paste")

        if submitted,
           let rawEventID = v2String(params, "feed_event_id"),
           let eventID = UUID(uuidString: rawEventID) {
            _ = FeedCoordinator.shared.store?.recordTerminalReply(eventID, text: text)
        }

        var payload: [String: Any] = [
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": terminalPanel.id.uuidString,
            "delivery": textResult == .sent ? "delivered" : "queued",
            "submitted": submitted,
        ]
        if let submitError {
            payload["submit_error"] = submitError
        }
        return .ok(payload)
    }
}

@MainActor
extension DockSplitStore {
    /// Resolves a structurally owned Dock terminal against the live registry.
    func controlSocketTerminalTarget(for surfaceID: UUID) -> ControlTerminalSocketTarget? {
        guard let panel = panels[surfaceID] as? TerminalPanel else { return nil }
        return ControlTerminalSocketTarget.resolve(
            surfaceID: surfaceID,
            panel: panel,
            workspaceID: workspaceId
        )
    }
}

@MainActor
private extension ControlTerminalSocketTarget {
    /// Reconciles app-owned topology with package-owned live runtime identity.
    static func resolve(
        surfaceID: UUID,
        panel: TerminalPanel,
        workspaceID: UUID
    ) -> ControlTerminalSocketTarget? {
        guard let canonical = GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID),
              canonical.tabId == workspaceID else {
            return nil
        }
        let state: ControlTerminalSocketBindingState = canonical === panel.surface
            ? .bound
            : .registryRebound
        if state == .registryRebound {
            logger.debug(
                "Rebound socket surface=\(surfaceID, privacy: .public) workspace=\(workspaceID, privacy: .public)"
            )
        }
        return ControlTerminalSocketTarget(
            surfaceID: surfaceID,
            panel: panel,
            surface: canonical,
            bindingState: state
        )
    }
}

extension TerminalController {
    /// Creates the health row shared by workspace and Dock surface listings.
    func controlSurfaceHealthEntry(
        for panel: any Panel,
        terminalTarget: ControlTerminalSocketTarget?
    ) -> ControlSurfaceHealthEntry {
        if let terminalPanel = panel as? TerminalPanel {
            return ControlSurfaceHealthEntry(
                surfaceID: panel.id,
                typeRawValue: panel.panelType.rawValue,
                inWindow: terminalTarget?.surface.isViewInWindow
                    ?? terminalPanel.surface.isViewInWindow,
                socketBindingRawValue: terminalTarget?.bindingState.rawValue
                    ?? ControlTerminalSocketBindingState.unavailable.rawValue,
                renderHealthRawValue: terminalTarget?.surface.renderHealth.rawValue
                    ?? terminalPanel.surface.renderHealth.rawValue
            )
        }
        let inWindow = (panel as? BrowserPanel).map { $0.webView.window != nil }
        return ControlSurfaceHealthEntry(
            surfaceID: panel.id,
            typeRawValue: panel.panelType.rawValue,
            inWindow: inWindow
        )
    }

    /// Captures terminal text from a validated canonical runtime model.
    func readTerminalTextRawSnapshot(
        terminalSurface: TerminalSurface,
        includeScrollback: Bool
    ) -> TerminalTextRawSnapshot? {
        guard terminalSurface.liveSurfaceForGhosttyAccess(
            reason: "socket.readTerminalText"
        ) != nil else { return nil }
        if includeScrollback {
            return TerminalTextRawSnapshot(
                viewport: nil,
                screen: terminalSurface.readText(region: .screen),
                history: terminalSurface.readText(region: .history),
                active: terminalSurface.readText(region: .active)
            )
        }
        return TerminalTextRawSnapshot(
            viewport: terminalSurface.readText(region: .viewport),
            screen: nil,
            history: nil,
            active: nil
        )
    }

    /// Encodes a panel-owned terminal snapshot for the legacy socket protocol.
    func readTerminalTextBase64(
        terminalPanel: TerminalPanel,
        includeScrollback: Bool = false,
        lineLimit: Int? = nil
    ) -> String {
        readTerminalTextBase64(
            terminalSurface: terminalPanel.surface,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        )
    }

    /// Encodes a canonical terminal snapshot for the legacy socket protocol.
    func readTerminalTextBase64(
        terminalSurface: TerminalSurface,
        includeScrollback: Bool = false,
        lineLimit: Int? = nil
    ) -> String {
        guard terminalSurface.liveSurfaceForGhosttyAccess(
            reason: "readTerminalTextBase64"
        ) != nil else {
            return "ERROR: Terminal surface not found"
        }
        guard let snapshot = readTerminalTextRawSnapshot(
            terminalSurface: terminalSurface,
            includeScrollback: includeScrollback
        ) else {
            return "ERROR: Terminal surface not found"
        }
        switch Self.terminalTextPayload(
            from: snapshot,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        ) {
        case .success(let payload):
            return "OK \(payload.base64)"
        case .failure(let error):
            return "ERROR: \(error.message)"
        }
    }
}
