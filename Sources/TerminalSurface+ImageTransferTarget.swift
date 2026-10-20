import BreeTerminal
import Foundation

extension TerminalSurface {
    @MainActor
    func resolvedImageTransferTarget(
        mode: TerminalImageTransferMode = .paste,
        in workspace: Workspace? = nil
    ) -> TerminalImageTransferTarget {
        // The bound session remains authoritative even during reconnect, before
        // its local workspace or a fresh remote numeric surface can be resolved.
        let workspace = workspace ?? owningWorkspace()
        guard let workspace else { return .local }
        if workspace.isRemoteTerminalSurface(id) {
            return .remote(.workspaceRemote)
        }
        // Manual tmux mirrors have no local TTY for the SSH process detector.
        if let target = AppDelegate.shared?.remoteTmuxController.remoteUploadTarget(forSurfaceId: id) {
            return .remote(target)
        }
        return .local
    }

    @MainActor
    func resolvedImageTransferTargetAsync(
        mode: TerminalImageTransferMode = .paste,
        in workspace: Workspace? = nil,
        detector: @escaping @Sendable (String) -> DetectedSSHSession? = { tty in
            TerminalSSHSessionDetector.detect(forTTY: tty)
        },
        timeoutSleep: @escaping @Sendable (TimeInterval) async -> Void = {
            timeout in
            await TerminalSSHSessionDetector
                .defaultDetectionTimeoutSleep(timeout)
        }
    ) async -> TerminalImageTransferTarget {
        let workspace = workspace ?? owningWorkspace()
        let knownTarget = resolvedImageTransferTarget(mode: mode, in: workspace)
        guard let ttyName = imageTransferDetectionTTY(mode: mode, in: workspace),
              let session = await TerminalSSHSessionDetector.detectAsync(
                  forTTY: ttyName,
                  detector: detector,
                  timeoutSleep: timeoutSleep
              ) else {
            return knownTarget
        }
        return .remote(.detectedSSH(session))
    }

    /// The TTY to check for a user-started SSH session, or nil when the
    /// transfer is local without any process lookup.
    ///
    /// Every drop and paste calls this on the main actor, and a nil result
    /// inserts the path in the same turn, as upstream Ghostty does. Keep the
    /// work here bounded by the foreground job: the PTY names its foreground
    /// group (`tcgetpgrp`), and only a group with an `ssh` or `et` member
    /// needs the bounded async lookup. Never add per-process work over the
    /// whole TTY or machine here, or make every drop wait on a background
    /// hop; on a loaded Mac either one delayed every dropped path by seconds.
    @MainActor
    func imageTransferDetectionTTY(
        mode: TerminalImageTransferMode = .paste,
        in workspace: Workspace? = nil
    ) -> String? {
        let workspace = workspace ?? owningWorkspace()
        guard resolvedImageTransferTarget(mode: mode, in: workspace) == .local,
              let ttyName = workspace?.surfaceTTYNames[id],
              !ttyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        // The fast check reads this surface's own PTY. It applies only when the
        // reported TTY is that PTY: inside tmux the report can name a tmux
        // pane's TTY, whose foreground job the bree PTY cannot see. Without a
        // live PTY, on a mismatch, or when the group cannot be read at all
        // (`nil` rather than `false`), keep the async lookup so an unknown job
        // is never assumed local.
        if let surfaceDevice = controllingTTYDeviceIdentifier,
           surfaceDevice == BreeTopProcessSnapshot.deviceIdentifier(forTTYName: ttyName),
           let processGroupID = foregroundProcessID(),
           TerminalSSHSessionDetector.foregroundJobHasRemoteShell(
               processGroupID: Int32(processGroupID),
               ttyName: ttyName
           ) == false {
            return nil
        }
        return ttyName
    }
}
