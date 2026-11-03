import contextlib
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import threading
import unittest
import unittest.mock

HERE = Path(__file__).parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


catalog = load("venice_catalog", "venice-catalog.py")
chat = load("local_chat", "local-chat.py")

PLAIN = {"slug": "plain", "priority": 13, "apply_patch_tool_type": "freeform", "base_instructions": "prompts",
         "context_window": 1, "upgrade": {"model": "x"}, "service_tiers": [{"id": "fast"}], "support_verbosity": True,
         "use_responses_lite": False}
BUNDLED = {"models": [dict(PLAIN, slug="code-mode", priority=1, tool_mode="code_mode_only"),
                      dict(PLAIN, slug="lite", priority=2, use_responses_lite=True),
                      dict(PLAIN, slug="no-patch", priority=3, apply_patch_tool_type=None), PLAIN]}


def row(model, uncensored=False, privacy="private", tools=True, e2ee=False, **capabilities):
    return {"id": model, "context_length": 5, "model_spec": {
        "name": model.upper(), "uncensored": uncensored, "privacy": privacy, "availableContextTokens": 1000000,
        "capabilities": dict(supportsFunctionCalling=tools, supportsE2EE=e2ee, **capabilities)}}


class CatalogTests(unittest.TestCase):
    def test_builds_from_a_plain_entry_whatever_its_name(self):
        self.assertEqual(catalog.base_entry(BUNDLED)["slug"], "plain")

    def test_no_plain_entry_is_an_error_not_a_bad_catalog(self):
        with self.assertRaises(ValueError):
            catalog.base_entry({"models": [dict(PLAIN, tool_mode="code_mode_only")]})

    def test_an_entry_gets_apply_patch_and_venices_limits(self):
        entry = catalog.venice_entry(PLAIN, row("m", supportsVision=True), 1)
        self.assertEqual(entry["slug"], "m")
        self.assertEqual(entry["apply_patch_tool_type"], "freeform")
        self.assertEqual(entry["context_window"], 1000000)
        self.assertEqual(entry["max_context_window"], 1000000)
        self.assertEqual(entry["effective_context_window_percent"], 90)
        self.assertEqual(entry["base_instructions"], "prompts")
        self.assertIsNone(entry["upgrade"])
        self.assertEqual(entry["service_tiers"], [])
        self.assertFalse(entry["support_verbosity"])
        self.assertEqual(entry["input_modalities"], ["text", "image"])
        self.assertEqual(catalog.venice_entry(PLAIN, row("m"), 1)["input_modalities"], ["text"])

    def test_reasoning_follows_venice(self):
        entry = catalog.venice_entry(PLAIN, row("m", supportsReasoning=True, reasoningEffortOptions=["low", "high", "made-up"],
                                                defaultReasoningEffort="high"), 1)
        self.assertEqual([level["effort"] for level in entry["supported_reasoning_levels"]], ["low", "high"])
        self.assertEqual(entry["default_reasoning_level"], "high")
        entry = catalog.venice_entry(PLAIN, row("m"), 1)
        self.assertEqual(entry["default_reasoning_level"], "medium")

    def test_only_models_codex_can_drive(self):
        self.assertTrue(catalog.usable(row("m")))
        self.assertFalse(catalog.usable(row("m", tools=False)))
        self.assertFalse(catalog.usable(row("m", e2ee=True)))
        self.assertFalse(catalog.usable(row("--bad")))
        self.assertFalse(catalog.usable(row("a b")))

    def test_the_default_is_uncensored_private_and_made_for_code(self):
        rows = [row("a"), row("b", uncensored=True, privacy="anonymized", optimizedForCode=True),
                row("c", uncensored=True), row("d", uncensored=True, optimizedForCode=True)]
        made, default = catalog.build(BUNDLED, rows)
        self.assertEqual(default, "d")
        self.assertEqual([entry["slug"] for entry in made["models"]], ["d", "c", "b", "a"])
        self.assertEqual([entry["priority"] for entry in made["models"]], [1, 2, 3, 4])

    def test_a_servers_text_cant_steer_a_terminal(self):
        made = row("m")
        made["model_spec"]["name"] = "Name\x1b]2;x\x07"
        self.assertEqual(catalog.venice_entry(PLAIN, made, 1)["display_name"], "Name]2;x")


