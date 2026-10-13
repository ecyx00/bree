import AppKit
import Bonsplit
import BreeCloud
import BreeTerminal
import BreeTerminalSharing
import BreeTerminalSizing
import Foundation
import SwiftUI
import SystemConfiguration

/// Shared terminal sizing for local terminals (the Mac is the host).
/// Contract: docs/shared-terminal-sizing.md.
@MainActor
extension TerminalController {
    /// The Mac's user-visible computer name, read once without DNS.
    static let localComputerName: String? = SCDynamicStoreCopyComputerName(nil, nil) as String?

    /// This Mac's identity as a participant.
    func localSizingIdentity() -> TerminalSharingIdentity {
        TerminalSharingIdentity(
            userID: nil,
            displayName: nil,
            deviceName: Self.localComputerName,
            deviceID: Self.localSizingDeviceID
        )
    }

    /// This Mac's sizing `device_id`, derived once from its host identity.
    static let localSizingDeviceID = TerminalSharingIdentity.sizingDeviceID(installID: MobileHostIdentity.deviceID())

    /// Returns the local host of a surface, creating it (with the Mac pane as
    /// participant) when `create` is set and the surface is a local PTY.
    func localSizingHost(surfaceID: UUID, create: Bool) -> LocalTerminalSizingHost? {
        if let host = localSizingHostsBySurfaceID[surfaceID] { return host }
        guard create,
              let target = terminalSocketTarget(surfaceID: surfaceID),
              target.surface.ioMode == .exec else { return nil }
        let surface = target.surface
        let controller = LocalTerminalSharingController(surfaceID: surfaceID, surface: surface, owner: self)
        let viewport = controller.naturalViewport() ?? TerminalGridSize(cols: 80, rows: 24)
        let host = LocalTerminalSizingHost(
            macParticipant: localSizingIdentity().participant(
                id: "mac:\(surfaceID.uuidString.lowercased())",
                deviceKind: .mac,
                viewport: viewport
            ),
            initialSize: viewport
        )
        localSizingHostsBySurfaceID[surfaceID] = host
        localSizingControllersBySurfaceID[surfaceID] = controller
        ensureTerminalSharingPresentation()
        terminalSharing.register(controller, surfaceID: surfaceID)
        surface.onNaturalGridInputsChanged = { [weak self] in
            // Hop out of the in-progress updateSize before re-applying.
            Task { @MainActor [weak self] in
                self?.localSizingMacViewportChanged(surfaceID: surfaceID)
            }
        }
        publishLocalSizing(surfaceID: surfaceID)
        return host
    }

    /// Applies the host's decision and publishes it when it changed. A grid
    /// target caps the pane; returning to uncapped clears a cap this host set.
    func applyLocalSizing(
        surfaceID: UUID,
        previous: TerminalSizingState?,
        immediate: Bool = false,
        reason: String
    ) {
        guard let host = localSizingHostsBySurfaceID[surfaceID] else { return }
        if host.state != previous { publishLocalSizing(surfaceID: surfaceID) }
        let surface = terminalSocketTarget(surfaceID: surfaceID)?.surface
        switch host.applyTarget {
        case let .grid(size):
            localSizingCappedSurfaceIDs.insert(surfaceID)
            _ = surface?.applyMobileViewportLimit(columns: size.cols, rows: size.rows, reason: reason)
        case .uncapped:
            if localSizingCappedSurfaceIDs.remove(surfaceID) != nil {
                _ = surface?.clearMobileViewportLimit(reason: reason)
            }
        }
    }

    /// The Mac pane resized: re-report its grid as the Mac participant's viewport.
    func localSizingMacViewportChanged(surfaceID: UUID) {
        guard var host = localSizingHostsBySurfaceID[surfaceID],
              let viewport = localSizingControllersBySurfaceID[surfaceID]?.naturalViewport() else { return }
        let previous = host.state
        // Store even when nothing published: a detached Mac view remembers
        // its pane grid for the reattach.
        let changed = host.updateMacViewport(viewport)
        localSizingHostsBySurfaceID[surfaceID] = host
        guard changed else { return }
        applyLocalSizing(surfaceID: surfaceID, previous: previous, reason: "mac.viewport")
    }

    /// Explicit keyboard, paste or mouse input on the Mac pane. O(1) when the
    /// terminal is not shared, because it runs on every keystroke.
    func noteLocalTerminalSizingActivity(surfaceID: UUID) {
        guard var host = localSizingHostsBySurfaceID[surfaceID] else { return }
        let previous = host.state
        guard host.noteActivity(host.macParticipantID) else { return }
        localSizingHostsBySurfaceID[surfaceID] = host
        applyLocalSizing(surfaceID: surfaceID, previous: previous, reason: "mac.activity")
    }

