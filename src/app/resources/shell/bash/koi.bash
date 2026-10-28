# Koi prompt integration for bash. bash has no startup hook Koi can use
# without editing your files, so source this yourself from ~/.bashrc:
#   [[ ${TERM_PROGRAM-} == Koi ]] && source "$KOI_SHELL_INTEGRATION/bash/koi.bash"
# Inside Koi it emits OSC 133 prompt markers for Previous/Next Prompt and
# names each command for pane headers.
[[ ${TERM_PROGRAM-} == Koi && $- == *i* ]] || return 0
_koi_at_prompt=1
_koi_precmd() {
  local code=$?
  _koi_at_prompt=1
  printf '\033]133;D;%s\007\033]133;A\007' "$code"
}
_koi_preexec() {
  [[ -n ${COMP_LINE-} || -z $_koi_at_prompt ]] && return
  [[ $BASH_COMMAND == _koi_precmd* ]] && return
  _koi_at_prompt=
  local w name=''
  for w in $BASH_COMMAND; do
    case $w in *=*|sudo|doas|nohup|exec|time|command|builtin) continue;; esac
    name=${w##*/}; break
  done
  printf '\033]133;C\007\033]7502;cmd=%s\007' "$name"
}
PROMPT_COMMAND="_koi_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
[[ $PS1 == *'\e]133;B'* ]] || PS1="$PS1"'\[\e]133;B\a\]'
trap '_koi_preexec' DEBUG
