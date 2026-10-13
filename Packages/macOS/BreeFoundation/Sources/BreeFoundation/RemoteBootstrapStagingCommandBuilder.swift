internal import Foundation

/// Stages a remote terminal bootstrap over an SSH management exec channel.
///
/// The potentially large bootstrap is streamed on standard input. Interactive
/// transports such as SSH or Mosh then execute only the small staged path.
public struct RemoteBootstrapStagingCommandBuilder: Sendable {
    private let installerSSHArguments: [String]
    private let destination: String
    private let remoteRelayPort: Int
    private let bootstrapScript: String

    /// Creates a bootstrap staging builder.
    ///
    /// - Parameters:
    ///   - installerSSHArguments: SSH executable and options, excluding destination.
    ///   - destination: SSH destination or host alias.
    ///   - remoteRelayPort: Valid relay namespace used for the staged path.
    ///   - bootstrapScript: Remote shell bootstrap containing optional bree ID placeholders.
    public init?(
        installerSSHArguments: [String],
        destination: String,
        remoteRelayPort: Int,
        bootstrapScript: String
    ) {
        guard !installerSSHArguments.isEmpty,
              !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...65_535).contains(remoteRelayPort),
              !bootstrapScript.isEmpty else {
            return nil
        }
        self.installerSSHArguments = installerSSHArguments
        self.destination = destination
        self.remoteRelayPort = remoteRelayPort
        self.bootstrapScript = bootstrapScript
    }

    /// Local shell code that substitutes runtime IDs and streams the bootstrap over SSH.
    ///
    /// The SSH command is one `/bin/sh -c` remote-command string so an account's
    /// configured login shell cannot parse the POSIX installer itself.
    public var preparationShellScript: String {
        let encodedBootstrapScript = Data(bootstrapScript.utf8).base64EncodedString()
        let installCommand = "/bin/sh -c \(remoteInstallShellScript.remoteCommandShellQuoted)"
        let sshPrefix = installerSSHArguments
            .map(\.remoteCommandShellQuoted)
            .joined(separator: " ")
        return [
            "bree_workspace_id=\"${BREE_WORKSPACE_ID:-}\"",
            "bree_surface_id=\"${BREE_SURFACE_ID:-}\"",
            "bree_terminal_lifecycle_id=\"${BREE_TERMINAL_LIFECYCLE_ID:-}\"",
            "bree_ssh_attempt_id=\"${BREE_SSH_ATTEMPT_ID:-}\"",
            "bree_remote_bootstrap_b64=\(encodedBootstrapScript.remoteCommandShellQuoted)",
            "bree_remote_bootstrap=\"$(printf %s \"$bree_remote_bootstrap_b64\" | base64 -d 2>/dev/null || printf %s \"$bree_remote_bootstrap_b64\" | base64 -D 2>/dev/null)\"",
            "bree_sed_escape() { printf '%s' \"$1\" | sed 's/[\\/&\\\\]/\\\\&/g'; }",
            "bree_workspace_id_escaped=\"$(bree_sed_escape \"$bree_workspace_id\")\"",
            "bree_surface_id_escaped=\"$(bree_sed_escape \"$bree_surface_id\")\"",
            "bree_terminal_lifecycle_id_escaped=\"$(bree_sed_escape \"$bree_terminal_lifecycle_id\")\"",
            "bree_ssh_attempt_id_escaped=\"$(bree_sed_escape \"$bree_ssh_attempt_id\")\"",
            "bree_remote_bootstrap=\"$(printf '%s' \"$bree_remote_bootstrap\" | sed \"s/__BREE_WORKSPACE_ID__/$bree_workspace_id_escaped/g; s/__BREE_SURFACE_ID__/$bree_surface_id_escaped/g; s/__BREE_TERMINAL_LIFECYCLE_ID__/$bree_terminal_lifecycle_id_escaped/g; s/__BREE_SSH_ATTEMPT_ID__/$bree_ssh_attempt_id_escaped/g\")\"",
            "bree_remote_install_stderr_file=\"$(mktemp \"${TMPDIR:-/tmp}/bree-remote-bootstrap-install.XXXXXX\" 2>/dev/null || true)\"",
            "if [ -n \"$bree_remote_install_stderr_file\" ]; then",
            "  printf '%s' \"$bree_remote_bootstrap\" | command \(sshPrefix) -T \(destination.remoteCommandShellQuoted) \(installCommand.remoteCommandShellQuoted) 2>\"$bree_remote_install_stderr_file\"",
            "  bree_remote_install_status=$?",
            "else",
            "  printf '%s' \"$bree_remote_bootstrap\" | command \(sshPrefix) -T \(destination.remoteCommandShellQuoted) \(installCommand.remoteCommandShellQuoted)",
            "  bree_remote_install_status=$?",
            "fi",
            "if [ \"$bree_remote_install_status\" -ne 0 ] && [ -n \"$bree_remote_install_stderr_file\" ] && [ -s \"$bree_remote_install_stderr_file\" ]; then",
            "  cat \"$bree_remote_install_stderr_file\" >&2",
            "fi",
            "rm -f -- \"${bree_remote_install_stderr_file:-}\" 2>/dev/null || true",
            "unset bree_remote_bootstrap bree_remote_bootstrap_b64 bree_workspace_id bree_surface_id bree_terminal_lifecycle_id bree_ssh_attempt_id bree_workspace_id_escaped bree_surface_id_escaped bree_terminal_lifecycle_id_escaped bree_ssh_attempt_id_escaped bree_remote_install_stderr_file",
            "(exit \"$bree_remote_install_status\")",
        ].joined(separator: "\n")
    }

    /// Small remote shell command that replaces the process with the staged bootstrap.
    ///
    /// OpenSSH hands its remote command to the account's configured login
    /// shell first. Quote the POSIX launcher as the argument to an explicit
    /// `/bin/sh -c` so fish/csh/nushell never parse the staged bootstrap
    /// command themselves.
    public var remoteExecutionShellScript: String {
        "/bin/sh -c \(stagedBootstrapLauncherScript.remoteCommandShellQuoted)"
    }

    /// Remote command argv that executes the staged bootstrap.
    ///
    /// Mosh forwards this argv to `mosh-server`, which executes it with
    /// `execvp` and no shell parsing, so the launcher must be real argv
    /// elements: a single command string would be treated as a literal
    /// executable pathname and fail.
    public var remoteExecutionCommandArguments: [String] {
        ["/bin/sh", "-c", stagedBootstrapLauncherScript]
    }

    private var stagedBootstrapLauncherScript: String {
        "exec /bin/sh \"$HOME/\(BreeIdentity.remoteDotDirectoryName)/relay/\(remoteRelayPort).bootstrap.sh\""
    }

    private var remoteInstallShellScript: String {
        [
            "set -eu",
            "umask 077",
            "bree_bootstrap_path=\"$HOME/\(BreeIdentity.remoteDotDirectoryName)/relay/\(remoteRelayPort).bootstrap.sh\"",
            "mkdir -p \"$HOME/\(BreeIdentity.remoteDotDirectoryName)/relay\"",
            "cat > \"$bree_bootstrap_path\"",
            "chmod 700 \"$bree_bootstrap_path\" >/dev/null 2>&1 || true",
        ].joined(separator: "\n")
    }
}
