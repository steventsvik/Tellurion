#!/usr/bin/env python3
"""Live status from more coding agents, for Tellurion's sidebar.

Usage (from an agent's hooks): agent-event.py <agent> <hook event>
  agent: copilot | droid | kiro | gemini | antigravity | cursor | qwen | kimi | goose | mistral

Reads the hook's JSON from stdin, turns the agent's own event into one of the sidebar's
(session_start, prompt_submit, tool_complete, permission_request, input_needed, stop,
stop_failure, session_end), and writes it to the agent's terminal as an OSC 777
notification titled "ghostty-extreme://agent". It only observes: it never approves,
denies or changes anything, prints only what each agent needs to carry on ("{}" for the
ones that parse JSON), and always exits 0.
"""
import json
import os
import re
import subprocess
import sys
import time
import uuid

# Agents that parse the hook's stdout as JSON; the rest get nothing.
JSON_REPLY = {"gemini", "antigravity", "cursor", "qwen"}


def text(value):
    return value if isinstance(value, str) else ""


def tool_detail(name, arguments):
    if isinstance(arguments, str):
        try:
            arguments = json.loads(arguments)
        except ValueError:
            arguments = {}
    if not isinstance(arguments, dict):
        arguments = {}
    argument = next((arguments[k] for k in ("command", "cmd", "file_path", "filePath", "path", "url", "pattern")
                     if isinstance(arguments.get(k), str) and arguments.get(k)), "")
    name = text(name)
    return f"{name}: {argument}" if argument else name


def prompt_text(prompt):
    """What the user asked, without image placeholders and paste wrappers."""
    prompt = re.sub(r"\[Image #\d+\]|</?pasted_content[^>]*>", "", text(prompt))
    change = re.search(r"\nChange: ([^\n]*)", prompt)
    if change and re.search(r"(^|\n)Visual fix #\d+:", prompt):
        return "Visual fix: " + change.group(1)
    return prompt


def translate(agent, event, p):
    """(sidebar event, detail) for this agent's hook event, or None to ignore it."""
    tool = tool_detail(p.get("tool_name") or p.get("toolName") or (p.get("toolCall") or {}).get("name"),
                       p.get("tool_input") or p.get("toolArgs") or p.get("toolInput") or (p.get("toolCall") or {}).get("args"))
    kind = text(p.get("notification_type")) or text(p.get("notificationType"))
    # Goose sends the prompt as "message".
    prompt = prompt_text(p.get("prompt") or (p.get("message") if agent == "goose" else "") or os.environ.get("USER_PROMPT", ""))
    common = {
        "session_start": ("session_start", ""), "sessionStart": ("session_start", ""), "SessionStart": ("session_start", ""),
        "session_end": ("session_end", ""), "sessionEnd": ("session_end", ""), "SessionEnd": ("session_end", ""),
        "UserPromptSubmit": ("prompt_submit", prompt), "userPromptSubmitted": ("prompt_submit", prompt),
        "BeforeAgent": ("prompt_submit", prompt), "PreInvocation": ("prompt_submit", prompt),
        "beforeSubmitPrompt": ("prompt_submit", prompt),
        "PostToolUse": ("tool_complete", tool), "postToolUse": ("tool_complete", tool), "AfterTool": ("tool_complete", tool),
        "afterShellExecution": ("tool_complete", tool_detail("Shell", {"command": p.get("command")})),
        "afterFileEdit": ("tool_complete", tool_detail("Edit", {"file_path": p.get("file_path")})),
        "Stop": ("stop", ""), "agentStop": ("stop", ""), "AfterAgent": ("stop", ""),
        "StopFailure": ("stop_failure", text(p.get("error")) or text(p.get("message"))),
        # Kimi: it says when it's asking (and when it got an answer) but can't be answered.
        "PermissionRequest": ("permission_request", tool), "PermissionResult": ("tool_complete", ""),
        "Interrupt": ("stop", ""),
        # Mistral Vibe.
        "post_tool": ("tool_complete", tool), "post_agent": ("stop", ""),
    }
    if event == "stop" and agent == "cursor":
        return ("stop_failure" if p.get("status") == "error" else "stop"), ""
    if event in ("Notification", "notification"):
        if kind in ("permission_prompt", "ToolPermission"):
            return "permission_request", text(p.get("message")) or tool
        if kind == "elicitation_dialog":
            return "input_needed", text(p.get("message"))
        # Droid reports a cancelled turn as idle instead of stopping.
        if kind == "idle_prompt" and agent == "droid":
            return "stop", ""
        return None
    if event == "errorOccurred":
        return None if p.get("recoverable") else ("stop_failure", text((p.get("error") or {}).get("message")))
    if event == "stop" and agent != "cursor":
        return "stop", ""
    return common.get(event)


