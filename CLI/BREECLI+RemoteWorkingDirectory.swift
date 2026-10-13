import Foundation

extension BREECLI {
    static func applyingSSHPTYAttachBootstrapSubstitutions(
        to command: String,
        workspaceID: String
    ) -> String {
        let remoteInitialCWDB64 = ProcessInfo.processInfo.environment["BREE_REMOTE_INITIAL_CWD"]
            .flatMap { $0.isEmpty ? nil : Data($0.utf8).base64EncodedString() } ?? ""
        return command
            .replacingOccurrences(of: "__BREE_WORKSPACE_ID__", with: workspaceID)
            .replacingOccurrences(of: "__BREE_SURFACE_ID__", with: ProcessInfo.processInfo.environment["BREE_SURFACE_ID"] ?? "")
            .replacingOccurrences(of: "__BREE_TERMINAL_LIFECYCLE_ID__", with: ProcessInfo.processInfo.environment["BREE_TERMINAL_LIFECYCLE_ID"] ?? "")
            .replacingOccurrences(of: "__BREE_SSH_ATTEMPT_ID__", with: ProcessInfo.processInfo.environment["BREE_SSH_ATTEMPT_ID"] ?? "")
            .replacingOccurrences(of: "__BREE_REMOTE_INITIAL_CWD_B64__", with: remoteInitialCWDB64)
    }
}
