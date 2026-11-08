# Tellurion: tells the vertical tabs sidebar which coding agent a pane is running,
# the way Warp recognizes agents from the command line. Starting `claude`, `codex`, etc.
# marks the pane with that agent immediately; the mark clears when the command exits,
# even if the agent crashed. The agents' own hooks (agent-hook.sh) add live status.
#
# Sourced from ~/.zshrc. Does nothing outside Tellurion.

# The pre-rebrand "Ghostty Custom" build is still served until it's replaced.
if [[ "${GHOSTTY_EXTREME_AGENT_EVENTS:-}" == 1 ]]; then
  typeset -g _gc_namespace=ghostty-extreme
elif [[ "${GHOSTTY_CUSTOM_AGENT_EVENTS:-}" == 1 ]]; then
  typeset -g _gc_namespace=ghostty-custom
else
  return 0
fi

typeset -g _gc_running_agent=""

# The shared Codex daemon does not inherit this terminal's environment. Keep local
# terminal sessions attached to this pane so their hooks inherit the correct TTY.
codex() {
  # A pane on Venice or on a model on this Mac (TELLURION_CODEX_BACKEND comes with the pane):
  # Codex with its usual setup, its model requests going where the pane says. This must never
  # fall through to plain Codex, which would send the same work to another provider.
  if [[ ${TELLURION_CODEX_BACKEND:-} == (venice|local) ]]; then
    local _gc_cli="${TELLURION_TEST_HOME:-$HOME}/.ghostty-extreme/bin/tellurion"
    if [[ ! -x $_gc_cli ]]; then
      if [[ $TELLURION_CODEX_BACKEND == venice ]]; then
        print -u2 "Tellurion's command isn't installed, so Codex can't reach Venice. Run Tellurion > Check Setup…"
      else
        print -u2 "Tellurion's command isn't installed, so Codex can't run on the model on this Mac. Run Tellurion > Check Setup…"
      fi
      return 1
    fi
    GHOSTTY_EXTREME_CODEX_TTY="${TTY:-}" "$_gc_cli" "$TELLURION_CODEX_BACKEND" codex "$@"
    return
  fi
  if [[ -n $TTY && -t 1 ]]; then
    GHOSTTY_EXTREME_CODEX_TTY="$TTY" command codex --no-daemon "$@"
  else
    command codex "$@"
  fi
}

# Command name -> agent id (see VerticalTabAgentKind).
typeset -gA _gc_agent_commands=(
  claude claude
  codex codex
  gemini gemini
  opencode opencode
  amp amp
  copilot copilot
  cursor-agent cursor
  agent cursor
  droid droid
  goose goose
  hermes hermes
  agy antigravity
  kiro-cli kiro
  aider aider
  crush crush
  qwen qwen
  kimi kimi
  vibe mistral
)

_gc_agent_event() {
  printf '\e]777;notify;%s://agent;{"agent":"%s","event":"%s","t":"%s"}\a' "$_gc_namespace" "$1" "$2" "${GHOSTTY_EXTREME_EVENT_TOKEN:-}" 2>/dev/null >/dev/tty
}

_gc_agent_preexec() {
  # $3 is the command line with aliases expanded. Skip env assignments and wrappers
  # to find the program actually being run.
  local word venice=""
  for word in ${(z)3}; do
    [[ $word == *=* || $word == (command|exec|env|noglob|nocorrect|time|nohup) ]] && continue
    # `tellurion venice codex …` and `tellurion local codex …` are Codex.
    if [[ ${${(Q)word}:t} == tellurion && $venice != done ]]; then venice=tellurion; continue; fi
    if [[ $venice == tellurion && $word == (venice|local) ]]; then venice=done; continue; fi
    break
  done
  [[ $venice == tellurion ]] && return 0
  local agent=${_gc_agent_commands[${${(Q)word}:t}]}
  [[ -n $agent ]] || return 0
  _gc_running_agent=$agent
  # Hooks often run without a terminal of their own: tell them which pane is theirs.
  export GHOSTTY_EXTREME_AGENT_TTY="$TTY"
  if [[ $agent == codex ]]; then
    # Codex tool hooks need not have a controlling TTY. Bind them to this pane once,
    # rather than guessing from a changing worker-process ancestry.
    export GHOSTTY_EXTREME_CODEX_TTY="$TTY"
  fi
  _gc_agent_event "$agent" session_start
}

_gc_agent_precmd() {
  [[ -n $_gc_running_agent ]] || return 0
  _gc_agent_event "$_gc_running_agent" session_end
  unset GHOSTTY_EXTREME_AGENT_TTY
  [[ $_gc_running_agent == codex ]] && unset GHOSTTY_EXTREME_CODEX_TTY
  _gc_running_agent=""
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _gc_agent_preexec
add-zsh-hook precmd _gc_agent_precmd
