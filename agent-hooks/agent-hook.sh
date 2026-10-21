#!/bin/bash
# Reports coding-agent activity to Tellurion's vertical tabs sidebar.
#
# Usage (from an agent's hooks): agent-hook.sh <agent> <event>
#   agent: claude | codex
#   event: session_start | prompt_submit | tool_complete | permission_request |
#          notification | stop | stop_failure | session_end | pre_tool_use |
#          subagent_start | subagent_stop
#
# Emits an OSC 777 notification titled "ghostty-extreme://agent" with a compact JSON
# body. Tellurion consumes it silently; it is never shown as a notification.
# At session start it also adds what Codex remembers about the project (shared memory,
# memory_context.py) to Claude Code's context.
#   - Claude Code: printed as the `terminalSequence` hook field, so Claude Code
#     writes it to its own terminal.
#   - Others (Codex): written to the agent's terminal; nothing is printed, so the
#     agent sees an empty hook result.
#
# The one thing it changes: when Claude Code starts a dev server or tunnel (`npm run dev`,
# `vite`, `ssh -L`, a command that ran in a localhost session here before, ...), the command is rewritten to open it in a Tellurion localhost
# session instead, a separate tab that keeps the server running after the agent is
# done. Claude Code still asks for permission as usual, showing the rewritten command.
# It never approves or denies anything.

# Only inside Tellurion; anywhere else (including official Ghostty) do nothing.
# The pre-rebrand "Ghostty Custom" build is still served until it's replaced.
if [ "${GHOSTTY_EXTREME_AGENT_EVENTS:-}" = "1" ]; then
  namespace="ghostty-extreme"
elif [ "${GHOSTTY_CUSTOM_AGENT_EVENTS:-}" = "1" ]; then
  namespace="ghostty-custom"
else
  exit 0
fi
command -v jq >/dev/null 2>&1 || exit 0

agent="${1:-}"
event="${2:-}"
# Codex has its own event adapter; the Claude protocol below stays unchanged.
if [ "$agent" = "codex" ]; then
  exec python3 "$(dirname "$0")/codex-hook.py" "$event"
fi
input=$(cat)

# Dev servers Claude Code starts go to a localhost session (Tellurion only).
if [ "$event" = "pre_tool_use" ]; then
  [ "$agent" = "claude" ] && [ "$namespace" = "ghostty-extreme" ] || exit 0
  launcher="$HOME/.ghostty-extreme/bin/localhost"
  [ -x "$launcher" ] || exit 0
  # Turned off in Tellurion's Settings.
  [ -e "$HOME/.ghostty-extreme/features/localhost-off" ] && exit 0
  [ "$(jq -r '.tool_name // empty' <<<"$input")" = "Bash" ] || exit 0
  command=$(jq -r '.tool_input.command // empty' <<<"$input")
  cwd=$(jq -r '.cwd // empty' <<<"$input")
  background=$(jq -r 'if .tool_input.run_in_background == true then "--background" else empty end' <<<"$input")
  rewritten=$("$launcher" rewrite "$command" ${cwd:+--cwd "$cwd"} $background 2>/dev/null) || exit 0
  [ -n "$rewritten" ] || exit 0
  jq -c --arg cmd "$rewritten" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      updatedInput: (.tool_input + {command: $cmd, run_in_background: false}),
      additionalContext: "The server was moved to a Tellurion localhost session: a separate terminal tab the user manages, which keeps running after you finish. The command prints its URL and where its logs are. Do not start the server again yourself."
    }
  }' <<<"$input"
  exit 0
fi

# Registered for Codex, but not reported to the sidebar yet.
case "$event" in pre_tool_use|subagent_start|subagent_stop) exit 0 ;; esac

# Ghostty caps notification bodies at 255 bytes, so keep details short.
# Every event carries this launch's secret, so the app can tell real events from printed text.
token="${GHOSTTY_EXTREME_EVENT_TOKEN:-}"
sequence=$(jq -r --arg agent "$agent" --arg event "$event" --arg ns "$namespace" --arg t "$token" '
  def clip: gsub("[\\s]+"; " ") | ltrimstr(" ") | if length > 48 then .[0:47] + "…" else . end;
  # What the user asked: without image placeholders and paste wrappers, and for a Visual
  # Fix request, the change they described.
  def prompt_text:
    gsub("\\[Image #[0-9]+\\]"; "") | gsub("</?pasted_content[^>]*>"; "")
    | if test("(^|\n)Visual fix #[0-9]+:") and test("\nChange: ")
      then "Visual fix: " + (capture("\nChange: (?<c>[^\n]*)").c) else . end;
  def tool_detail:
    (.tool_name // "") as $tool
    | (.tool_input.command // .tool_input.file_path // .tool_input.url // "" | tostring) as $arg
    | if $arg == "" then $tool else "\($tool): \($arg)" end;

  (if $event == "notification" then
     (if .notification_type == "permission_prompt" then "permission_request"
      elif .notification_type == "elicitation_dialog" then "input_needed"
      else empty end)
   else $event end) as $e
  | {
      event: $e,
      detail: (
        if $e == "prompt_submit" then (.prompt // "" | prompt_text)
        elif $e == "permission_request" or $e == "tool_complete" then tool_detail
        elif $e == "input_needed" then (.message // "")
        else "" end | clip)
    }
  | {agent: $agent, t: $t} + .
  | "\u001b]777;notify;\($ns)://agent;\(tojson)\u0007"
' <<<"$input" 2>/dev/null) || exit 0

# Where this session's transcript lives, so the editor can show the agent's thinking and
# actions live. Sent separately to stay under Ghostty's 255-byte notification body limit.
if [ "$event" = "session_start" ] || [ "$event" = "prompt_submit" ]; then
  transcript=$(jq -r '.transcript_path // empty' <<<"$input" 2>/dev/null)
  # A long path doesn't fit: send the session's file name, and the app finds the file.
  if [ ${#transcript} -ge 160 ]; then transcript=$(basename "$transcript" .jsonl); fi
  if [ -n "$transcript" ] && [ ${#transcript} -lt 160 ]; then
    sequence+=$(jq -rn --arg agent "$agent" --arg path "$transcript" --arg ns "$namespace" --arg t "$token" \
      '"\u001b]777;notify;\($ns)://agent;\({agent: $agent, t: $t, event: "transcript", detail: $path} | tojson)\u0007"')
  fi
fi
[ -n "$sequence" ] || exit 0

# The terminal the agent runs in. Codex starts hooks without a controlling terminal,
# so /dev/tty fails there; walk up to the first ancestor that has one.
agent_tty() {
  if { : > /dev/tty; } 2>/dev/null; then echo /dev/tty; return; fi
  local pid=$PPID t
  while [ "${pid:-1}" -gt 1 ]; do
    t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$t" in ""|"??") ;; *) echo "/dev/$t"; return ;; esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
}

if [ "$agent" = "claude" ]; then
  # Shared memory: a new session starts with what Codex remembers about the project.
  shared=""
  if [ "$event" = "session_start" ] && [ "$namespace" = "ghostty-extreme" ] && command -v python3 >/dev/null 2>&1; then
    cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)
    [ -n "$cwd" ] && shared=$(python3 "$(dirname "$0")/memory_context.py" claude "$cwd" 2>/dev/null)
  fi
  jq -nc --arg seq "$sequence" --arg ctx "$shared" '{terminalSequence: $seq}
    + (if $ctx == "" then {} else {hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}} end)'
else
  tty_path=$(agent_tty)
  [ -n "$tty_path" ] && printf '%s' "$sequence" > "$tty_path" 2>/dev/null
fi

exit 0
