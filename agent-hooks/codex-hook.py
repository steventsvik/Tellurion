#!/usr/bin/env python3
"""Codex telemetry for Tellurion. Never decides PermissionRequest hooks.

Keep rich tool data in private local JSONL; OSC notifications carry only identity and
status, safely below the terminal's 255-byte body limit. Claude's adapter is independent.
"""
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import tempfile


def identifier(value):
    return value if isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,100}", value) else None


def transcript_metadata(path):
    try:
        with open(path, encoding="utf-8") as stream:
            record = json.loads(stream.readline(65536))
    except (OSError, ValueError, TypeError):
        return {}
    # Any JSON can be on that line: only an object holding an object is what's expected.
    if not isinstance(record, dict) or record.get("type") != "session_meta":
        return {}
    meta = record.get("payload")
    return meta if isinstance(meta, dict) else {}


def tty_path():
    bound = os.environ.get("GHOSTTY_EXTREME_CODEX_TTY", "")
    if re.fullmatch(r"/dev/ttys[0-9]+", bound):
        return bound
    try:
        descriptor = os.open("/dev/tty", os.O_WRONLY | os.O_NOCTTY)
        os.close(descriptor)
        return "/dev/tty"
    except OSError:
        pid = os.getppid()
        for _ in range(32):
            if pid <= 1:
                break
            try:
                row = subprocess.check_output(
                    ["/bin/ps", "-o", "ppid=,tty=", "-p", str(pid)], text=True,
                    stderr=subprocess.DEVNULL, timeout=0.2).split()
                if len(row) != 2:
                    break
                pid = int(row[0])
                if row[1] not in ("??", "?"):
                    return "/dev/" + row[1]
            except (OSError, ValueError, subprocess.SubprocessError):
                break
    return None


def prompt_text(prompt):
    """What the user asked: without image placeholders and paste wrappers, and for a
    Visual Fix request, the change they described."""
    text = re.sub(r"\[Image #\d+\]|</?pasted_content[^>]*>", "", str(prompt or ""))
    change = re.search(r"\nChange: ([^\n]*)", text)
    if change and re.search(r"(^|\n)Visual fix #\d+:", text):
        return "Visual fix: " + change.group(1)
    return text


def tool_name(payload):
    name = payload.get("tool_name")
    return name if isinstance(name, str) else ""


def compact_detail(payload, event):
    tool = tool_name(payload)
    arguments = payload.get("tool_input") or {}
    if not isinstance(arguments, dict):
        arguments = {}
    if event == "prompt_submit":
        detail = prompt_text(payload.get("prompt", ""))
    elif event in ("pre_tool_use", "tool_complete", "permission_request"):
        argument = arguments.get("command", arguments.get("cmd", arguments.get("file_path", "")))
        detail = f"{tool}: {argument}" if argument else tool
    else:
        detail = ""
    return " ".join(str(detail).split())[:48]


# Each session's events are kept for the editor's live view, and nothing else removed them.
TRACKING_DAYS = 14


def prune_tracking(directory):
    """Removes tracking files no event has touched for two weeks. At most once a day, told by
    a stamp file, so a hook normally pays one stat for it. Never the hook's problem."""
    try:
        stamp = directory / ".pruned"
        now = time.time()
        try:
            if now - stamp.stat().st_mtime < 86400:
                return
        except OSError:
            pass
        # Stamped first: hooks running at the same moment don't all go through the folder.
        stamp.touch(mode=0o600)
        with os.scandir(directory) as entries:
            for entry in entries:
                try:
                    if entry.name != stamp.name and entry.is_file(follow_symlinks=False) \
                            and now - entry.stat(follow_symlinks=False).st_mtime > TRACKING_DAYS * 86400:
                        os.remove(entry.path)
                except OSError:
                    pass
    except Exception:  # noqa: BLE001 - tidying up must never fail a hook
        pass


def codex_background_session(payload, home):
    """Codex's own memory-writing agent runs as a separate session in its memories folder,
    from the same terminal. It isn't the pane's agent, so it must not show as its task."""
    cwd = payload.get("cwd")
    if not isinstance(cwd, str) or not cwd:
        return False
    codex_home = Path(os.environ.get("CODEX_HOME") or home / ".codex")
    try:
        return Path(cwd).resolve().is_relative_to((codex_home / "memories").resolve())
    except (OSError, ValueError):
        return False


