# vim:ft=zsh
#
# Compatibility shim: with the current integration model, bree restores
# ZDOTDIR in .zshenv so this file should never be reached. If it is, restore
# ZDOTDIR and behave like vanilla zsh by sourcing the user's .zlogin.

if [[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"
    builtin unset GHOSTTY_ZSH_ZDOTDIR
elif [[ -n "${BREE_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$BREE_ZSH_ZDOTDIR"
    builtin unset BREE_ZSH_ZDOTDIR
else
    builtin unset ZDOTDIR
fi

builtin typeset _bree_file="${ZDOTDIR-$HOME}/.zlogin"
[[ ! -r "$_bree_file" ]] || builtin source -- "$_bree_file"
builtin unset _bree_file