def clip(detail):
    # One line of printable text: control characters would show up in the sidebar.
    text = "".join(c if c.isprintable() else " " for c in str(detail))
    return " ".join(text.split())[:48]


def tty_path():
    """The agent's terminal. Hooks often run without one, so try the pane the shell
    integration recorded, then the first ancestor process that has a terminal."""
    try:
        descriptor = os.open("/dev/tty", os.O_WRONLY | os.O_NOCTTY)
        os.close(descriptor)
        return "/dev/tty"
    except OSError:
        pass
    bound = os.environ.get("GHOSTTY_EXTREME_AGENT_TTY", "")
    if re.fullmatch(r"/dev/ttys[0-9]+", bound):
        return bound
    pid = os.getppid()
    for _ in range(32):
        if pid <= 1:
            break
        try:
            row = subprocess.check_output(["/bin/ps", "-o", "ppid=,tty=", "-p", str(pid)], text=True,
                                          stderr=subprocess.DEVNULL, timeout=0.2).split()
            if len(row) != 2:
                break
            pid = int(row[0])
            if row[1] not in ("??", "?"):
                return "/dev/" + row[1]
        except (OSError, ValueError, subprocess.SubprocessError):
            break
    return None


# ---------- Live feed for the code editor ----------
#
# The editor shows an agent's prompts and tool calls live by reading its session transcript,
# in Claude Code's format. These agents keep no such transcript (or one in their own
# format), so each event is also appended to a small one of ours, with the same records,
# under ~/.ghostty-extreme/feeds/. Old feeds are removed after a week.

# TELLURION_TEST_HOME moves .ghostty-extreme for a test copy of the app, and the feeds with it.
FEEDS = os.path.join(os.environ.get("TELLURION_TEST_HOME") or os.path.expanduser("~"), ".ghostty-extreme", "feeds")
PATH_KEYS = ("file_path", "filePath", "absolute_path", "target_file", "path", "file", "notebook_path")


def feed_path(agent, p, tty):
    """One feed per session: the agent's session id, or else the pane it runs in."""
    session = next((str(p[k]) for k in ("session_id", "sessionId", "conversation_id", "conversationId", "thread_id")
                    if p.get(k)), "")
    if not session and tty and tty != "/dev/tty":
        session = os.path.basename(tty)
    session = re.sub(r"[^A-Za-z0-9_.-]", "", session)[:64] or str(os.getppid())
    return os.path.join(FEEDS, f"{agent}-{session}.jsonl")


def claude_tool(name, arguments):
    """The tool as Claude Code would name it, so the editor knows what it does."""
    if isinstance(arguments, str):
        try:
            arguments = json.loads(arguments)
        except ValueError:
            arguments = {"command": arguments}
    if not isinstance(arguments, dict):
        arguments = {}
    lowered = text(name).lower().split("__")[-1]
    inputs = {}
    path = next((arguments[k] for k in PATH_KEYS if isinstance(arguments.get(k), str) and arguments[k]), None)
    if path:
        inputs["file_path"] = path
    for key, target in (("command", "command"), ("cmd", "command"), ("pattern", "pattern"), ("query", "query"),
                        ("url", "url"), ("old_string", "old_string"), ("old_str", "old_string"),
                        ("new_string", "new_string"), ("new_str", "new_string"), ("content", "content"),
                        ("file_text", "content"), ("description", "description")):
        if isinstance(arguments.get(key), str) and target not in inputs:
            inputs[target] = arguments[key][:4000]
    # Goose's text editor names its action in "command".
    if lowered in ("text_editor", "str_replace_editor"):
        action = text(arguments.get("command"))
        inputs.pop("command", None)
        return {"view": "Read", "write": "Write", "create": "Write"}.get(action, "Edit"), inputs
    rules = (("TodoWrite", ("todo", "plan")),
             ("Edit", ("edit", "replace", "patch", "str_replace", "multiedit")),
             ("Write", ("write", "create", "save")),
             ("Read", ("read", "view", "cat", "open")),
             ("Bash", ("shell", "bash", "exec", "command", "terminal", "run")),
             ("Grep", ("grep", "search", "glob", "find", "list", "ls")),
             ("WebFetch", ("web", "fetch", "url", "browse")))
    for claude, words in rules:
        if any(word in lowered for word in words):
            return claude, inputs
    return text(name) or "Tool", inputs