def record_event(payload, event, home):
    session = identifier(payload.get("session_id"))
    if not session or codex_background_session(payload, home):
        return None
    transcript = payload.get("transcript_path")
    meta = transcript_metadata(transcript) if isinstance(transcript, str) else {}
    actual = identifier(meta.get("id")) or session
    child = identifier(payload.get("agent_id")) if event.startswith("subagent_") else None
    directory = home / ".ghostty-extreme" / "codex-tracking"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(directory, 0o700)
    prune_tracking(directory)
    record = {"event": event, "timestamp": time.time(), "session": actual,
              "parent": session if actual != session else None,
              "child": child, "payload": payload}
    # Lock across parallel tool hooks; one complete JSON record per append.
    path = directory / f"{actual}.jsonl"
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(descriptor, "a", encoding="utf-8") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.write(json.dumps(record, ensure_ascii=True, separators=(",", ":")) + "\n")
    if isinstance(transcript, str) and meta.get("id") == actual:
        descriptor, temporary = tempfile.mkstemp(dir=directory)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump({"id": actual, "transcript": transcript}, stream)
        os.replace(temporary, directory / f"{actual}.json")
    if actual != session or child:
        # A child finishing never marks its parent Done or clears its parent pane.
        return None
    mapped = {"pre_tool_use": "tool_start", "interrupt": "input_needed"}.get(event, event)
    detail = compact_detail(payload, event)
    if event == "pre_tool_use" and tool_name(payload).split(".")[-1] in (
            "request_user_input", "request_user_input_async"):
        mapped = "input_needed"
        detail = "Waiting for your answer"
    # This launch's secret, so the app can tell real events from printed text. Added before the
    # trim: the terminal caps a notification body at 255 bytes, and what counts is everything
    # that's sent, as it's sent (a Cyrillic letter is six bytes escaped, an emoji twelve).
    result = {"agent": "codex", "event": mapped, "session": session, "detail": detail,
              "t": os.environ.get("GHOSTTY_EXTREME_EVENT_TOKEN", "")}
    while result["detail"] and len(encoded(result)) > 250:
        result["detail"] = result["detail"][:-1]
    return result


def encoded(status):
    """The notification body exactly as it goes to the terminal."""
    return json.dumps(status, ensure_ascii=True, separators=(",", ":")).encode()


def localhost_context(payload, event, home):
    if event != "pre_tool_use" or os.environ.get("GHOSTTY_EXTREME_AGENT_EVENTS") != "1":
        return None
    if payload.get("tool_name") not in ("Bash", "exec_command", "shell", "local_shell"):
        return None
    arguments = payload.get("tool_input") or {}
    if not isinstance(arguments, dict):
        return None
    command = arguments.get("command", arguments.get("cmd"))
    launcher = home / ".ghostty-extreme" / "bin" / "localhost"
    if not isinstance(command, str) or not launcher.is_file():
        return None
    try:
        cwd_arg = arguments.get("workdir", payload.get("cwd"))
        extra = ["--cwd", cwd_arg] if isinstance(cwd_arg, str) and cwd_arg else []
        rewritten = subprocess.check_output([str(launcher), "rewrite", command, *extra],
                                            text=True, stderr=subprocess.DEVNULL, timeout=1).strip()
    except (OSError, subprocess.SubprocessError):
        return None
    if not rewritten:
        return None
    cwd = arguments.get("workdir", payload.get("cwd"))
    if isinstance(cwd, str):
        import shlex
        rewritten = f"cd {shlex.quote(cwd)} && {rewritten}"
    rewritten = rewritten.replace("/bin/localhost start ", "/bin/localhost start --agent codex ", 1)
    updated = dict(arguments)
    updated["command" if "command" in arguments else "cmd"] = rewritten
    # Codex (as of 0.166) takes a changed command from a hook only together with "allow", and
    # has no "ask". `localhost rewrite` only changes known dev-server commands inside the
    # project, so that is all this allows. The tool's sandbox and escalation arguments are kept.
    return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow",
        "updatedInput": updated, "additionalContext":
        "The dev server command now opens a Tellurion localhost session: a separate "
        "terminal tab that keeps running after you finish. The command prints the URL and "
        "log commands. Do not start another copy."}}


def shared_memory(payload):
    """What Claude Code remembers about the project, for a new Codex session."""
    cwd = payload.get("cwd")
    if not isinstance(cwd, str) or not cwd:
        return None
    try:
        # No __pycache__ in the user's hooks folder.
        sys.dont_write_bytecode = True
        from memory_context import context
        text = context("codex", cwd)
    except Exception:  # noqa: BLE001 - never fail a session start
        return None
    return {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": text}} if text else None


def main():
    if os.environ.get("GHOSTTY_EXTREME_AGENT_EVENTS") != "1" and os.environ.get("GHOSTTY_CUSTOM_AGENT_EVENTS") != "1":
        return
    event = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict):
            return
        # Where the app keeps .ghostty-extreme: the home folder, or a test copy's own.
        home = Path(os.environ.get("TELLURION_TEST_HOME") or Path.home())
        status = record_event(payload, event, home)
        if status:
            namespace = "ghostty-extreme" if os.environ.get("GHOSTTY_EXTREME_AGENT_EVENTS") == "1" else "ghostty-custom"
            sequence = f"\x1b]777;notify;{namespace}://agent;{encoded(status).decode()}\x07"
            tty = tty_path()
            if tty:
                try:
                    with open(tty, "w", encoding="utf-8") as stream:
                        stream.write(sequence)
                except OSError:
                    pass
        context = localhost_context(payload, event, home)
        if event == "session_start" and os.environ.get("GHOSTTY_EXTREME_AGENT_EVENTS") == "1":
            context = shared_memory(payload)
        if context:
            print(json.dumps(context))
    except Exception:  # noqa: BLE001
        # Observability must never fail a tool, delay an exit, or block a turn, whatever
        # shape the payload turns out to have.
        pass


if __name__ == "__main__":
    main()
