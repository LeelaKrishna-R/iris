# Iris tells you when a long command finishes.
#
#   source /path/to/iris/agents/shell_hook.zsh      # in ~/.zshrc
#
# A command that ran IRIS_LONG_S seconds or more (30 by default): she says "your make command finished" (or
# "failed") aloud, or, while you're on a call (`iris busy`), only glances up. Only the program's name is said,
# never its arguments: those can hold paths, hosts or tokens. Set IRIS_LONG_S=0 to hear about everything.

zmodload zsh/datetime 2>/dev/null
autoload -Uz add-zsh-hook

: ${IRIS_LONG_S:=30}
: ${IRIS_CLI:=${${(%):-%x}:A:h}/iris_cli.py}

_iris_preexec() {
  local -a words
  words=(${(z)1})
  _iris_cmd=${words[1]:t}
  _iris_t0=$EPOCHSECONDS
}

_iris_precmd() {
  local code=$?
  [[ -n $_iris_t0 ]] || return
  local took=$(( EPOCHSECONDS - _iris_t0 ))
  local cmd=$_iris_cmd
  unset _iris_t0 _iris_cmd
  (( took >= IRIS_LONG_S )) || return
  local what="your $cmd command finished"
  (( code == 0 )) || what="your $cmd command failed"
  {
    if python3 "$IRIS_CLI" busy >/dev/null 2>&1; then
      python3 "$IRIS_CLI" notice "$what" >/dev/null 2>&1
    else
      python3 "$IRIS_CLI" say "${(C)what[1]}${what[2,-1]}." >/dev/null 2>&1
    fi
  } &!
}

add-zsh-hook preexec _iris_preexec
add-zsh-hook precmd _iris_precmd