def feed_records(agent, event, p, name):
    """The records this event adds to the feed, in Claude Code's transcript format."""
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + "Z"
    if name == "prompt_submit":
        prompt = text(p.get("prompt")) or (text(p.get("message")) if agent == "goose" else "") or os.environ.get("USER_PROMPT", "")
        return [{"type": "user", "timestamp": stamp, "message": {"role": "user", "content": prompt[:8000]}}] if prompt else []
    if name == "tool_complete":
        tool = p.get("tool_name") or p.get("toolName") or (p.get("toolCall") or {}).get("name")
        arguments = p.get("tool_input") or p.get("toolArgs") or p.get("toolInput") or (p.get("toolCall") or {}).get("args")
        if event == "afterFileEdit":
            tool, arguments = "Edit", {"file_path": p.get("file_path")}
        elif event == "afterShellExecution":
            tool, arguments = "Bash", {"command": p.get("command")}
        if not tool:
            return []
        claude, inputs = claude_tool(tool, arguments)
        call = "tool_" + uuid.uuid4().hex[:12]
        output = p.get("tool_response") or p.get("tool_output") or p.get("toolResult") or ""
        if not isinstance(output, str):
            output = json.dumps(output)[:1500]
        return [
            {"type": "assistant", "timestamp": stamp,
             "message": {"role": "assistant", "content": [{"type": "tool_use", "id": call, "name": claude, "input": inputs}]}},
            {"type": "user", "timestamp": stamp,
             "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": call, "content": output[:1500]}]}},
        ]
    if name in ("stop", "stop_failure"):
        reply = text(p.get("last_assistant_message")) or text(p.get("response"))
        return [{"type": "assistant", "timestamp": stamp,
                 "message": {"role": "assistant", "content": [{"type": "text", "text": reply[:8000]}]}}] if reply else []
    return []


def write_feed(path, records):
    # Prompts and tool output: for this user only, like the agents' own transcripts.
    os.makedirs(FEEDS, mode=0o700, exist_ok=True)
    fresh = not os.path.exists(path)
    if fresh:
        os.chmod(FEEDS, 0o700)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(descriptor, "a", encoding="utf-8") as feed:
        os.fchmod(descriptor, 0o600)
        for record in records:
            feed.write(json.dumps(record, ensure_ascii=False) + "\n")
    if fresh:
        week = time.time() - 7 * 86400
        for old in os.listdir(FEEDS):
            full = os.path.join(FEEDS, old)
            try:
                if os.path.getmtime(full) < week:
                    os.remove(full)
            except OSError:
                pass


def main():
    agent = sys.argv[1] if len(sys.argv) > 1 else ""
    event = sys.argv[2] if len(sys.argv) > 2 else ""
    try:
        if os.environ.get("GHOSTTY_EXTREME_AGENT_EVENTS") != "1":
            return
        try:
            payload = json.load(sys.stdin)
        except ValueError:
            payload = {}
        if not isinstance(payload, dict):
            payload = {}
        mapped = translate(agent, event, payload)
        if not mapped:
            return
        name, detail = mapped
        status = {"agent": agent, "event": name, "detail": clip(detail),
                  "t": os.environ.get("GHOSTTY_EXTREME_EVENT_TOKEN", "")}
        # The terminal caps notification bodies at 255 bytes.
        while len(json.dumps(status, ensure_ascii=True, separators=(",", ":")).encode()) > 250 and status["detail"]:
            status["detail"] = status["detail"][:-1]
        sequence = "\x1b]777;notify;ghostty-extreme://agent;" + json.dumps(status, ensure_ascii=True, separators=(",", ":")) + "\x07"
        tty = tty_path()
        # The editor's live feed (OpenCode and Amp write theirs from their plugins).
        if os.environ.get("GHOSTTY_EXTREME_AGENT_FEED", "1") != "0":
            try:
                path = feed_path(agent, payload, tty)
                records = feed_records(agent, event, payload, name)
                if records or not os.path.exists(path):
                    write_feed(path, records)
                if name in ("session_start", "prompt_submit") and len(path) < 160:
                    where = {"agent": agent, "event": "transcript", "detail": path,
                             "t": os.environ.get("GHOSTTY_EXTREME_EVENT_TOKEN", "")}
                    sequence += "\x1b]777;notify;ghostty-extreme://agent;" + json.dumps(where, ensure_ascii=True, separators=(",", ":")) + "\x07"
            except OSError:
                pass
        if tty:
            # Never as a controlling terminal: the hook isn't the terminal's process.
            descriptor = os.open(tty, os.O_WRONLY | os.O_NOCTTY | os.O_NONBLOCK)
            try:
                os.write(descriptor, sequence.encode())
            finally:
                os.close(descriptor)
    except Exception:  # noqa: BLE001 - observing must never break the agent
        pass
    finally:
        if agent == "cursor" and event == "beforeSubmitPrompt":
            # Cursor holds the prompt until this hook says it may go on.
            print('{"continue": true}')
        elif agent in JSON_REPLY:
            print("{}")


if __name__ == "__main__":
    main()