class Models(http.server.BaseHTTPRequestHandler):
    seen = []

    def log_message(self, *args):
        pass

    def do_GET(self):
        Models.seen.append((self.path, self.headers.get("Authorization")))
        body = json.dumps({"data": [row("default-model", uncensored=True, optimizedForCode=True), row("other")]}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


FAKE_CODEX = """#!/bin/bash
if [ "$1" = --version ]; then echo "codex-cli 1.0"; exit 0; fi
if [ "$1" = debug ]; then
  if [ -n "${FAKE_DEBUG_FAILS:-}" ]; then exit 3; fi
  cat "$FAKE_BUNDLED"; exit 0
fi
{ printf '%s\\n' "$@" > "$FAKE_LOG.argv"; env > "$FAKE_LOG.env"; }
"""


class TellurionVeniceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        self.root = self.home / ".ghostty-extreme"
        self.root.mkdir()
        self.bin = self.home / "path"
        self.bin.mkdir()
        codex = self.bin / "codex"
        codex.write_text(FAKE_CODEX)
        codex.chmod(codex.stat().st_mode | stat.S_IEXEC)
        (self.home / "bundled.json").write_text(json.dumps(BUNDLED))
        self.log = self.home / "codex"
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Models)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.shutdown)
        self.addCleanup(self.server.server_close)
        self.token = "ABC-123"
        self.write_info()

    def write_info(self):
        (self.root / "venice-proxy.json").write_text(json.dumps({"port": self.server.server_address[1], "token": self.token}, separators=(",", ":")))

    def run_cli(self, *args, **env):
        environment = {"HOME": str(self.home), "PATH": f"{self.bin}:/usr/bin:/bin:/opt/homebrew/bin", "GHOSTTY_EXTREME_TEST_HOME": str(self.home),
                       "FAKE_LOG": str(self.log), "FAKE_BUNDLED": str(self.home / "bundled.json"), **env}
        return subprocess.run([str(HERE / "tellurion"), "venice", "codex", *args], env=environment, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=30)

    def argv(self):
        return Path(str(self.log) + ".argv").read_text().splitlines()

    def child_env(self):
        return dict(line.split("=", 1) for line in Path(str(self.log) + ".env").read_text().splitlines() if "=" in line)

    def test_sends_codex_to_the_proxy_for_this_run_only(self):
        result = self.run_cli("resume", "some-id", TELLURION_VENICE_MODEL="chosen-model")
        self.assertEqual(result.returncode, 0, result.stderr)
        argv = self.argv()
        joined = "\n".join(argv)
        self.assertIn('model_provider="venice"', argv)
        self.assertIn('analytics.enabled=false', argv)
        self.assertIn('features.apps=false', argv)
        self.assertIn(f'base_url="http://127.0.0.1:{self.server.server_address[1]}/api/v1"', joined)
        self.assertIn('env_key="TELLURION_VENICE_TOKEN"', joined)
        self.assertIn('wire_api="responses"', joined)
        self.assertEqual(argv[argv.index("-m") + 1], "chosen-model")
        self.assertEqual(argv[-2:], ["resume", "some-id"], "codex's own arguments stay last")
        self.assertNotIn(self.token, joined, "the token isn't on a command line")
        self.assertEqual(self.child_env()["TELLURION_VENICE_TOKEN"], self.token)
        self.assertIn('shell_environment_policy.set.TELLURION_VENICE_TOKEN=""', argv, "commands the agent runs don't get it")
        self.assertIn(f'model_catalog_json="{self.root}/venice/codex-catalog.json"', argv)
        self.assertFalse((self.home / ".codex").exists(), "Codex's own folder isn't touched")

    def test_memory_and_computer_use_are_off_by_default(self):
        self.run_cli(TELLURION_VENICE_MODEL="chosen-model")
        argv = self.argv()
        self.assertIn('features.memories=false', argv)
        self.assertIn('memories.generate_memories=false', argv)
        self.assertIn('features.computer_use=false', argv)
        for server in ('cua_repl', 'computer-use', 'node_repl'):
            self.assertIn(f'mcp_servers.{server}={{command="/usr/bin/false",enabled=false}}', argv)

    def test_memory_can_be_used_but_is_never_written_from_venice(self):
        (self.root / "venice").mkdir(exist_ok=True)
        (self.root / "venice" / "use-codex-memory").touch()
        self.run_cli(TELLURION_VENICE_MODEL="chosen-model")
        argv = self.argv()
        self.assertNotIn('features.memories=false', argv)
        self.assertIn('memories.generate_memories=false', argv)
        self.assertIn('features.computer_use=false', argv, "each switch is its own")

    def test_computer_use_can_be_allowed(self):
        (self.root / "venice").mkdir(exist_ok=True)
        (self.root / "venice" / "allow-computer-use").touch()
        self.run_cli(TELLURION_VENICE_MODEL="chosen-model")
        joined = "\n".join(self.argv())
        self.assertNotIn('computer_use', joined)
        self.assertNotIn('cua_repl', joined)
        self.assertIn('features.memories=false', joined, "each switch is its own")

    def test_secret_files_are_out_of_reach_by_default(self):
        self.run_cli(TELLURION_VENICE_MODEL="chosen-model")
        argv = self.argv()
        self.assertIn('default_permissions="tellurion-venice"', argv)
        self.assertIn('permissions.tellurion-venice.extends=":workspace"', argv)
        table = next(a for a in argv if a.startswith("permissions.tellurion-venice.filesystem="))
        for path in (".ssh", ".codex/auth.json", "**/.env", "**/*.pem"):
            self.assertIn(f'"{self.home}/{path}"="deny"', table)
        self.assertIn(f'"{self.root}/venice-proxy.json"="deny"', table)
        self.assertIn('":workspace_roots"={"**/.env"="deny"', table)
        self.assertNotIn(".env.example", table, "examples stay readable")

    def test_a_sandbox_flag_keeps_secret_files_out_of_reach(self):
        for flag in (["--sandbox", "workspace-write"], ["-s", "workspace-write"], ["--sandbox=workspace-write"], ["-sworkspace-write"]):
            result = self.run_cli(*flag, "exec", "hi", TELLURION_VENICE_MODEL="chosen-model")
            self.assertEqual(result.returncode, 0, result.stderr)
            argv = self.argv()
            self.assertIn('default_permissions="tellurion-venice"', argv, flag)
            self.assertIn('permissions.tellurion-venice.extends=":workspace"', argv, flag)
            self.assertFalse({"--sandbox", "-s", "--sandbox=workspace-write", "-sworkspace-write"} & set(argv), flag)
            self.assertEqual(argv[-2:], ["exec", "hi"])

    def test_read_only_stays_read_only(self):
        self.run_cli("exec", "--sandbox", "read-only", "hi", TELLURION_VENICE_MODEL="chosen-model")
        argv = self.argv()
        self.assertIn('permissions.tellurion-venice.extends=":read-only"', argv)
        self.assertEqual(argv[-2:], ["exec", "hi"])

    def test_what_would_remove_the_protection_is_refused(self):
        for flags in (["--sandbox", "danger-full-access"], ["-s", "danger-full-access"], ["--sandbox=danger-full-access"],
                      ["--dangerously-bypass-approvals-and-sandbox"], ["--yolo"], ["-c", 'default_permissions=":workspace"'],
                      ["-c", 'permissions.tellurion-venice.extends=":danger-full-access"'], ["--config=default_permissions=x"], ["--sandbox", "nonsense"]):
            Path(str(self.log) + ".argv").unlink(missing_ok=True)
            result = self.run_cli(*flags, TELLURION_VENICE_MODEL="chosen-model")
            self.assertNotEqual(result.returncode, 0, flags)
            self.assertIn("Let it read secret files", result.stderr, flags)
            self.assertFalse(Path(str(self.log) + ".argv").exists(), "Codex doesn't start")

    def test_the_same_words_in_a_prompt_are_not_refused(self):
        result = self.run_cli("exec", "permissions.py needs a fix", TELLURION_VENICE_MODEL="chosen-model")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.argv()[-1], "permissions.py needs a fix")
        result = self.run_cli("-c", "model_reasoning_effort=low", "exec", "hi", TELLURION_VENICE_MODEL="chosen-model")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.argv()[-4:], ["-c", "model_reasoning_effort=low", "exec", "hi"])

    def test_flags_are_codexs_own_once_secret_files_are_allowed(self):
        (self.root / "venice").mkdir(exist_ok=True)
        (self.root / "venice" / "allow-secret-files").touch()
        result = self.run_cli("--sandbox", "danger-full-access", TELLURION_VENICE_MODEL="chosen-model")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.argv()[-2:], ["--sandbox", "danger-full-access"])

    def test_everything_after_a_bare_separator_is_left_alone(self):
        self.run_cli("exec", "--", "--sandbox", "danger-full-access", TELLURION_VENICE_MODEL="chosen-model")
        self.assertEqual(self.argv()[-4:], ["exec", "--", "--sandbox", "danger-full-access"])

    def test_secret_files_can_be_allowed(self):
        (self.root / "venice").mkdir(exist_ok=True)
        (self.root / "venice" / "allow-secret-files").touch()
        self.run_cli(TELLURION_VENICE_MODEL="chosen-model")
        joined = "\n".join(self.argv())
        self.assertNotIn('default_permissions', joined)
        self.assertNotIn('tellurion-venice', joined)
        self.assertIn('features.memories=false', joined, "each switch is its own")

    def test_catalog_comes_from_the_live_list(self):
        Models.seen.clear()
        self.run_cli()
        self.assertEqual(Models.seen, [("/api/v1/models?type=text", "Bearer " + self.token)])
        written = json.loads((self.root / "venice/codex-catalog.json").read_text())
        self.assertEqual([entry["slug"] for entry in written["models"]], ["default-model", "other"])
        self.assertEqual(stat.S_IMODE((self.root / "venice/codex-catalog.json").stat().st_mode), 0o600)
        Models.seen.clear()
        self.run_cli()
        self.assertEqual(Models.seen, [], "kept while it's fresh and Codex is the same")

    def test_without_a_chosen_model_uses_the_default(self):
        self.run_cli()
        argv = self.argv()
        self.assertEqual(argv[argv.index("-m") + 1], "default-model")

    def test_a_model_on_the_command_line_wins(self):
        for arguments in (["-m", "mine"], ["--model", "mine"], ["--model=mine"], ["-mmine"]):
            self.assertEqual(self.run_cli(*arguments, TELLURION_VENICE_MODEL="other").returncode, 0)
            self.assertEqual(self.argv().count("other"), 0, arguments)
            self.assertEqual(self.argv()[-len(arguments):], arguments)

    def test_a_bad_model_name_stops_it(self):
        for name in ("--evil", "a b", "$(id)", "a;b"):
            result = self.run_cli(TELLURION_VENICE_MODEL=name)
            self.assertEqual(result.returncode, 1, name)
            self.assertIn("can't be right", result.stderr)
        self.assertFalse(Path(str(self.log) + ".argv").exists())

    def test_without_a_catalog_codex_still_runs_and_it_says_whats_lost(self):
        result = self.run_cli(TELLURION_VENICE_MODEL="m", FAKE_DEBUG_FAILS="1")
        self.assertEqual(result.returncode, 0)
        self.assertIn("apply_patch", result.stderr)
        self.assertFalse(any("model_catalog_json" in argument for argument in self.argv()))

    def test_never_falls_back_to_plain_codex_when_it_cant_reach_the_proxy(self):
        (self.root / "venice-proxy.json").unlink()
        result = self.run_cli(TELLURION_VENICE_MODEL="m")
        self.assertEqual(result.returncode, 1)
        self.assertIn("isn't connected", result.stderr)
        self.write_info()
        info = json.loads((self.root / "venice-proxy.json").read_text())
        info["port"] = 1
        (self.root / "venice-proxy.json").write_text(json.dumps(info, separators=(",", ":")))
        result = self.run_cli(TELLURION_VENICE_MODEL="m")
        self.assertEqual(result.returncode, 1)
        self.assertIn("isn't running", result.stderr)
        (self.root / "venice-proxy.json").write_text('{"port":"; rm -rf x","token":"$(id)"}')
        result = self.run_cli(TELLURION_VENICE_MODEL="m")
        self.assertEqual(result.returncode, 1)
        self.assertFalse(Path(str(self.log) + ".argv").exists())