    /// Drops every local host (account change or test reset).
    func resetLocalSizingHosts() {
        for surfaceID in Set(localSizingHostsBySurfaceID.keys).union(localSizingControllersBySurfaceID.keys) {
            removeLocalSizingHost(surfaceID: surfaceID)
        }
    }

    /// Drops one surface's local host, its sharing controller and its store
    /// snapshot. Called when the terminal closes (``cleanupSurfaceState``);
    /// a surface moved to another workspace keeps its host.
    func removeLocalSizingHost(surfaceID: UUID) {
        if let controller = localSizingControllersBySurfaceID.removeValue(forKey: surfaceID) {
            controller.surface?.onNaturalGridInputsChanged = nil
            terminalSharing.unregister(controller, surfaceID: surfaceID)
        }
        localSizingHostsBySurfaceID[surfaceID] = nil
        localSizingCappedSurfaceIDs.remove(surfaceID)
    }

    // MARK: - Presentation

    /// Routes store changes to the pane overlay and the tab accessory. Set
    /// once, the first time any host or relay registers.
    func ensureTerminalSharingPresentation() {
        guard terminalSharing.onChange == nil else { return }
        terminalSharing.onChange = { [weak self] surfaceID in
            self?.terminalSharingDidChange(surfaceID: surfaceID)
        }
    }

