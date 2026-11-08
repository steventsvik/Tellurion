"""Codex on a model on this Mac: `tellurion local codex`, local-catalog.py and the zsh wrapper."""
import http.server
import importlib.util
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import tempfile
import threading
import unittest

HERE = Path(__file__).parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


catalog = load("local_catalog", "local-catalog.py")
venice = load("venice_catalog", "venice-catalog.py")

PLAIN = {"slug": "plain", "priority": 13, "apply_patch_tool_type": "freeform", "base_instructions": "prompts",
         "context_window": 1, "upgrade": {"model": "x"}, "service_tiers": [{"id": "fast"}], "support_verbosity": True,
         "use_responses_lite": False}
BUNDLED = {"models": [dict(PLAIN, slug="code-mode", priority=1, tool_mode="code_mode_only"), PLAIN]}

FAKE_CODEX = """#!/bin/bash
if [ "$1" = --version ]; then echo "codex-cli 1.0"; exit 0; fi
if [ "$1" = debug ]; then
  if [ -n "${FAKE_DEBUG_FAILS:-}" ]; then exit 3; fi
  cat "$FAKE_BUNDLED"; exit 0
fi
{ printf '%s\\n' "$@" > "$FAKE_LOG.argv"; env > "$FAKE_LOG.env"; }
"""


def model(name, tools=True, context=262144, loaded=False, vision=False, served=None):
    return {"name": name, "tools": tools, "context": context, "loaded": loaded, "vision": vision, "served": served}


class ChoosingTests(unittest.TestCase):
    models = [model("alpha:7b"), model("tiny:1b", tools=False), model("zeta:27b", loaded=True)]

    def test_the_model_asked_for(self):
        self.assertEqual(catalog.choose(self.models, "alpha:7b", "ollama")["name"], "alpha:7b")

    def test_a_name_without_a_tag_means_latest(self):
        models = self.models + [model("plain:latest")]
        self.assertEqual(catalog.choose(models, "plain", "ollama")["name"], "plain:latest")
        with self.assertRaisesRegex(ValueError, "no model named alpha"):
            catalog.choose(models, "alpha", "ollama")

    def test_a_model_that_cant_call_tools_is_refused_and_the_others_named(self):
        with self.assertRaisesRegex(ValueError, "tiny:1b can't call tools.*alpha:7b, zeta:27b"):
            catalog.choose(self.models, "tiny:1b", "ollama")

    def test_an_unknown_model_is_refused_and_the_models_here_named(self):
        with self.assertRaisesRegex(ValueError, "Ollama has no model named nope:1b. It has: alpha:7b, tiny:1b, zeta:27b"):
            catalog.choose(self.models, "nope:1b", "ollama")

    def test_without_a_choice_a_loaded_model_comes_first_then_by_name(self):
        self.assertEqual(catalog.choose(self.models, "", "ollama")["name"], "zeta:27b")
        self.assertEqual(catalog.choose(self.models[:2], "", "ollama")["name"], "alpha:7b")

    def test_lm_studio_models_arent_known_to_lack_tools(self):
        self.assertEqual(catalog.choose([model("m", tools=None)], "", "lmstudio")["name"], "m")

    def test_nothing_that_can_call_tools_says_what_to_do(self):
        with self.assertRaisesRegex(ValueError, "None of the models in Ollama can call tools.*Local models"):
            catalog.choose([model("tiny:1b", tools=False)], "", "ollama")


class BuildingTests(unittest.TestCase):
    def test_the_chosen_model_comes_first_and_the_served_context_caps_the_rest(self):
        models = [model("alpha:7b"), model("tiny:1b", tools=False), model("zeta:27b", context=8192), model("vis:2b", vision=True)]
        made = catalog.build(venice, BUNDLED, models, models[2], 32768, "ollama")
        self.assertEqual([m["slug"] for m in made["models"]], ["zeta:27b", "alpha:7b", "vis:2b"])
        self.assertEqual([m["context_window"] for m in made["models"]], [32768, 32768, 32768])
        self.assertEqual([m["priority"] for m in made["models"]], [1, 2, 3])
        self.assertEqual(made["models"][2]["input_modalities"], ["text", "image"])
        self.assertEqual(made["models"][0]["input_modalities"], ["text"])

    def test_an_entry_has_codexs_tools_and_a_level_for_the_format(self):
        made = catalog.build(venice, BUNDLED, [model("alpha:7b")], model("alpha:7b"), 32768, "ollama")
        entry = made["models"][0]
        self.assertEqual(entry["apply_patch_tool_type"], "freeform")
        self.assertEqual(entry["base_instructions"], "prompts")
        self.assertEqual(entry["description"], "On this Mac, in Ollama")
        self.assertEqual(entry["default_reasoning_level"], "medium")
        self.assertEqual([level["effort"] for level in entry["supported_reasoning_levels"]], ["medium"])
        self.assertNotIn("tool_mode", entry)
        self.assertIsNone(entry["upgrade"])

    def test_lm_studio_contexts_are_each_models_own(self):
        models = [model("a", tools=None, context=4096, served=4096), model("b", tools=None, context=131072)]
        made = catalog.build(venice, BUNDLED, models, models[0], 4096, "lmstudio")
        self.assertEqual([m["context_window"] for m in made["models"]], [4096, 131072])
        self.assertEqual(made["models"][0]["description"], "On this Mac, in LM Studio")