@unittest.skipUnless(Path("/bin/zsh").exists(), "needs zsh")
class ZshWrapperTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        self.path = self.home / "path"
        self.path.mkdir()
        self.log = self.home / "log"
        fake = self.path / "codex"
        fake.write_text(f'#!/bin/bash\nprintf "plain %s\\n" "$*" >> "{self.log}"\n')
        fake.chmod(0o755)

    def install_cli(self):
        bin_folder = self.home / ".ghostty-extreme/bin"
        bin_folder.mkdir(parents=True)
        cli = bin_folder / "tellurion"
        cli.write_text(f'#!/bin/bash\nprintf "tellurion %s\\n" "$*" >> "{self.log}"\n')
        cli.chmod(0o755)

    def zsh(self, script, **env):
        environment = {"HOME": str(self.home), "PATH": f"{self.path}:/usr/bin:/bin", "GHOSTTY_EXTREME_TEST_HOME": str(self.home),
                       "GHOSTTY_EXTREME_AGENT_EVENTS": "1", "GHOSTTY_EXTREME_EVENT_TOKEN": "t", **env}
        return subprocess.run(["/bin/zsh", "-f", "-c", f'source "{HERE}/ghostty-extreme.zsh"; {script}'], env=environment,
                              capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=20)

    def logged(self):
        return self.log.read_text() if self.log.exists() else ""

    def test_a_pane_on_venice_goes_through_tellurion(self):
        self.install_cli()
        self.assertEqual(self.zsh("codex resume abc", TELLURION_CODEX_BACKEND="venice").returncode, 0)
        self.assertEqual(self.logged(), "tellurion venice codex resume abc\n")

    def test_any_other_pane_runs_plain_codex(self):
        self.install_cli()
        self.zsh("codex resume abc")
        self.assertTrue(self.logged().startswith("plain "))
        self.assertIn("resume abc", self.logged())

    def test_without_the_command_it_stops_instead_of_using_plain_codex(self):
        result = self.zsh("codex; print -r -- rc=$?", TELLURION_CODEX_BACKEND="venice")
        self.assertIn("rc=1", result.stdout)
        self.assertIn("Check Setup", result.stderr)
        self.assertEqual(self.logged(), "")

    def test_the_sidebar_sees_codex_when_started_through_tellurion(self):
        marked = self.zsh("""_gc_agent_preexec "" "" "'/some where/tellurion' venice codex resume x"; print -r -- agent=$_gc_running_agent""")
        self.assertIn("agent=codex", marked.stdout)
        for line in ("tellurion doctor", "tellurion venice", "tellurion local m"):
            other = self.zsh(f"""_gc_agent_preexec "" "" "{line}"; print -r -- agent=$_gc_running_agent""")
            self.assertIn("agent=\n", other.stdout, line)
        plain = self.zsh("""_gc_agent_preexec "" "" "FOO=1 codex"; print -r -- agent=$_gc_running_agent""")
        self.assertIn("agent=codex", plain.stdout)


