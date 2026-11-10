#!/usr/bin/env python3
"""`localhost rewrite`, which decides what an agent's command becomes, and how `localhost start`
tells that a session is still serving."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "localhost"
START = "~/.ghostty-extreme/bin/localhost start "


class Folders(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        # Resolved: on a Mac the temporary folder is reached through a symlink.
        self.home = Path(temporary.name).resolve()
        self.project = self.home / "project"
        (self.project / "web").mkdir(parents=True)
        self.outside = self.home / "outside"
        self.outside.mkdir()
        # The script finds a terminal to talk to through its parents (`ps`). Here it finds
        # none, so no test can write an event into the terminal the tests are run from.
        self.tools = self.home / "tools"
        self.tools.mkdir()
        (self.tools / "ps").write_text("#!/bin/sh\nexit 1\n")
        (self.tools / "ps").chmod(0o755)

    def run_script(self, *arguments, cwd=None):
        environment = {"HOME": str(self.home), "TELLURION_TEST_HOME": str(self.home),
                       "PATH": f"{self.tools}:{os.environ.get('PATH', '')}"}
        return subprocess.run(["/bin/bash", str(SCRIPT), *arguments], capture_output=True, text=True, env=environment,
                              cwd=str(cwd or self.project), stdin=subprocess.DEVNULL, timeout=20, start_new_session=True)


class RewriteTests(Folders):
    def rewrite(self, command, *more):
        result = self.run_script("rewrite", command, "--cwd", str(self.project), *more)
        self.assertIn(result.returncode, (0, 1), result.stderr)
        self.assertEqual(result.returncode == 0, bool(result.stdout), (command, result.stdout))
        return result.stdout.rstrip("\n") or None

    def assertLeftAlone(self, command, *more):
        self.assertIsNone(self.rewrite(command, *more), command)

    def test_a_dev_server_becomes_a_session(self):
        self.assertEqual(self.rewrite("npm run dev"), START + "-- 'npm run dev'")
        self.assertEqual(self.rewrite("PORT=3000 pnpm dev"), START + "-- 'PORT=3000 pnpm dev'")
        self.assertEqual(self.rewrite("uvicorn app:app --reload"), START + "-- 'uvicorn app:app --reload'")
        self.assertEqual(self.rewrite("nohup npx vite &"), START + "-- 'npx vite'")

    def test_other_commands_are_left_alone(self):
        for command in ("npm test", "ls", "npm run build", "npm run dev | tee log", "npm run dev; rm -rf x",
                        "npm run dev && echo done", "echo $(npm run dev)", "npm run dev\nrm -rf x", "vite `id`"):
            self.assertLeftAlone(command)

    # --- where the output went ---

    def test_output_sent_to_a_file_becomes_the_log(self):
        self.assertEqual(self.rewrite("npm run dev > dev.log 2>&1 &"), START + "--log 'dev.log' -- 'npm run dev'")
        self.assertEqual(self.rewrite("npm run dev >> dev.log"), START + "--log 'dev.log' -- 'npm run dev'")
        self.assertEqual(self.rewrite("npm run dev>dev.log"), START + "--log 'dev.log' -- 'npm run dev'")
        self.assertEqual(self.rewrite("npm run dev &> dev.log"), START + "--log 'dev.log' -- 'npm run dev'")
        self.assertEqual(self.rewrite("npm run dev 1>dev.log"), START + "--log 'dev.log' -- 'npm run dev'")

    def test_a_stream_number_isnt_an_argument(self):
        # Was: --log 'err.log' -- 'npm run dev 2'
        self.assertEqual(self.rewrite("npm run dev 2>err.log"), START + "--log 'err.log' -- 'npm run dev'")
        self.assertEqual(self.rewrite("npm run dev 2> err.log &"), START + "--log 'err.log' -- 'npm run dev'")
        self.assertEqual(self.rewrite("npm run dev > out.log 2> err.log"), START + "--log 'out.log' -- 'npm run dev'")
        self.assertEqual(self.rewrite("npm run dev 2> err.log > out.log"), START + "--log 'out.log' -- 'npm run dev'")

    def test_a_number_that_is_an_argument_stays_one(self):
        self.assertEqual(self.rewrite("serve -l 2 > out.log"), START + "--log 'out.log' -- 'serve -l 2'")
        self.assertEqual(self.rewrite("npm run dev:2>out.log"), START + "--log 'out.log' -- 'npm run dev:2'")

    def test_dev_null_is_not_a_log(self):
        # Was: --log '/dev/null'
        for command in ("npm run dev > /dev/null 2>&1", "npm run dev >/dev/null 2>&1 &", "npm run dev 2>/dev/null",
                        "npm run dev &>/dev/null", "npm run dev 2>&1", "npm run dev > /dev/null 2> /dev/null"):
            self.assertEqual(self.rewrite(command), START + "-- 'npm run dev'", command)
        self.assertEqual(self.rewrite("npm run dev > /dev/null 2> err.log"), START + "--log 'err.log' -- 'npm run dev'")
        self.assertEqual(self.rewrite("npm run dev > out.log 2> /dev/null"), START + "--log 'out.log' -- 'npm run dev'")

    def test_a_log_name_the_shell_would_have_to_work_out_is_left_alone(self):
        for command in ("npm run dev > $LOG", 'npm run dev > "dev.log"', "npm run dev > 'dev.log'", "npm run dev > log*.txt",
                        "npm run dev 3> x.log", "npm run dev < input", "npm run dev > a.log > b$(id).log"):
            self.assertLeftAlone(command)
        self.assertEqual(self.rewrite("npm run dev > ~/dev.log"), START + f"--log '{self.home}/dev.log' -- 'npm run dev'")

    # --- what counts as a server ---

    def test_a_script_isnt_a_server_for_its_name(self):
        # Was: all of these became sessions when run in the background.
        for command in ("./x.sh web &", "./run-server.sh &", "scripts/gcp.sh bot-dashboard &", "bash dev.sh &",
                        "sh ./serve.sh &", "./x.sh web > out.log 2>&1 &"):
            self.assertLeftAlone(command)
            self.assertLeftAlone(command.rstrip("& "), "--background")

    def test_a_task_runners_server_target_still_counts_in_the_background(self):
        self.assertEqual(self.rewrite("make dev &"), START + "-- 'make dev'")
        self.assertEqual(self.rewrite("just serve", "--background"), START + "-- 'just serve'")
        self.assertEqual(self.rewrite("mise run web-preview &"), START + "-- 'mise run web-preview'")
        self.assertLeftAlone("make dev")
        self.assertLeftAlone("make build &")
        for command in ("make -f /tmp/evil.mk dev &", "make -C /tmp dev &", "make dev SHELL=./x.sh &", "just --justfile /tmp/j dev &"):
            self.assertLeftAlone(command)

    def test_a_command_run_in_a_session_here_before_counts(self):
        sessions = self.home / ".ghostty-extreme/localhost"
        sessions.mkdir(parents=True)
        (sessions / "lh-1.json").write_text(json.dumps({"id": "lh-1", "cwd": str(self.project), "command": "./x.sh web"}))
        if shutil.which("jq"):
            self.assertEqual(self.rewrite("./x.sh web &"), START + "-- './x.sh web'")
        self.assertLeftAlone("./x.sh other &")

    def test_a_tunnel_that_only_forwards_a_port_counts(self):
        for command in ("ssh -L 8080:localhost:80 host", "ssh -N -L 8080:localhost:80 user@host", "ssh -NL 8080:localhost:80 host",
                        "ssh -p 2222 -i key -L 8080:localhost:80 host", "kubectl port-forward svc/web 8080:80",
                        "gcloud compute ssh vm --zone us-east1-b -- -L 8080:localhost:80", "ngrok http 3000"):
            self.assertEqual(self.rewrite(command), START + f"-- '{command}'", command)

    def test_ssh_that_can_run_a_program_here_is_left_alone(self):
        for command in ("ssh -o ProxyCommand=./p.sh -L 8080:localhost:80 host",
                        "ssh -oProxyCommand=./p.sh -L 8080:localhost:80 host",
                        "ssh -L 8080:localhost:80 -o proxycommand=./p.sh host",
                        "ssh -o StrictHostKeyChecking=no -L 8080:localhost:80 host",
                        "ssh -No PermitLocalCommand=yes -L 8080:localhost:80 host",
                        "ssh -J jump.example -L 8080:localhost:80 host",
                        "ssh -F ./ssh.conf -L 8080:localhost:80 host",
                        "ssh -NF ./ssh.conf -L 8080:localhost:80 host",
                        "autossh -M 0 -o ProxyJump=x -L 8080:localhost:80 host",
                        "gcloud compute ssh vm -- -o ProxyCommand=./p.sh -L 8080:localhost:80",
                        "gcloud compute ssh vm --ssh-flag=-oProxyCommand=./p.sh -- -L 8080:localhost:80",
                        "kubectl --kubeconfig ./k.yaml port-forward svc/web 8080:80"):
            self.assertLeftAlone(command)
            self.assertLeftAlone(command + " &")

    # --- a cd in front ---

    def test_a_cd_into_the_project_is_kept(self):
        self.assertEqual(self.rewrite("cd web && npm run dev"), "cd web && " + START + "-- 'npm run dev'")
        self.assertEqual(self.rewrite("cd ./web && npm run dev &"), "cd ./web && " + START + "-- 'npm run dev'")
        self.assertEqual(self.rewrite(f"cd {self.project}/web && npm run dev"), f"cd {self.project}/web && " + START + "-- 'npm run dev'")
        self.assertEqual(self.rewrite("cd . && npm run dev"), "cd . && " + START + "-- 'npm run dev'")
        self.assertEqual(self.rewrite("cd web/.. && npm run dev"), "cd web/.. && " + START + "-- 'npm run dev'")

    def test_a_cd_out_of_the_project_is_left_alone(self):
        # Was: cd /tmp && localhost start -- 'uvicorn evil:app'
        os.symlink(self.outside, self.project / "link")
        for command in ("cd /tmp && uvicorn evil:app", f"cd {self.outside} && npm run dev", "cd .. && npm run dev",
                        "cd ../outside && npm run dev", "cd web/../../outside && npm run dev", "cd ~ && npm run dev",
                        "cd ~/outside && npm run dev", "cd link && npm run dev", "cd / && npm run dev",
                        "cd missing && npm run dev", f"cd {self.project}-other && npm run dev"):
            self.assertLeftAlone(command)
        (self.home / "project-other").mkdir()
        self.assertLeftAlone(f"cd {self.project}-other && npm run dev")

    def test_without_a_known_folder_a_cd_is_judged_from_where_it_runs(self):
        result = self.run_script("rewrite", "cd web && npm run dev")
        self.assertEqual(result.stdout.strip(), "cd web && " + START + "-- 'npm run dev'")
        self.assertEqual(self.run_script("rewrite", "cd .. && npm run dev").stdout, "")
        self.assertEqual(self.run_script("rewrite", "cd web && npm run dev", "--cwd", str(self.home / "gone")).stdout, "")


@unittest.skipUnless(shutil.which("jq") and shutil.which("lsof"), "localhost start needs jq and lsof")
class ListeningTests(Folders):
    """A second `start` for a session that's serving points at it; it must not restart it."""

    def setUp(self):
        super().setUp()
        self.sessions = self.home / ".ghostty-extreme/localhost"
        self.sessions.mkdir(parents=True)
        self.listener = socket.socket()
        self.addCleanup(self.listener.close)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.port = self.listener.getsockname()[1]
        (self.sessions / "lh-1.json").write_text(json.dumps({"id": "lh-1", "cwd": str(self.project), "command": "npm run dev"}))

    def start_again(self, **status):
        path = self.sessions / "lh-1.status.json"
        path.write_text(json.dumps({"id": "lh-1", "state": "live", **status}))
        result = self.run_script("start", "--", "npm run dev")
        return result, json.loads(path.read_text())

    def assertStillServing(self, **status):
        result, after = self.start_again(**status)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Already running", result.stdout, status)
        self.assertEqual(after["state"], "live", "not asked to restart")

    def test_the_status_files_port_is_used(self):
        self.assertStillServing(url=f"http://localhost:{self.port}/app/", port=self.port)
        self.assertStillServing(url="http://localhost/", port=self.port)

    def test_an_address_with_a_path_still_gives_its_port(self):
        # Was: the "port" came out as "5173/app/", nothing listened there, and the server was restarted.
        for url in (f"http://localhost:{self.port}", f"http://localhost:{self.port}/", f"http://localhost:{self.port}/app/",
                    f"http://127.0.0.1:{self.port}/a/b?c=d:e", f"http://localhost:{self.port}?x=1", f"http://localhost:{self.port}#top"):
            self.assertStillServing(url=url)
        self.assertStillServing(url=f"http://localhost:{self.port}/app/", port="not a number")

    def test_a_session_nothing_listens_for_isnt_called_running(self):
        free = socket.socket()
        free.bind(("127.0.0.1", 0))
        gone = free.getsockname()[1]
        free.close()
        for status in ({"url": f"http://localhost:{gone}/app/", "port": gone}, {"url": "http://localhost/app/"}, {}):
            result, after = self.start_again(**status)
            self.assertNotIn("Already running", result.stdout, status)
            self.assertEqual((result.returncode, after["state"]), (1, "restarting"), status)


if __name__ == "__main__":
    unittest.main()
