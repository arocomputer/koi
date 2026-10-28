# Koi puts this directory on XDG_DATA_DIRS for fish shells it starts, so
# fish loads it for every new shell. Inside Koi, interactive shells emit
# OSC 133 prompt markers for Previous/Next Prompt and name each command
# for pane headers.
status is-interactive; or exit
test "$TERM_PROGRAM" = Koi; or exit
function __koi_preexec --on-event fish_preexec
    set -l name ''
    for w in (string split ' ' -- $argv[1])
        string match -q -- '*=*' $w; and continue
        contains -- $w sudo doas nohup exec time command builtin; and continue
        set name (path basename -- $w)
        break
    end
    printf '\e]133;C\a\e]7502;cmd=%s\a' $name
end
function __koi_postexec --on-event fish_postexec
    printf '\e]133;D;%s\a' $status
end
function __koi_prompt --on-event fish_prompt
    printf '\e]133;A\a'
end
if functions -q fish_prompt; and not functions -q __koi_user_prompt
    functions -c fish_prompt __koi_user_prompt
    function fish_prompt
        __koi_user_prompt
        printf '\e]133;B\a'
    end
end