class VeniceChatTests(unittest.TestCase):
    def setUp(self):
        self.addCleanup(setattr, chat, "PROVIDER", chat.PROVIDER)
        self.addCleanup(setattr, chat, "BASE", chat.BASE)
        self.addCleanup(chat.HEADERS.pop, "Authorization", None)
        chat.PROVIDER = "venice"

    def test_plain_words_by_status(self):
        self.assertIn("Out of Venice credits", chat.server_error({"error": "Insufficient balance"}, 402))
        self.assertIn("turned down the key", chat.server_error({"error": "x"}, 401))
        self.assertIn("doesn't have this model", chat.server_error({"error": "x"}, 404))
        self.assertIn("limiting", chat.server_error({"error": "x"}, 429))
        self.assertEqual(chat.server_error({"error": "plain"}, 500), "plain")
        self.assertIn("isn't connected", chat.server_error({"error": {"code": "proxy_token", "message": "m"}}, 401))

    def test_a_stream_error_says_how_long_to_wait(self):
        text = chat.server_error({"error": {"message": "overloaded\x1b]2;x\x07", "retry_after": 7}})
        self.assertEqual(text, "overloaded]2;x Try again in 7 seconds.")
        self.assertEqual(chat.server_error({"error": "overloaded", "retry_after": 3}), "overloaded Try again in 3 seconds.")
        self.assertEqual(chat.server_error({"error": "overloaded", "retry_after": True}), "overloaded")

    def test_the_token_is_read_from_the_proxys_file(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / ".ghostty-extreme"
            root.mkdir()
            (root / "venice-proxy.json").write_text('{"port":4242,"token":"tok"}')
            with unittest.mock.patch.dict(os.environ, {"GHOSTTY_EXTREME_TEST_HOME": folder}):
                chat.configure("venice", None)
        self.assertEqual(chat.BASE, "http://127.0.0.1:4242/api")
        self.assertEqual(chat.HEADERS["Authorization"], "Bearer tok")

    def test_answers_cant_steer_the_terminal(self):
        lines = [b'data: {"choices":[{"delta":{"content":"hi \\u001b]52;c;QQ==\\u0007there"}}]}\n',
                 b'data: {"choices":[],"usage":{"total_tokens":3}}\n', b"data: [DONE]\n"]

        class Reply(io.BytesIO):
            pass

        out = io.StringIO()
        with unittest.mock.patch.object(chat, "post", lambda *a, **k: contextlib.nullcontext(iter(lines))), contextlib.redirect_stdout(out):
            answer = chat.reply_openai("m", [], False)
        self.assertEqual(answer, "hi ]52;c;QQ==there")
        self.assertNotIn("\x1b]52", out.getvalue())


if __name__ == "__main__":
    unittest.main()
