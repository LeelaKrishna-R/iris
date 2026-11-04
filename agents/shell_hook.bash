# Iris tells you when a long command finishes (bash; agents/shell_hook.zsh is the zsh one).
#
#   source /path/to/iris/agents/shell_hook.bash     # in ~/.bashrc (on macOS, ~/.bash_profile)
#
# The same as the zsh hook: a command that ran IRIS_LONG_S seconds or more (30 by default) is said aloud as "your
# make command finished" (or "failed"), or, while you're on a call (`iris busy`), she only glances up. Only the
# program's name is said, never its arguments. Works with the bash 3.2 macOS ships: a DEBUG trap stands in for
# zsh's preexec and PROMPT_COMMAND for precmd.

: "${IRIS_LONG_S:=30}"
: "${IRIS_CLI:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/iris_cli.py}"

_iris_preexec() {
  [ -n "$_iris_in_prompt" ] && return        # the prompt's own commands, not yours
  [ -n "$_iris_t0" ] && return               # a line of several commands is timed from its first
  local first=${1%% *}
  _iris_cmd=${first##*/}
  _iris_t0=$SECONDS
}

_iris_precmd() {
  local code=$?
  _iris_in_prompt=1
  [ -n "$_iris_t0" ] || return 0
  local took=$(( SECONDS - _iris_t0 )) cmd=$_iris_cmd
  unset _iris_t0 _iris_cmd
  [ "$took" -ge "$IRIS_LONG_S" ] || return 0
  local what="your $cmd command finished"
  [ "$code" -eq 0 ] || what="your $cmd command failed"
  local said
  said="$(printf %s "${what:0:1}" | tr '[:lower:]' '[:upper:]')${what:1}."
  ( (
    if python3 "$IRIS_CLI" busy >/dev/null 2>&1; then
      python3 "$IRIS_CLI" notice "$what" >/dev/null 2>&1
    else
      python3 "$IRIS_CLI" say "$said" >/dev/null 2>&1
    fi
  ) & )
  return 0
}

_iris_in_prompt=1                            # the rest of the line that sourced this isn't timed
trap '_iris_preexec "$BASH_COMMAND"' DEBUG
PROMPT_COMMAND="_iris_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}; _iris_in_prompt="
