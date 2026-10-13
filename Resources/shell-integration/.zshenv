# vim:ft=zsh
#
# bree ZDOTDIR bootstrap for zsh.
#
# GhosttyKit already uses a ZDOTDIR injection mechanism for zsh (setting ZDOTDIR
# to Ghostty's integration dir). bree also needs to run its integration, but
# we must restore the user's real ZDOTDIR immediately so that:
# - /etc/zshrc sets HISTFILE relative to the real ZDOTDIR/HOME (shared history)
# - zsh loads the user's real .zprofile/.zshrc normally (no wrapper recursion)
#
# We restore ZDOTDIR from (in priority order):
# - GHOSTTY_ZSH_ZDOTDIR (set by GhosttyKit when it overwrote ZDOTDIR)
# - BREE_ZSH_ZDOTDIR (set by bree when it overwrote a user-provided ZDOTDIR)
# - unset (zsh treats unset ZDOTDIR as $HOME)

# Move the one-shot welcome-banner token path out of the environment before
# user startup files run, so children they exec (tmux, another shell) do not
# inherit it. bree-zsh-integration.zsh consumes the shell-local copy.
if [[ -n "${BREE_SHOW_WELCOME_FILE:-}" ]]; then
    builtin typeset -g _BREE_BOOTSTRAP_WELCOME_FILE="$BREE_SHOW_WELCOME_FILE"
    builtin unset BREE_SHOW_WELCOME_FILE
fi

if [[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"
    builtin unset GHOSTTY_ZSH_ZDOTDIR
elif [[ -n "${BREE_ZSH_ZDOTDIR+X}" \
   && "$BREE_ZSH_ZDOTDIR" != "${BREE_SHELL_INTEGRATION_DIR:-}" \
   && "$BREE_ZSH_ZDOTDIR" != */Contents/Resources/shell-integration ]]; then
    builtin export ZDOTDIR="$BREE_ZSH_ZDOTDIR"
    builtin unset BREE_ZSH_ZDOTDIR
else
    builtin unset ZDOTDIR
    builtin unset BREE_ZSH_ZDOTDIR
fi

{
    # zsh treats unset ZDOTDIR as if it were HOME. We do the same.
    builtin typeset _bree_file="${ZDOTDIR-$HOME}/.zshenv"
    [[ ! -r "$_bree_file" ]] || builtin source -- "$_bree_file"

    if [[ -o interactive \
       && -z "${ZSH_EXECUTION_STRING:-}" \
       && "${BREE_SHELL_INTEGRATION:-1}" != "0" \
       && -n "${BREE_SHELL_INTEGRATION_DIR:-}" \
       && -r "${BREE_SHELL_INTEGRATION_DIR}/bree-zsh-integration.zsh" \
       && "${TERM:-}" == "xterm-256color" \
       && -z "${BREE_ZSH_RESTORE_TERM:-}" ]]; then
        # Keep startup TERM-compatible prompt/theme selection during shell init,
        # then restore the managed xterm-256color identity before the first
        # interactive command executes.
        builtin export BREE_ZSH_RESTORE_TERM="$TERM"
        builtin export TERM="xterm-ghostty"
        builtin typeset -g _BREE_DELAY_TERM_RESTORE_UNTIL_FIRST_PROMPT=1
    fi
} always {
    if [[ -o interactive ]]; then
        # We overwrote GhosttyKit's injected ZDOTDIR, so manually load Ghostty's
        # zsh integration if available.
        #
        # We can't rely on GHOSTTY_ZSH_ZDOTDIR here because Ghostty's own zsh
        # bootstrap unsets it before chaining into this bree wrapper.
        if [[ "${BREE_LOAD_GHOSTTY_ZSH_INTEGRATION:-0}" == "1" ]]; then
            if [[ -n "${BREE_SHELL_INTEGRATION_DIR:-}" ]]; then
                builtin typeset _bree_ghostty="$BREE_SHELL_INTEGRATION_DIR/ghostty-integration.zsh"
            fi
            if [[ ! -r "${_bree_ghostty:-}" && -n "${GHOSTTY_RESOURCES_DIR:-}" ]]; then
                builtin typeset _bree_ghostty="$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
            fi
            [[ -r "$_bree_ghostty" ]] && builtin source -- "$_bree_ghostty"
        fi

        # Load bree integration (unless disabled)
        if [[ "${BREE_SHELL_INTEGRATION:-1}" != "0" && -n "${BREE_SHELL_INTEGRATION_DIR:-}" ]]; then
            builtin typeset _bree_integ="$BREE_SHELL_INTEGRATION_DIR/bree-zsh-integration.zsh"
            [[ -r "$_bree_integ" ]] && builtin source -- "$_bree_integ"
        fi
    fi

    builtin unset _bree_file _bree_ghostty _bree_integ _BREE_BOOTSTRAP_WELCOME_FILE
}