class Server(http.server.BaseHTTPRequestHandler):
    """Ollama's API, and LM Studio's model list, for the models in `models`."""
    models = {}
    loaded = set()
    served = 32768
    seen = []

    def log_message(self, *args):
        pass

    def reply(self, body, status=200):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        Server.seen.append(("GET", self.path))
        if self.path == "/api/tags":
            self.reply({"models": [{"name": name} for name in self.models]})
        elif self.path == "/api/ps":
            self.reply({"models": [{"name": name, "model": name, "context_length": self.served} for name in self.loaded]})
        elif self.path == "/api/v0/models":
            rows = []
            for name, spec in self.models.items():
                row = {"id": name, "type": "vlm" if spec.get("vision") else "llm", "max_context_length": spec["context"],
                       "state": "loaded" if name in self.loaded else "not-loaded"}
                if name in self.loaded:
                    row["loaded_context_length"] = self.served
                rows.append(row)
            rows.append({"id": "embed", "type": "embeddings"})
            self.reply({"data": rows})
        else:
            self.reply({"error": "not found"}, 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        name = body.get("model")
        Server.seen.append(("POST", self.path, name))
        spec = self.models.get(name)
        if spec is None:
            self.reply({"error": f"model '{name}' not found"}, 404)
        elif self.path == "/api/show":
            capabilities = ["completion"] + (["tools"] if spec["tools"] else []) + (["vision"] if spec.get("vision") else [])
            self.reply({"capabilities": capabilities, "model_info": {"general.architecture": "x", "x.context_length": spec["context"]}})
        elif self.path == "/api/generate":
            Server.loaded.add(name)
            self.reply({"model": name, "response": "", "done": True, "done_reason": "load"})
        else:
            self.reply({"error": "not found"}, 404)


def closed_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class TellurionLocalCodexTests(unittest.TestCase):
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
        Server.models = {"alpha:7b": {"tools": True, "context": 262144}, "tiny:1b": {"tools": False, "context": 32768},
                         "zeta:27b": {"tools": True, "context": 131072}, "plain:latest": {"tools": True, "context": 8192}}
        Server.loaded = {"zeta:27b"}
        Server.served = 32768
        Server.seen = []
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Server)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.shutdown)
        self.addCleanup(self.server.server_close)
        self.address = "127.0.0.1:%d" % self.server.server_address[1]

    def run_cli(self, *args, **env):
        environment = {"HOME": str(self.home), "PATH": f"{self.bin}:/usr/bin:/bin:/opt/homebrew/bin", "TELLURION_TEST_HOME": str(self.home),
                       "OLLAMA_HOST": self.address, "FAKE_LOG": str(self.log), "FAKE_BUNDLED": str(self.home / "bundled.json"), **env}
        return subprocess.run([str(HERE / "tellurion"), "local", "codex", *args], env=environment, capture_output=True, text=True,
                              stdin=subprocess.DEVNULL, timeout=30)

    def argv(self):
        return Path(str(self.log) + ".argv").read_text().splitlines()

    def codex_ran(self):
        return Path(str(self.log) + ".argv").exists()

    def setting(self, argv, key):
        values = [argv[i + 1] for i, a in enumerate(argv[:-1]) if a == "-c" and argv[i + 1].startswith(key + "=")]
        self.assertEqual(len(values), 1, (key, argv))
        return values[0][len(key) + 1:]

    def test_codex_runs_on_ollama_for_this_run_only(self):
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        argv = self.argv()
        self.assertEqual(self.setting(argv, "model_provider"), '"ollama"')
        self.assertIn("--oss", argv)
        self.assertEqual(argv[argv.index("--local-provider") + 1], "ollama")
        self.assertEqual(argv[argv.index("-m") + 1], "zeta:27b", "the loaded model that can call tools")
        self.assertEqual(self.setting(argv, "model_catalog_json"), f'"{self.root}/local/codex-catalog.json"')
        self.assertEqual(self.setting(argv, "features.apps"), "false")
        self.assertEqual(self.setting(argv, "analytics.enabled"), "false")
        self.assertEqual(self.setting(argv, "memories.generate_memories"), "false")
        self.assertFalse(any("model_providers" in a for a in argv), "Codex's own ollama provider, not a new one")
        self.assertFalse(any("features.memories" in a for a in argv), "memory can still be read: it stays on this Mac")
        self.assertFalse(any("default_permissions" in a or "permissions." in a for a in argv), "no secret-file rules: nothing leaves this Mac")
        self.assertEqual(result.stderr, "")

    def test_the_model_is_loaded_first_and_the_catalog_knows_its_served_context(self):
        Server.loaded = set()
        self.run_cli()
        self.assertIn(("POST", "/api/generate", "alpha:7b"), Server.seen)
        written = json.loads((self.root / "local/codex-catalog.json").read_text())
        self.assertEqual([entry["slug"] for entry in written["models"]], ["alpha:7b", "plain:latest", "zeta:27b"], "no tiny:1b: it can't call tools")
        self.assertEqual([entry["context_window"] for entry in written["models"]], [32768, 8192, 32768])
        self.assertEqual(stat.S_IMODE((self.root / "local/codex-catalog.json").stat().st_mode), 0o600)
        self.assertEqual((self.root / "local/default-model").read_text(), "alpha:7b\n")

    def test_a_model_on_the_command_line_wins_and_is_passed_once(self):
        result = self.run_cli("-m", "alpha:7b")
        self.assertEqual(result.returncode, 0, result.stderr)
        argv = self.argv()
        self.assertEqual(argv.count("-m"), 1)
        self.assertEqual(argv[argv.index("-m") + 1], "alpha:7b")
        self.assertEqual((self.root / "local/default-model").read_text(), "alpha:7b\n")
        self.run_cli("--model=plain")
        argv = self.argv()
        self.assertIn("--model=plain", argv)
        self.assertEqual((self.root / "local/default-model").read_text(), "plain:latest\n")

    def test_the_pane_can_name_the_model(self):
        self.run_cli(TELLURION_LOCAL_MODEL="alpha:7b")
        argv = self.argv()
        self.assertEqual(argv[argv.index("-m") + 1], "alpha:7b")

    def test_a_model_that_cant_call_tools_is_refused(self):
        result = self.run_cli("-m", "tiny:1b")
        self.assertEqual(result.returncode, 1)
        self.assertIn("tiny:1b can't call tools, which Codex needs. Models here that can: alpha:7b, plain:latest, zeta:27b", result.stderr)
        self.assertFalse(self.codex_ran())

    def test_a_model_that_isnt_here_is_refused(self):
        result = self.run_cli("-m", "nope:3b")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Ollama has no model named nope:3b.", result.stderr)
        self.assertFalse(self.codex_ran())

    def test_a_bad_model_name_stops_it(self):
        for name in ("x;rm -rf", "-m", 'a"b'):
            result = self.run_cli("-m", name)
            self.assertEqual(result.returncode, 1, name)
            self.assertIn("can't be right", result.stderr)
        self.assertFalse(self.codex_ran())
        self.assertEqual(Server.seen, [], "nothing was asked of Ollama")

    def test_when_ollama_isnt_running_it_stops_instead_of_using_another_provider(self):
        result = self.run_cli(OLLAMA_HOST="127.0.0.1:%d" % closed_port())
        self.assertEqual(result.returncode, 1)
        self.assertIn("Ollama isn't running", result.stderr)
        self.assertIn("Local models", result.stderr)
        self.assertFalse(self.codex_ran())

    def test_an_unknown_provider_is_refused(self):
        result = self.run_cli("--provider", "venice")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Ollama or LM Studio", result.stderr)
        self.assertFalse(self.codex_ran())

    def test_lm_studio(self):
        result = self.run_cli("--provider", "lmstudio", "--base", "http://" + self.address)
        self.assertEqual(result.returncode, 0, result.stderr)
        argv = self.argv()
        self.assertEqual(self.setting(argv, "model_provider"), '"lmstudio"')
        self.assertEqual(argv[argv.index("--local-provider") + 1], "lmstudio")
        self.assertEqual(argv[argv.index("-m") + 1], "zeta:27b")
        self.assertNotIn("--provider", argv)
        self.assertNotIn("--base", argv)
        written = json.loads((self.root / "local/codex-catalog.json").read_text())
        self.assertEqual([entry["slug"] for entry in written["models"]], ["zeta:27b", "alpha:7b", "plain:latest", "tiny:1b"],
                         "LM Studio doesn't say which can call tools, so all are offered, and no embedding models")
        self.assertEqual(written["models"][0]["context_window"], 32768)
        self.assertEqual(written["models"][1]["context_window"], 262144)
        self.assertNotIn(("POST", "/api/generate", "zeta:27b"), Server.seen)

    def test_base_needs_a_web_address(self):
        result = self.run_cli("--provider", "lmstudio", "--base", "ls -la")
        self.assertEqual(result.returncode, 1)
        self.assertIn("web address", result.stderr)
        self.assertFalse(self.codex_ran())

    def test_a_small_context_is_pointed_out_and_codex_still_runs(self):
        Server.served = 4096
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Ollama serves zeta:27b with 4096 tokens of context", result.stderr)
        self.assertIn("Ollama's settings", result.stderr)
        self.assertTrue(self.codex_ran())

    def test_web_search_is_off_by_default(self):
        self.run_cli()
        self.assertFalse(any("tellurion_search" in a for a in self.argv()))

    def test_web_search_can_be_turned_on_and_shares_venices_searxng(self):
        (self.root / "local").mkdir()
        (self.root / "local/use-web-search").touch()
        self.run_cli()
        argv = self.argv()
        search = self.setting(argv, "mcp_servers.tellurion_search")
        self.assertIn("venice-search.py", search)
        self.assertIn(f'"--folder","{self.root}/venice"', search)
        self.assertIn('"-I"', search)

    def test_without_a_catalog_codex_still_runs_and_it_says_whats_lost(self):
        result = self.run_cli(FAKE_DEBUG_FAILS="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("without its details", result.stderr)
        argv = self.argv()
        self.assertFalse(any("model_catalog_json" in a for a in argv))
        self.assertEqual(argv[argv.index("-m") + 1], "zeta:27b")

    def test_everything_after_a_bare_separator_is_left_alone(self):
        result = self.run_cli("--", "--provider", "lmstudio")
        self.assertEqual(result.returncode, 0, result.stderr)
        argv = self.argv()
        self.assertEqual(argv[-3:], ["--", "--provider", "lmstudio"])
        self.assertEqual(argv[argv.index("--local-provider") + 1], "ollama")

    def test_codexs_own_arguments_pass_through(self):
        self.run_cli("resume", "abc", "-s", "read-only")
        argv = self.argv()
        self.assertEqual(argv[-4:], ["resume", "abc", "-s", "read-only"])

    def test_without_python_it_says_so(self):
        result = self.run_cli(PATH=f"{self.bin}:/nonexistent")
        self.assertEqual(result.returncode, 1)
        self.assertIn("python3", result.stderr)
        self.assertFalse(self.codex_ran())


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
        environment = {"HOME": str(self.home), "PATH": f"{self.path}:/usr/bin:/bin", "TELLURION_TEST_HOME": str(self.home),
                       "GHOSTTY_EXTREME_AGENT_EVENTS": "1", "GHOSTTY_EXTREME_EVENT_TOKEN": "t", **env}
        return subprocess.run(["/bin/zsh", "-f", "-c", f'source "{HERE}/ghostty-extreme.zsh"; {script}'], env=environment,
                              capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=20)

    def logged(self):
        return self.log.read_text() if self.log.exists() else ""

    def test_a_pane_on_a_local_model_goes_through_tellurion(self):
        self.install_cli()
        self.assertEqual(self.zsh("codex resume abc", TELLURION_CODEX_BACKEND="local").returncode, 0)
        self.assertEqual(self.logged(), "tellurion local codex resume abc\n")

    def test_without_the_command_it_stops_instead_of_using_plain_codex(self):
        result = self.zsh("codex; print -r -- rc=$?", TELLURION_CODEX_BACKEND="local")
        self.assertIn("rc=1", result.stdout)
        self.assertIn("on this Mac", result.stderr)
        self.assertEqual(self.logged(), "")

    def test_an_unknown_backend_is_not_a_local_one(self):
        self.install_cli()
        self.zsh("codex", TELLURION_CODEX_BACKEND="other")
        self.assertTrue(self.logged().startswith("plain "))

    def test_the_sidebar_sees_codex_when_started_locally(self):
        marked = self.zsh("""_gc_agent_preexec "" "" "'/some where/tellurion' local codex -m qwen3:4b"; print -r -- agent=$_gc_running_agent""")
        self.assertIn("agent=codex", marked.stdout)
        other = self.zsh("""_gc_agent_preexec "" "" "tellurion local qwen3:4b"; print -r -- agent=$_gc_running_agent""")
        self.assertIn("agent=\n", other.stdout, "a chat reports itself")


if __name__ == "__main__":
    unittest.main()
