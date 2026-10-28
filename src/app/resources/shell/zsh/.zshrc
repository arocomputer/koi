# Runs the user's .zshrc, then adds Koi's prompt integration for shells
# inside Koi: OSC 133 markers for Previous/Next Prompt and the running
# command's name for pane headers. See .zshenv.
if [[ -n $_koi_user_dir ]]; then ZDOTDIR=$_koi_user_dir; else unset ZDOTDIR; fi
[[ -r ${ZDOTDIR:-$HOME}/.zshrc ]] && builtin source "${ZDOTDIR:-$HOME}/.zshrc"
unset _koi_user_dir _koi_integration_dir
if [[ ${TERM_PROGRAM-} == Koi ]] && autoload -Uz add-zsh-hook; then
  _koi_precmd() {
    local code=$?
    builtin printf '\033]133;D;%s\007\033]133;A\007' "$code"
    [[ ${PROMPT-} == *$'\e]133;B'* ]] || PROMPT+=$'%{\e]133;B\a%}'
  }
  _koi_preexec() {
    local -a words; words=(${(z)1})
    local w; for w in $words; do
      [[ $w == *=* || $w == (sudo|doas|nohup|exec|time|command|builtin|noglob) ]] || break
    done
    builtin printf '\033]133;C\007\033]7502;cmd=%s\007' "${w:t}"
  }
  add-zsh-hook precmd _koi_precmd
  add-zsh-hook preexec _koi_preexec
fi
