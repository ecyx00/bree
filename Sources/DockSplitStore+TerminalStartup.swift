import Foundation

extension DockSplitStore {
    static func resolvedWorkingDirectory(_ cwd: String?, baseDirectory: String) -> String {
        guard let cwd, !cwd.isEmpty else { return baseDirectory }
        if cwd.hasPrefix("/") {
            return cwd
        }
        return (baseDirectory as NSString).appendingPathComponent(cwd)
    }

    static func shellStartupScript(command: String, workingDirectory: String) -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent(
            "bree-dock-control-\(UUID().uuidString.lowercased()).sh"
        )
        let encodedCommand = Data(command.utf8).base64EncodedString()
        let encodedWorkingDirectory = Data(workingDirectory.utf8).base64EncodedString()
        let body = """
        #!/bin/sh
        bree_dock_decode() { printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null; }
        bree_dock_login_shell() {
          bree_dock_user="$(id -un 2>/dev/null || printf '%s' "${USER:-}")"
          bree_dock_ds_shell="$(dscl . -read "/Users/$bree_dock_user" UserShell 2>/dev/null | awk '{print $2; exit}')"
          if [ -n "$bree_dock_ds_shell" ] && [ -x "$bree_dock_ds_shell" ]; then printf '%s\\n' "$bree_dock_ds_shell"
          elif [ -n "${SHELL:-}" ] && [ -x "${SHELL:-}" ]; then printf '%s\\n' "$SHELL"
          else printf '%s\\n' /bin/sh; fi
        }
        bree_dock_command="$(bree_dock_decode '\(encodedCommand)')"
        bree_dock_working_directory="$(bree_dock_decode '\(encodedWorkingDirectory)')"
        bree_dock_shell="$(bree_dock_login_shell)"
        bree_dock_bundle_bin=""
        if [ -n "${BREE_BUNDLED_CLI_PATH:-}" ]; then bree_dock_bundle_bin="$(dirname "$BREE_BUNDLED_CLI_PATH")"; fi
        export SHELL="$bree_dock_shell"
        rm -f -- "$0" 2>/dev/null || true
        case "$(basename "$bree_dock_shell")" in
          fish)
            BREE_DOCK_BUNDLE_BIN="$bree_dock_bundle_bin" BREE_DOCK_START_COMMAND="$bree_dock_command" BREE_DOCK_START_DIRECTORY="$bree_dock_working_directory" "$bree_dock_shell" -l -c 'if test -n "$BREE_DOCK_BUNDLE_BIN"; and not contains -- "$BREE_DOCK_BUNDLE_BIN" $PATH; set -gx PATH "$BREE_DOCK_BUNDLE_BIN" $PATH; end; if test -n "$BREE_DOCK_START_DIRECTORY"; cd "$BREE_DOCK_START_DIRECTORY"; end; eval "$BREE_DOCK_START_COMMAND"'
            ;;
          *) BREE_DOCK_BUNDLE_BIN="$bree_dock_bundle_bin" BREE_DOCK_START_COMMAND="$bree_dock_command" BREE_DOCK_START_DIRECTORY="$bree_dock_working_directory" "$bree_dock_shell" -lc 'if [ -n "${BREE_DOCK_BUNDLE_BIN:-}" ]; then case ":${PATH:-}:" in *":$BREE_DOCK_BUNDLE_BIN:"*) ;; *) PATH="$BREE_DOCK_BUNDLE_BIN${PATH:+:$PATH}"; export PATH ;; esac; fi; cd "$BREE_DOCK_START_DIRECTORY" 2>/dev/null || true; eval "$BREE_DOCK_START_COMMAND"'
            ;;
        esac
        printf '\\n'
        exec "$bree_dock_shell" -l
        """
        do {
            try body.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            return scriptURL.path
        } catch {
            return "/bin/sh"
        }
    }
}
