extension RemoteInteractiveShellBootstrapBuilder {
    static func remoteInitialWorkingDirectoryLines() -> [String] {
        [
            "bree_remote_initial_cwd_b64='__BREE_REMOTE_INITIAL_CWD_B64__'",
            "if [ \"$bree_remote_initial_cwd_b64\" = '__BREE_''REMOTE_INITIAL_CWD_B64__' ]; then bree_remote_initial_cwd_b64=''; fi",
            "if [ -n \"$bree_remote_initial_cwd_b64\" ]; then",
            "  bree_remote_initial_cwd=\"$(printf %s \"$bree_remote_initial_cwd_b64\" | base64 -d 2>/dev/null || printf %s \"$bree_remote_initial_cwd_b64\" | base64 -D 2>/dev/null || true)\"",
            "  if [ -n \"$bree_remote_initial_cwd\" ]; then cd \"$bree_remote_initial_cwd\" 2>/dev/null || true; fi",
            "fi",
            "unset bree_remote_initial_cwd_b64 bree_remote_initial_cwd",
        ]
    }
}
