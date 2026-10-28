# Runs the user's .zprofile; see .zshenv.
if [[ -n $_koi_user_dir ]]; then ZDOTDIR=$_koi_user_dir; else unset ZDOTDIR; fi
[[ -r ${ZDOTDIR:-$HOME}/.zprofile ]] && builtin source "${ZDOTDIR:-$HOME}/.zprofile"
typeset -g _koi_user_dir=${ZDOTDIR-}
ZDOTDIR=$_koi_integration_dir
