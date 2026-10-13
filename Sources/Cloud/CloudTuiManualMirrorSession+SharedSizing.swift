import BreeCloudTui
import BreeTerminal
import BreeTerminalSharing
import BreeTerminalSizing
import Foundation

/// The Mac as a participant of a Cloud terminal (docs/shared-terminal-sizing.md):
/// it forwards itself to the bree-tui host and receives the host's size state
/// and detach events. Daemons without `shared-sizing-v1` keep the legacy claim
/// path.
@MainActor
extension CloudTuiManualMirrorSession: TerminalSharingSurfaceControlling {
    private var sharingStore: TerminalSharingStore { TerminalController.shared.terminalSharing }

    // MARK: Lifecycle

    func bindSharing(surfaceID: UUID) {
        guard sharingSurfaceID != surfaceID else { return }
        unbindSharing()
        sharingSurfaceID = surfaceID
        if sizingRelay.isSupported, attachResponseReceived {
            registerSharing()
        }
    }

    func unbindSharing() {
        guard let surfaceID = sharingSurfaceID else { return }
        sharingStore.unregister(self, surfaceID: surfaceID)
        sharingSurfaceID = nil
    }

    private func registerSharing() {
        guard let surfaceID = sharingSurfaceID else { return }
        sharingStore.register(self, surfaceID: surfaceID)
    }

    /// This Mac's identity as a host participant (no viewport; the attach
    /// lease reports it).
    func sharingSelfIdentity() -> TerminalSizingParticipant {
        TerminalController.shared.localSizingIdentity().participant(id: "", deviceKind: .mac)
    }

    /// The attach answer arrived: record this Mac's host id, register and
    /// fetch the current state.
    func sharingAttached(selfParticipantID: String?) {
        guard sizingRelay.isSupported else { return }
        sizingRelay.attached(selfParticipantID: selfParticipantID)
        registerSharing()
        if sharingReattachAsViewerPending, let remoteLease {
            sharingReattachAsViewerPending = false
            sendSizing(commandBuilder.setSizeCounts(
                surfaceID: remoteSurfaceID, target: ("lease", remoteLease), counts: false, requestID: takeRequestID()
            ))
        }
        sendSizing(commandBuilder.getSizeState(surfaceID: remoteSurfaceID, requestID: takeRequestID()))
    }

    // MARK: Host events

    func receiveSizeState(_ state: TerminalSizingState) {
        guard sizingRelay.receive(state) else { return }
        publishSharingSnapshot()
    }

    func publishSharingSnapshot() {
        guard let surfaceID = sharingSurfaceID else { return }
        guard let state = sizingRelay.state else {
            sharingStore.publish(nil, surfaceID: surfaceID)
            return
        }
        sharingStore.publish(
            TerminalSharingSnapshot(
                state: state,
                selfParticipantID: sizingRelay.selfParticipantID,
                detachment: sharingDetachment,
                isCloud: true
            ),
            surfaceID: surfaceID
        )
    }

    /// Routes a `detached` event. A view-only detach of this Mac shows the
    /// detached card and keeps the connection. This Mac's whole-connection
    /// `disconnected-by` (or host-shutdown / superseded) stops automatic
    /// reconnection and shows the detached card; a network detach reconnects
    /// as before.
    func handleSharingDetached(reason: TerminalDetachReason, view: String?, viewOnly: Bool = false) {
        switch sizingRelay.routeDetached(reason: reason, view: view, viewOnly: viewOnly) {
        case nil:
            return
        case let .ownView(reason):
            sharingOwnViewDetached = true
            sharingDetachment = TerminalSharingDetachment(reason: reason, at: Date())
            publishSharingSnapshot()
        case .phone:
            return
        case let .mirror(reason, _):
            guard !reason.reconnectsAutomatically else {
                disconnectForSharing(reconnect: true)
                return
            }
            let detachment = TerminalSharingDetachment(reason: reason, at: Date())
            sharingDetachment = detachment
            disconnectForSharing(reconnect: false)
            publishSharingSnapshot()
        }
    }

    private var relaysSizing: Bool { sizingRelay.isSupported && attachResponseReceived }

    @discardableResult
    private func sendSizing(_ command: [String: Any]) -> Bool {
        guard relaysSizing, let connection, let requestID = command["id"] as? UInt64 else { return false }
        pendingRequests[requestID] = .sizing
        connection.send(command)
        return true
    }

    /// Explicit focus or input on this Mac pane (`note-size-activity`).
    /// `set-client-sizing` is not used here: under shared sizing its
    /// `enabled: false` means counts false.
    func sendSharingFocusActivity() {
        _ = sendSizing(commandBuilder.noteSizeActivity(surfaceID: remoteSurfaceID, requestID: takeRequestID()))
    }

    // MARK: Store actions (TerminalSharingSurfaceControlling)

    func sharingSetPolicy(_ policy: TerminalSizingPolicy) -> Bool {
        sendSizing(commandBuilder.setSizePolicy(surfaceID: remoteSurfaceID, policy: policy, requestID: takeRequestID()))
    }

    func sharingSetCountsOverride(participantID: String, value: Bool?) -> Bool {
        let target: (key: String, value: String)
        if participantID == sizingRelay.selfParticipantID, let remoteLease {
            target = ("lease", remoteLease)
        } else if let view = sizingRelay.view(forHostParticipant: participantID) {
            target = ("view", view)
        } else {
            target = ("participant", participantID)
        }
        return sendSizing(commandBuilder.setSizeCounts(
            surfaceID: remoteSurfaceID, target: target, counts: value, requestID: takeRequestID()
        ))
    }

    /// Disconnects a participant through the daemon. Asked for this Mac's
    /// own view (by a phone behind it), a `sizing-view-detach-v1` daemon
    /// detaches the view only; an older daemon would drop the relay and its
    /// phones, so that request is refused.
    func sharingDisconnect(participantID: String, by actor: TerminalDetachActor?) -> Bool {
        if participantID == sizingRelay.selfParticipantID, !sizingRelay.supportsViewDetach { return false }
        let actor = actor ?? TerminalController.shared.localSizingIdentity().detachActor
        return sendSizing(commandBuilder.detachClient(
            participantID: participantID, surfaceID: remoteSurfaceID, by: actor, requestID: takeRequestID()
        ))
    }

    func sharingNoteSelfActivity() {
        sendSharingFocusActivity()
    }

    func sharingReattach(asViewer: Bool) -> Bool {
        guard sharingDetachment != nil else { return false }
        if sharingOwnViewDetached {
            // The connection is alive: restore the view in place.
            guard sendSizing(commandBuilder.reattachView(
                surfaceID: remoteSurfaceID, asViewer: asViewer, requestID: takeRequestID()
            )) else { return false }
            sharingOwnViewDetached = false
            sharingDetachment = nil
            publishSharingSnapshot()
            return true
        }
        sharingReattachAsViewerPending = asViewer
        return retryConnection()
    }
}
