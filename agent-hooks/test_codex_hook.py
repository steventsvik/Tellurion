import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("codex_hook", Path(__file__).with_name("codex-hook.py"))
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)


class CodexHookTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)

    def transcript(self, session, parent=None):
        file = self.home / (session + ".jsonl")
        file.write_text(json.dumps({"type": "session_meta", "payload": {"id": session, "parent_thread_id": parent}}) + "\n")
        return str(file)

    def test_session_binding_and_long_unicode_status(self):
        session = "01a00000-1111-2222-3333-444444444444"
        path = self.transcript(session)
        status = hook.record_event({"session_id": session, "transcript_path": path, "prompt": "🐋" * 100}, "prompt_submit", self.home)
        self.assertLessEqual(len(json.dumps(status, ensure_ascii=True, separators=(",", ":")).encode()), 250)
        self.assertEqual(status["session"], session)
        manifest = json.loads((self.home / ".ghostty-extreme/codex-tracking" / (session + ".json")).read_text())
        self.assertEqual(manifest["transcript"], path)

    def sent(self, payload, event="prompt_submit", token="0123456789abcdef0123456789abcdef"):
        """What main() writes to the terminal for this payload: the whole notification body."""
        written = io.StringIO()
        written.close = lambda: None
        real_open = open
        environment = {"GHOSTTY_EXTREME_AGENT_EVENTS": "1", "GHOSTTY_EXTREME_EVENT_TOKEN": token,
                       "TELLURION_TEST_HOME": str(self.home)}
        with patch.dict(os.environ, environment, clear=True), patch.object(hook.sys, "argv", ["codex-hook.py", event]), \
                patch.object(hook.sys, "stdin", io.StringIO(json.dumps(payload))), \
                patch.object(hook, "tty_path", return_value="/dev/ttys999"), \
                patch("builtins.open", lambda path, *a, **k: written if path == "/dev/ttys999" else real_open(path, *a, **k)), \
                contextlib.redirect_stdout(io.StringIO()) as printed:
            hook.main()
        self.printed = printed.getvalue()
        text = written.getvalue()
        if not text:
            return None
        self.assertTrue(text.startswith("\x1b]777;notify;ghostty-extreme://agent;") and text.endswith("\x07"), text)
        return text[len("\x1b]777;notify;ghostty-extreme://agent;"):-1].encode()

    def test_the_whole_body_with_its_token_fits_the_terminals_limit(self):
        # The terminal drops what's past 255 bytes, and an event cut short is refused.
        session = "01a00000-1111-2222-3333-444444444444"
        token = "0123456789abcdef0123456789abcdef"
        for name, prompt in (("latin", "x" * 300), ("cyrillic", "Исправь ссылки в навигации и проверь, что всё работает как надо"),
                             ("emoji", "🐋" * 100), ("mixed", "Почини 🐋 the build, пожалуйста, и запусти тесты ещё раз 🐋🐋🐋")):
            body = self.sent({"session_id": session, "prompt": prompt}, token=token)
            self.assertLessEqual(len(body), 250, name)
            status = json.loads(body)
            self.assertEqual(status["t"], token, name)
            self.assertEqual(status["session"], session, name)
            self.assertTrue(status["detail"], name)
            self.assertTrue(prompt.startswith(status["detail"]), name)

    def test_a_long_session_name_still_leaves_a_whole_body(self):
        body = self.sent({"session_id": "s" * 100, "prompt": "🐋" * 100})
        self.assertLessEqual(len(body), 250)
        self.assertEqual(json.loads(body)["session"], "s" * 100)

    def test_odd_payloads_never_raise(self):
        odd_transcript = self.home / "odd.jsonl"
        for first_line in ("[1, 2]", '"text"', "7", "null", '{"type": "session_meta", "payload": [1]}',
                           '{"type": "session_meta", "payload": "x"}'):
            odd_transcript.write_text(first_line + "\n")
            self.assertEqual(hook.transcript_metadata(str(odd_transcript)), {}, first_line)
            body = self.sent({"session_id": "odd", "transcript_path": str(odd_transcript)}, "session_start")
            self.assertEqual(json.loads(body)["session"], "odd", first_line)
        for tool in (7, None, ["Bash"], {"name": "Bash"}, True):
            for event in ("pre_tool_use", "tool_complete", "permission_request"):
                body = self.sent({"session_id": "odd", "tool_name": tool, "tool_input": {"command": "ls"}}, event)
                self.assertEqual(json.loads(body)["agent"], "codex", (tool, event))
        for payload in ({"session_id": "odd", "tool_input": "ls", "prompt": ["a"]}, {"session_id": "odd", "cwd": 5},
                        {"session_id": ["x"]}, {"session_id": "odd", "agent_id": {"a": 1}}):
            self.sent(payload, "pre_tool_use")
            self.sent(payload, "subagent_stop")

    def test_tracking_follows_the_test_home(self):
        self.sent({"session_id": "here"}, "session_start")
        self.assertTrue((self.home / ".ghostty-extreme/codex-tracking/here.jsonl").exists())

    def test_old_tracking_files_are_removed_once_a_day(self):
        folder = self.home / ".ghostty-extreme/codex-tracking"
        hook.record_event({"session_id": "first"}, "session_start", self.home)
        long_ago = time.time() - 15 * 86400
        recent = time.time() - 13 * 86400
        for name, when in (("old.jsonl", long_ago), ("old.json", long_ago), ("kept.jsonl", recent)):
            (folder / name).write_text("{}\n")
            os.utime(folder / name, (when, when))
        hook.record_event({"session_id": "second"}, "session_start", self.home)
        self.assertTrue((folder / "old.jsonl").exists(), "already looked today")
        yesterday = time.time() - 2 * 86400
        os.utime(folder / ".pruned", (yesterday, yesterday))
        hook.record_event({"session_id": "third"}, "session_start", self.home)
        self.assertEqual(sorted(p.name for p in folder.iterdir() if p.name.startswith(("old", "kept"))), ["kept.jsonl"])
        self.assertTrue((folder / "first.jsonl").exists())
        self.assertLess(time.time() - (folder / ".pruned").stat().st_mtime, 60)

    def test_a_folder_that_cant_be_tidied_doesnt_stop_the_event(self):
        with patch.object(hook.os, "scandir", side_effect=PermissionError("no")):
            self.assertIsNotNone(hook.record_event({"session_id": "parent"}, "session_start", self.home))
        with patch.object(hook.Path, "touch", side_effect=RuntimeError("odd")):
            self.assertIsNotNone(hook.record_event({"session_id": "parent"}, "stop", self.home))

    @unittest.skipUnless(shutil.which("jq"), "the Claude Code hook needs jq")
    def test_claude_events_fit_the_limit_too(self):
        script = str(Path(__file__).with_name("agent-hook.sh"))
        environment = {"PATH": os.environ.get("PATH", ""), "HOME": str(self.home), "GHOSTTY_EXTREME_AGENT_EVENTS": "1",
                       "GHOSTTY_EXTREME_EVENT_TOKEN": "0123456789abcdef0123456789abcdef"}
        for name, prompt in (("emoji", "🐋" * 48), ("more emoji", "🐋" * 300), ("cyrillic", "ж" * 300), ("latin", "x" * 300)):
            result = subprocess.run(["/bin/bash", script, "claude", "prompt_submit"], input=json.dumps({"prompt": prompt}),
                                    capture_output=True, text=True, env=environment, timeout=10)
            sequence = json.loads(result.stdout)["terminalSequence"]
            body = sequence[len("\x1b]777;notify;ghostty-extreme://agent;"):-1]
            self.assertLessEqual(len(body.encode()), 250, name)
            status = json.loads(body)
            self.assertEqual(status["t"], environment["GHOSTTY_EXTREME_EVENT_TOKEN"], name)
            self.assertTrue(status["detail"] and prompt.startswith(status["detail"].rstrip("…")), name)
        short = subprocess.run(["/bin/bash", script, "claude", "prompt_submit"], input=json.dumps({"prompt": "Fix the links"}),
                               capture_output=True, text=True, env=environment, timeout=10)
        self.assertIn('"detail":"Fix the links"', json.loads(short.stdout)["terminalSequence"])

    def test_codex_events_dont_need_jq(self):
        # The Codex adapter is Python: a Mac without jq still reports Codex.
        tools = self.home / "tools"
        tools.mkdir()
        for tool in ("python3", "dirname", "cat"):
            os.symlink(shutil.which(tool), tools / tool)
        environment = {"PATH": str(tools), "HOME": str(self.home), "TELLURION_TEST_HOME": str(self.home),
                       "GHOSTTY_EXTREME_AGENT_EVENTS": "1", "GHOSTTY_EXTREME_EVENT_TOKEN": "t"}
        script = str(Path(__file__).with_name("agent-hook.sh"))
        result = subprocess.run(["/bin/bash", script, "codex", "session_start"], input='{"session_id":"nojq"}',
                                capture_output=True, text=True, env=environment, timeout=10, start_new_session=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.home / ".ghostty-extreme/codex-tracking/nojq.jsonl").exists())

    def test_child_never_marks_parent_done(self):
        path = self.transcript("child", "parent")
        self.assertIsNone(hook.record_event({"session_id": "parent", "transcript_path": path}, "stop", self.home))
        self.assertIsNone(hook.record_event({"session_id": "parent", "agent_id": "child"}, "subagent_stop", self.home))
        records = (self.home / ".ghostty-extreme/codex-tracking/child.jsonl").read_text().splitlines()
        self.assertEqual(json.loads(records[0])["parent"], "parent")

    def test_memory_writing_agent_is_ignored(self):
        memories = str(self.home / ".codex/memories")
        with patch.dict(os.environ, {"CODEX_HOME": ""}):
            for event in ("session_start", "prompt_submit", "pre_tool_use", "stop"):
                payload = {"session_id": "memory-agent", "cwd": memories, "transcript_path": None,
                           "prompt": "## Memory Writing Agent: Phase 2 (Consolidation)"}
                self.assertIsNone(hook.record_event(payload, event, self.home))
            self.assertFalse((self.home / ".ghostty-extreme/codex-tracking/memory-agent.jsonl").exists())
            project = {"session_id": "project", "cwd": str(self.home / "project"), "prompt": "Fix the links"}
            self.assertIsNotNone(hook.record_event(project, "prompt_submit", self.home))

    def test_prompt_text_hides_paste_wrappers_and_names_visual_fixes(self):
        visual = '[Image #1]\n\n<pasted_content id="49c0">\nVisual fix #1: I pointed at an element.\nChange: Make it bigger\n</pasted_content id="49c0">\n'
        self.assertEqual(hook.prompt_text(visual), "Visual fix: Make it bigger")
        self.assertEqual(hook.prompt_text("Fix this [Image #2]").strip(), "Fix this")
        self.assertEqual(hook.prompt_text("Change: nothing special"), "Change: nothing special")

    def test_pretool_and_question_status(self):
        payload = {"session_id": "parent", "tool_name": "Bash", "tool_input": {"command": "cat src/app.ts"}}
        self.assertEqual(hook.record_event(payload, "pre_tool_use", self.home)["event"], "tool_start")
        payload["tool_name"] = "request_user_input"
        self.assertEqual(hook.record_event(payload, "pre_tool_use", self.home)["event"], "input_needed")

    def test_no_output_or_storage_outside_extreme(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(hook.sys, "stdin", io.StringIO('{"session_id":"parent"}')):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                hook.main()
            self.assertEqual(output.getvalue(), "")
            self.assertFalse((self.home / ".ghostty-extreme").exists())

    def test_no_path_traversal(self):
        self.assertIsNone(hook.record_event({"session_id": "../../escape"}, "session_start", self.home))
        self.assertFalse((self.home / ".ghostty-extreme").exists())

    def test_localhost_rewrite_preserves_permission_arguments(self):
        launcher = self.home / ".ghostty-extreme/bin/localhost"
        launcher.parent.mkdir(parents=True)
        launcher.touch()
        payload = {"session_id": "parent", "tool_name": "Bash", "cwd": "/tmp/a project",
                   "tool_input": {"command": "npm run dev", "sandbox_permissions": "require_escalated", "justification": "Start server"}}
        with patch.dict(os.environ, {"GHOSTTY_EXTREME_AGENT_EVENTS": "1"}), patch.object(hook.subprocess, "check_output", return_value="~/.ghostty-extreme/bin/localhost start -- 'npm run dev'\n"):
            result = hook.localhost_context(payload, "pre_tool_use", self.home)["hookSpecificOutput"]
        self.assertEqual(result["hookEventName"], "PreToolUse")
        self.assertEqual(result["permissionDecision"], "allow", "Codex takes a changed command only with it")
        self.assertEqual(result["updatedInput"]["sandbox_permissions"], "require_escalated")
        self.assertEqual(result["updatedInput"]["justification"], "Start server")
        self.assertIn("--agent codex", result["updatedInput"]["command"])
        self.assertIn("cd '/tmp/a project'", result["updatedInput"]["command"])
        self.assertIsNone(hook.localhost_context(payload, "permission_request", self.home))

    def test_a_dev_server_codex_starts_is_moved(self):
        launcher = self.home / ".ghostty-extreme/bin/localhost"
        launcher.parent.mkdir(parents=True)
        launcher.write_text("#!/bin/bash\necho \"~/.ghostty-extreme/bin/localhost start -- 'npm run dev'\"\n")
        launcher.chmod(0o755)
        payload = {"session_id": "parent", "tool_name": "Bash", "cwd": str(self.home), "tool_input": {"command": "npm run dev"}}
        self.assertEqual(json.loads(self.sent(payload, "pre_tool_use"))["event"], "tool_start")
        output = json.loads(self.printed)["hookSpecificOutput"]
        self.assertIn("localhost start --agent codex", output["updatedInput"]["command"])
        self.assertEqual(output["permissionDecision"], "allow")

    def test_non_server_is_not_rewritten(self):
        launcher = self.home / ".ghostty-extreme/bin/localhost"
        launcher.parent.mkdir(parents=True)
        launcher.touch()
        payload = {"tool_name": "Bash", "tool_input": {"command": "npm test"}}
        with patch.dict(os.environ, {"GHOSTTY_EXTREME_AGENT_EVENTS": "1"}), patch.object(hook.subprocess, "check_output", side_effect=hook.subprocess.CalledProcessError(1, "localhost")):
            self.assertIsNone(hook.localhost_context(payload, "pre_tool_use", self.home))

    def test_shell_wrapper_binds_pane_runtime_and_preserves_arguments(self):
        executable = self.home / "codex"
        executable.write_text('#!/bin/zsh\nprintf "%s\\n" "$GHOSTTY_EXTREME_CODEX_TTY" "$@"\n')
        executable.chmod(0o755)
        master, slave = os.openpty()
        environment = dict(os.environ, GHOSTTY_EXTREME_AGENT_EVENTS="1",
                           PATH=str(self.home) + ":" + os.environ.get("PATH", ""))
        try:
            result = subprocess.run(["/bin/zsh", "-f", "-c",
                'source "$1"; TTY=/dev/ttys123; codex resume saved-session --sandbox read-only "$2"',
                "zsh", str(Path(__file__).with_name("ghostty-extreme.zsh")), "a literal $prompt"],
                stdin=slave, stdout=slave, stderr=slave, env=environment, timeout=3)
            self.assertEqual(result.returncode, 0)
            arguments = os.read(master, 65536).decode().splitlines()
            self.assertEqual(arguments[:2], ["/dev/ttys123", "--no-daemon"])
            self.assertEqual(arguments[2:], ["resume", "saved-session", "--sandbox", "read-only", "a literal $prompt"])
        finally:
            os.close(master)
            os.close(slave)


class AgentEventFeedTests(unittest.TestCase):
    """agent-event.py, the hook for the other agents: its feed for the editor."""

    def run_hook(self, home, payload, **more):
        environment = {"PATH": os.environ.get("PATH", ""), "HOME": str(home), "TELLURION_TEST_HOME": str(home),
                       "GHOSTTY_EXTREME_AGENT_EVENTS": "1", "GHOSTTY_EXTREME_EVENT_TOKEN": "t", **more}
        return subprocess.run([sys.executable, "-B", str(Path(__file__).with_name("agent-event.py")), "gemini", "BeforeAgent"],
                              input=json.dumps(payload), capture_output=True, text=True, env=environment, timeout=10,
                              start_new_session=True)

    def test_the_feed_is_for_this_user_only_and_follows_the_test_home(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            old = os.umask(0o022)
            try:
                result = self.run_hook(home, {"session_id": "s1", "prompt": "a secret plan"})
                self.run_hook(home, {"session_id": "s1", "prompt": "and more"})
            finally:
                os.umask(old)
            self.assertEqual(result.stdout.strip(), "{}")
            feed = home / ".ghostty-extreme/feeds/gemini-s1.jsonl"
            self.assertEqual(len(feed.read_text().splitlines()), 2)
            self.assertEqual(stat.S_IMODE(feed.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(feed.parent.stat().st_mode), 0o700)

    def test_a_feed_made_readable_by_an_older_version_is_closed_again(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            feeds = home / ".ghostty-extreme/feeds"
            feeds.mkdir(parents=True)
            (feeds / "gemini-s1.jsonl").write_text("")
            (feeds / "gemini-s1.jsonl").chmod(0o644)
            self.run_hook(home, {"session_id": "s1", "prompt": "hello"})
            self.assertEqual(stat.S_IMODE((feeds / "gemini-s1.jsonl").stat().st_mode), 0o600)


if __name__ == "__main__":
    unittest.main()
