# Koi starts zsh with ZDOTDIR pointing here, so its startup files read from
# this directory first. Each one runs the user's own file with the user's
# ZDOTDIR restored, so configurations that refer to $ZDOTDIR keep working;
# after .zshrc the user's ZDOTDIR stays, and Koi's hooks are installed.
typeset -g _koi_integration_dir=$ZDOTDIR
if [[ -n ${KOI_ZDOTDIR-} ]]; then ZDOTDIR=$KOI_ZDOTDIR; else unset ZDOTDIR; fi
unset KOI_ZDOTDIR
[[ -r ${ZDOTDIR:-$HOME}/.zshenv ]] && builtin source "${ZDOTDIR:-$HOME}/.zshenv"
if [[ -o interactive ]]; then
  # Keep reading Koi's files until .zshrc has run; a script reads only this one.
  typeset -g _koi_user_dir=${ZDOTDIR-}
  ZDOTDIR=$_koi_integration_dir
fi