    private func terminalSharingDidChange(surfaceID: UUID) {
        let snapshot = terminalSharing.snapshot(for: surfaceID)
        if snapshot == nil { terminalSizePanelPresenter.close(surfaceID: surfaceID) }
        if let surface = GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID) {
            // A detached view stops sending keyboard input until it reattaches.
            surface.sharingViewDetached = snapshot?.detachment != nil
            surface.hostedView.setTerminalSharingSnapshot(
                snapshot,
                surface: surface,
                onShowSizePanel: { [weak self] in
                    _ = self?.presentTerminalSizePanel(surfaceID: surfaceID, confirmDisconnectOthers: false)
                },
                onReattach: { [weak self] asViewer in
                    _ = self?.terminalSharing.reattach(surfaceID: surfaceID, asViewer: asViewer)
                }
            )
        }
        if let workspace = AppDelegate.shared?.workspaceContainingPanel(panelId: surfaceID)?.workspace {
            workspace.updateTerminalSharingPresence(panelId: surfaceID, snapshot: snapshot)
        }
    }

    /// Opens the size panel for a terminal, anchored at its tab in the tab
    /// strip (tab accessory, pane chip, context menu, command palette and
    /// shortcut all land here).
    ///
    /// - Parameters:
    ///   - surfaceID: The terminal.
    ///   - confirmDisconnectOthers: Open with the Disconnect Others confirmation showing.
    ///   - toggle: Close instead when the panel is already open for this terminal
    ///     (the tab accessory's click).
    /// - Returns: `false` when the terminal has nothing on screen to anchor to.
    @discardableResult
    func presentTerminalSizePanel(surfaceID: UUID, confirmDisconnectOthers: Bool, toggle: Bool = false) -> Bool {
        if toggle, terminalSizePanelPresenter.consumeToggleClose(surfaceID: surfaceID) { return true }
        if terminalSharing.snapshot(for: surfaceID) == nil {
            _ = localSizingHost(surfaceID: surfaceID, create: true)
        }
        guard let anchor = terminalSizePanelAnchor(surfaceID: surfaceID) else { return false }
        let panel = TerminalSizePanelView(
            store: terminalSharing,
            surfaceID: surfaceID,
            confirmDisconnectOthers: confirmDisconnectOthers
        )
        terminalSizePanelPresenter.present(panel, surfaceID: surfaceID, anchor: anchor.view, rect: anchor.rect)
        return true
    }

    /// The terminal's tab accessory, else its tab item, in the tab strip.
    /// Falls back to the pane's top-right corner only when the tab strip does
    /// not show the tab (for example a hidden tab bar).
    private func terminalSizePanelAnchor(surfaceID: UUID) -> (view: NSView, rect: NSRect?)? {
        if let workspace = AppDelegate.shared?.workspaceContainingPanel(panelId: surfaceID)?.workspace,
           let tabID = workspace.surfaceIdFromPanelId(surfaceID),
           let view = workspace.bonsplitController.popoverAnchorView(for: tabID) {
            return (view, nil)
        }
        guard let surface = GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID),
              surface.hostedView.window != nil else { return nil }
        let pane = surface.hostedView
        let corner = NSRect(x: pane.bounds.maxX - 24, y: pane.isFlipped ? 0 : pane.bounds.maxY - 4, width: 20, height: 4)
        return (pane, corner)
    }

    // MARK: - Publishing

    /// Publishes a local host's state to the store.
    func publishLocalSizing(surfaceID: UUID) {
        guard let host = localSizingHostsBySurfaceID[surfaceID] else {
            terminalSharing.publish(nil, surfaceID: surfaceID)
            return
        }
        terminalSharing.publish(
            TerminalSharingSnapshot(
                state: host.state,
                selfParticipantID: host.macParticipantID,
                detachment: host.macDetachment,
                isCloud: false
            ),
            surfaceID: surfaceID
        )
    }

    // MARK: - Local controller actions

    func localSizingSetPolicy(surfaceID: UUID, policy: TerminalSizingPolicy) -> Bool {
        guard var host = localSizingHostsBySurfaceID[surfaceID] else { return false }
        let previous = host.state
        host.setPolicy(policy)
        localSizingHostsBySurfaceID[surfaceID] = host
        applyLocalSizing(surfaceID: surfaceID, previous: previous, reason: "terminal.size_policy.set")
        return true
    }

    func localSizingSetCountsOverride(surfaceID: UUID, participantID: String, value: Bool?) -> Bool {
        guard var host = localSizingHostsBySurfaceID[surfaceID],
              host.state.participant(participantID) != nil else { return false }
        let previous = host.state
        host.setCountsOverride(participantID, value)
        localSizingHostsBySurfaceID[surfaceID] = host
        applyLocalSizing(surfaceID: surfaceID, previous: previous, reason: "terminal.size_counts.set")
        return true
    }

    /// Disconnects this Mac pane's own view (when another participant asks).
    /// The pane's view detach keeps the PTY and every other viewer; the pane
    /// shows the Detached card until Reattach.
    func localSizingDisconnect(surfaceID: UUID, participantID: String, by actor: TerminalDetachActor?) -> Bool {
        guard var host = localSizingHostsBySurfaceID[surfaceID],
              participantID == host.macParticipantID else { return false }
        let detachment = TerminalSharingDetachment(
            reason: .disconnectedBy(actor ?? localSizingIdentity().detachActor),
            at: Date()
        )
        let previous = host.state
        guard host.disconnect(participantID, detachment: detachment) else { return false }
        localSizingHostsBySurfaceID[surfaceID] = host
        applyLocalSizing(surfaceID: surfaceID, previous: previous, immediate: true, reason: "terminal.participant.disconnect.mac")
        return true
    }

    func localSizingNoteSelfActivity(surfaceID: UUID) {
        noteLocalTerminalSizingActivity(surfaceID: surfaceID)
    }

    /// Reattaches this Mac pane's view after someone disconnected it.
    func localSizingReattachMac(surfaceID: UUID, asViewer: Bool) -> Bool {
        guard var host = localSizingHostsBySurfaceID[surfaceID] else { return false }
        if let viewport = localSizingControllersBySurfaceID[surfaceID]?.naturalViewport() {
            host.updateMacViewport(viewport)
        }
        let previous = host.state
        guard host.reattach(host.macParticipantID, asViewer: asViewer) else { return false }
        localSizingHostsBySurfaceID[surfaceID] = host
        applyLocalSizing(surfaceID: surfaceID, previous: previous, immediate: true, reason: "terminal.participant.reattach.mac")
        return true
    }

    // MARK: - Socket / CLI

    func sizeStatePayload(surfaceID: UUID) -> [String: Any] {
        TerminalSizingWireCoder().sizeStatePayload(
            surfaceID: surfaceID.uuidString,
            snapshot: terminalSharing.snapshot(for: surfaceID)
        )
    }

    /// Resolves the terminal a socket request names, making sure a local
    /// terminal has a host so policy commands work before any phone attaches.
    private func sharingSocketSurfaceID(params: [String: Any]) -> UUID? {
        guard let surfaceID = mobileCanonicalTerminalTarget(params: params)?.surfaceID else { return nil }
        if terminalSharing.snapshot(for: surfaceID) == nil {
            _ = localSizingHost(surfaceID: surfaceID, create: true)
        }
        return surfaceID
    }

    private static var sharingSurfaceNotFound: V2CallResult {
        .err(code: "not_found", message: "Terminal surface not found", data: nil)
    }

    private static var fixedSizeTooLarge: V2CallResult {
        let limit = TerminalSizingPolicy.maximumFixedSize
        return .err(
            code: "invalid_params",
            message: "Fixed size must be at most \(limit.cols) x \(limit.rows)",
            data: nil
        )
    }

    /// `terminal.size_state {surface_id?}`.
    func v2TerminalSizeState(params: [String: Any]) -> V2CallResult {
        guard let surfaceID = sharingSocketSurfaceID(params: params) else { return Self.sharingSurfaceNotFound }
        return .ok(sizeStatePayload(surfaceID: surfaceID))
    }

    /// `terminal.size_policy.set {surface_id?, mode?, policy?, fixed_cols?, fixed_rows?, priority?}`.
    func v2TerminalSizePolicySet(params: [String: Any]) -> V2CallResult {
        guard let surfaceID = sharingSocketSurfaceID(params: params),
              let snapshot = terminalSharing.snapshot(for: surfaceID) else { return Self.sharingSurfaceNotFound }
        var policy = snapshot.state.policy
        if params["policy"] != nil {
            guard let requested = TerminalSizingWireCoder().policy(from: params["policy"]) else {
                return .err(code: "invalid_params", message: "Invalid policy", data: nil)
            }
            guard requested.fixedSizeIsWithinLimit else { return Self.fixedSizeTooLarge }
            policy = requested
        }
        if let rawMode = v2String(params, "mode") {
            guard let mode = TerminalSizingMode(rawValue: rawMode) else {
                return .err(code: "invalid_params", message: "Unknown mode \(rawMode)", data: nil)
            }
            policy = policy.withMode(mode, fallbackFixed: snapshot.state.size)
        }
        if let cols = v2Int(params, "fixed_cols"), let rows = v2Int(params, "fixed_rows") {
            let requested = TerminalSizingPolicy(mode: policy.mode, priority: policy.priority, fixed: TerminalGridSize(cols: cols, rows: rows))
            guard requested.fixedSizeIsWithinLimit else { return Self.fixedSizeTooLarge }
            policy = requested
        }
        if let priority = params["priority"] as? [String] {
            policy = TerminalSizingPolicy(mode: policy.mode, priority: priority, fixed: policy.fixed)
        }
        guard terminalSharing.setPolicy(policy, surfaceID: surfaceID) else {
            return .err(code: "unavailable", message: "Terminal size policy is unavailable", data: nil)
        }
        return .ok(sizeStatePayload(surfaceID: surfaceID))
    }

    /// `terminal.size_to_me {surface_id?}` (Size to My Window).
    func v2TerminalSizeToMe(params: [String: Any]) -> V2CallResult {
        guard let surfaceID = sharingSocketSurfaceID(params: params) else { return Self.sharingSurfaceNotFound }
        guard terminalSharing.sizeToMe(surfaceID: surfaceID) else {
            return .err(code: "unavailable", message: "This window is not attached to the terminal", data: nil)
        }
        return .ok(sizeStatePayload(surfaceID: surfaceID))
    }

    /// `terminal.size_counts.set {surface_id?, participant_id?, counts: bool|null}`.
    func v2TerminalSizeCountsSet(params: [String: Any]) -> V2CallResult {
        guard let surfaceID = sharingSocketSurfaceID(params: params),
              let snapshot = terminalSharing.snapshot(for: surfaceID) else { return Self.sharingSurfaceNotFound }
        guard let participantID = v2String(params, "participant_id") ?? snapshot.selfParticipantID else {
            return .err(code: "invalid_params", message: "Missing participant_id", data: nil)
        }
        let value: Bool? = params["counts"] is NSNull ? nil : v2Bool(params, "counts")
        guard terminalSharing.setCountsOverride(value, participantID: participantID, surfaceID: surfaceID) else {
            return .err(code: "not_found", message: "Participant not found", data: nil)
        }
        return .ok(sizeStatePayload(surfaceID: surfaceID))
    }

    /// `terminal.participant.disconnect {surface_id?, participant_id}`.
    func v2TerminalParticipantDisconnect(params: [String: Any]) -> V2CallResult {
        guard let surfaceID = sharingSocketSurfaceID(params: params) else { return Self.sharingSurfaceNotFound }
        guard let participantID = v2String(params, "participant_id") else {
            return .err(code: "invalid_params", message: "Missing participant_id", data: nil)
        }
        guard terminalSharing.disconnect(participantID: participantID, surfaceID: surfaceID) else {
            return .err(code: "not_found", message: "Participant not found", data: nil)
        }
        return .ok(sizeStatePayload(surfaceID: surfaceID))
    }

    /// `terminal.participants.disconnect_others {surface_id?}`.
    func v2TerminalParticipantsDisconnectOthers(params: [String: Any]) -> V2CallResult {
        guard let surfaceID = sharingSocketSurfaceID(params: params) else { return Self.sharingSurfaceNotFound }
        let count = terminalSharing.disconnectOthers(surfaceID: surfaceID)
        var payload = sizeStatePayload(surfaceID: surfaceID)
        payload["disconnected"] = count
        return .ok(payload)
    }
}
