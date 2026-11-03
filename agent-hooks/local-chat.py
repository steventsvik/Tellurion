#!/usr/bin/env python3
"""Chat with a model on this Mac, where nothing leaves it, or on a Venice account.

Usage: local-chat.py [--provider P] [--base URL] <model>
       (Tellurion runs it as `tellurion local …`)
  ollama (the default)  Ollama, at OLLAMA_HOST or 127.0.0.1:11434
  lmstudio              LM Studio's server, 127.0.0.1:1234
  openai                any OpenAI-compatible server at --base (llama.cpp's llama-server,
                        MLX's mlx_lm.server: 127.0.0.1:8080)
  apple                 Apple's on-device model, served by Tellurion itself (its address
                        and key are in ~/.ghostty-extreme/apple-model.json)
  venice                a model on your Venice account, in the cloud: what you type goes to
                        Venice's servers. Tellurion holds the account's key and forwards the
                        chat; this only knows a token for that, in
                        ~/.ghostty-extreme/venice-proxy.json

A plain chat in the terminal: type a message, the reply streams in. Inside Tellurion it
also reports to the sidebar (working while it answers, done when it's finished), with the
same OSC 777 events the agents' hooks send. Commands: /think shows or hides the
model's reasoning (hidden by default: a model that reasons first shows "Thinking… 12s"), /clear forgets the conversation,
/exit (or Ctrl-D) quits. Ctrl-C stops a reply.
"""
import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request

DIM, BOLD, GOLD, RED, RESET = "\033[2m", "\033[1m", "\033[38;5;179m", "\033[31m", "\033[0m"

# Everything that can steer a terminal, left out of what a server sends: escape sequences
# need these, and a model's answer or an error isn't to be trusted with them.
CONTROL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")


def clean(text):
    """A server's text, safe to print: only newlines and tabs of the control characters."""
    return CONTROL.sub("", text)


def tellurion_home():
    return os.environ.get("GHOSTTY_EXTREME_TEST_HOME") or os.path.expanduser("~")


def ollama_base():
    """OLLAMA_HOST read the way Ollama reads it: "host", "host:port", ":port" or a URL."""
    host = os.environ.get("OLLAMA_HOST", "").strip() or "127.0.0.1:11434"
    scheme = "http"
    if "://" in host:
        scheme, host = host.split("://", 1)
    host = host.split("/", 1)[0]
    if host.startswith(":"):
        host = "127.0.0.1" + host
    if not re.search(r":\d+$", host):
        host += ":11434"
    host = re.sub(r"^(0\.0\.0\.0|\[::\])(?=:)", "127.0.0.1", host)
    return f"{scheme}://{host}"


PROVIDERS = {"ollama": "Ollama", "lmstudio": "LM Studio", "openai": "the model server", "apple": "Tellurion",
             "venice": "Tellurion"}
PROVIDER = "ollama"
BASE = ollama_base()
HEADERS = {"Content-Type": "application/json"}


def configure(provider, base):
    """Points the chat at its provider (see the usage above)."""
    global PROVIDER, BASE
    PROVIDER = provider
    if provider == "lmstudio":
        BASE = (base or "http://127.0.0.1:1234").rstrip("/")
    elif provider == "openai":
        BASE = (base or "http://127.0.0.1:8080").rstrip("/")
    elif provider == "apple":
        with open(os.path.join(os.path.expanduser("~"), ".ghostty-extreme", "apple-model.json")) as handle:
            server = json.load(handle)
        BASE = f"http://127.0.0.1:{int(server['port'])}"
        HEADERS["Authorization"] = "Bearer " + server["token"]
    elif provider == "venice":
        with open(os.path.join(tellurion_home(), ".ghostty-extreme", "venice-proxy.json")) as handle:
            server = json.load(handle)
        # Its paths are /api/v1/…, and the chat's own are /v1/…
        BASE = f"http://127.0.0.1:{int(server['port'])}/api"
        HEADERS["Authorization"] = "Bearer " + server["token"]
    elif base:
        BASE = base.rstrip("/")


def report(model, event, detail=""):
    """Tells Tellurion's sidebar what the chat is doing. Silent anywhere else."""
    if os.environ.get("GHOSTTY_EXTREME_AGENT_EVENTS") != "1":
        return
    if event != "transcript":
        detail = " ".join("".join(c if c.isprintable() else " " for c in detail).split())[:48]
    # The sidebar names the chat after its session; a cloud chat says so there too.
    session = model[:52] + " · cloud" if PROVIDER == "venice" else model[:60]
    body = {"agent": "local", "event": event, "detail": detail, "session": session,
            "t": os.environ.get("GHOSTTY_EXTREME_EVENT_TOKEN", "")}
    # The terminal caps notification bodies at 255 bytes.
    while len(json.dumps(body, separators=(",", ":")).encode()) > 250 and body["detail"]:
        body["detail"] = body["detail"][:-1]
    try:
        with open("/dev/tty", "w") as tty:
            tty.write("\033]777;notify;ghostty-extreme://agent;" + json.dumps(body, separators=(",", ":")) + "\a")
    except OSError:
        pass


FEED = os.path.join(os.path.expanduser("~"), ".ghostty-extreme", "feeds", f"local-{os.getpid()}.jsonl")


def record(kind, content):
    """Adds to the chat's feed, which Tellurion's code editor shows live (Claude Code's
    transcript format, which it already reads)."""
    if os.environ.get("GHOSTTY_EXTREME_AGENT_EVENTS") != "1" or not content:
        return
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + "Z"
    if kind == "prompt":
        entry = {"type": "user", "timestamp": stamp, "message": {"role": "user", "content": content}}
    else:
        block = {"type": "thinking", "thinking": content} if kind == "thinking" else {"type": "text", "text": content}
        entry = {"type": "assistant", "timestamp": stamp, "message": {"role": "assistant", "content": [block]}}
    try:
        os.makedirs(os.path.dirname(FEED), exist_ok=True)
        with open(FEED, "a", encoding="utf-8") as feed:
            feed.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except OSError:
        pass


def post(path, payload, timeout=600):
    request = urllib.request.Request(BASE + path, data=json.dumps(payload).encode(), headers=HEADERS)
    return urllib.request.urlopen(request, timeout=timeout)


NOT_SERVING = "Tellurion isn't connected to Venice right now. Open Tellurion, or connect your account in Tools → Local models."

# Venice's errors are mostly a sentence and a status. For someone in a chat, by status.
VENICE_STATUS = {
    401: "Venice turned down the key: it may be expired or revoked. Connect a new one in Tools → Local models.",
    402: "Out of Venice credits. Top up at https://venice.ai/settings/api",
    404: "Venice doesn't have this model, or it's offline. Pick one from Tools → Local models.",
    429: "Venice is limiting requests right now. Try again in a minute.",
}
# Those the proxy inside Tellurion answers with.
PROXY_ERRORS = {"proxy_token": NOT_SERVING, "not_connected": NOT_SERVING}


def server_error(body, status=None):
    """The text of a server's error: `{"error": "…"}` or `{"error": {"message": "…", "code": …}}`,
    in plain words when Venice's status says what it means, with how long it asks to wait
    (`retry_after`, on an overloaded model). None if there's none to read."""
    detail = body.get("error") if isinstance(body, dict) else None
    code, message, wait = None, detail, None
    if isinstance(detail, dict):
        code, message, wait = detail.get("code"), detail.get("message"), detail.get("retry_after")
    if isinstance(body, dict) and wait is None:
        wait = body.get("retry_after")
    text = clean(str(message)) if message else None
    if PROVIDER == "venice":
        text = PROXY_ERRORS.get(code) or VENICE_STATUS.get(status) or text
    if text and isinstance(wait, (int, float)) and not isinstance(wait, bool) and wait > 0:
        text += f" Try again in {int(wait)} seconds."
    return text


def error_text(error):
    if isinstance(error, urllib.error.HTTPError):
        try:
            text = server_error(json.loads(error.read().decode()), error.code)
        except ValueError:
            text = None
        return text or clean(str(error))
    if isinstance(error, urllib.error.URLError):
        if PROVIDER == "apple":
            return "Tellurion isn't serving Apple's model right now. Open it again from Local models."
        if PROVIDER == "venice":
            return NOT_SERVING
        return f"{PROVIDERS[PROVIDER]} isn't answering at {BASE}. Start it, then try again."
    return clean(str(error))


def venice_check(model):
    """Asks for Venice's models, which proves the connection before anything is typed. Returns an
    error (or None) and what's known of the model, whose privacy tier the banner says."""
    request = urllib.request.Request(BASE + "/v1/models?type=text", headers=HEADERS)
    spec = {}
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            for row in json.load(response).get("data", []):
                if row.get("id") == model:
                    spec = row.get("model_spec") or {}
    except urllib.error.HTTPError as error:
        if error.code == 401:
            return error_text(error), spec
    except urllib.error.URLError as error:
        return error_text(error), spec
    except (OSError, ValueError, AttributeError):
        pass  # A slow or odd list shouldn't stop a chat: its first message will say what's wrong.
    return None, spec


def load(model):
    """Loads the model, so the first answer comes sooner. Returns an error, or None."""
    if PROVIDER != "ollama":
        return None  # The others load a model on its first request (or serve just one).
    try:
        with post("/api/generate", {"model": model, "keep_alive": "10m"}, timeout=300) as response:
            response.read()
        return None
    except Exception as error:  # noqa: BLE001 - shown to the user as is
        return error_text(error)


class NoThinking(Exception):
    """The model can't separate its reasoning from its answer."""


def reply(model, messages, show_reasoning, thinks):
    if PROVIDER != "ollama":
        return reply_openai(model, messages, show_reasoning)
    return reply_ollama(model, messages, show_reasoning, thinks)


def reply_openai(model, messages, show_reasoning):
    """The same, from an OpenAI-compatible server: server-sent events, each with a piece of
    the answer (or of the reasoning, which llama.cpp and LM Studio send separately)."""
    payload = {"model": model, "messages": messages, "stream": True}
    text, reasoning, in_thinking, started, last = [], [], False, time.time(), 0.0
    with post("/v1/chat/completions", payload) as response:
        for raw in response:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            chunk = json.loads(data)
            if chunk.get("error"):
                raise RuntimeError(server_error(chunk) or "The server reported an error.")
            delta = ((chunk.get("choices") or [{}])[0].get("delta") or {})
            thought = clean(delta.get("reasoning_content") or delta.get("reasoning") or "")
            content = clean(delta.get("content") or "")
            if thought:
                reasoning.append(thought)
                if show_reasoning:
                    if not in_thinking:
                        sys.stdout.write(DIM)
                    sys.stdout.write(thought)
                elif time.time() - last > 0.5:
                    last = time.time()
                    sys.stdout.write(f"\r{DIM}Thinking… {int(last - started)}s{RESET}\033[K")
                in_thinking = True
            if content:
                if in_thinking:
                    sys.stdout.write(RESET + "\n\n" if show_reasoning else "\r\033[K")
                    in_thinking = False
                text.append(content)
                sys.stdout.write(content)
            sys.stdout.flush()
    sys.stdout.write(RESET + "\n")
    record("thinking", "".join(reasoning).strip())
    return "".join(text)


def reply_ollama(model, messages, show_reasoning, thinks):
    """Streams one answer to the terminal and returns its text. Models that reason first
    get a one-line "Thinking… 12s" while they do, or their full reasoning, dimmed."""
    payload = {"model": model, "messages": messages, "stream": True, "keep_alive": "10m"}
    if thinks:
        payload["think"] = True
    text, reasoning, in_thinking, started, last = [], [], False, time.time(), 0.0
    try:
        response = post("/api/chat", payload)
    except urllib.error.HTTPError as error:
        if thinks and "thinking" in error_text(error).lower():
            raise NoThinking() from error
        raise
    with response:
        for line in response:
            if not line.strip():
                continue
            chunk = json.loads(line)
            if chunk.get("error"):
                raise RuntimeError(chunk["error"])
            message = chunk.get("message") or {}
            thought, content = clean(message.get("thinking") or ""), clean(message.get("content") or "")
            if thought:
                reasoning.append(thought)
                if show_reasoning:
                    if not in_thinking:
                        sys.stdout.write(DIM)
                    sys.stdout.write(thought)
                elif time.time() - last > 0.5:
                    last = time.time()
                    sys.stdout.write(f"\r{DIM}Thinking… {int(last - started)}s{RESET}\033[K")
                in_thinking = True
            if content:
                if in_thinking:
                    sys.stdout.write(RESET + "\n\n" if show_reasoning else "\r\033[K")
                    in_thinking = False
                text.append(content)
                sys.stdout.write(content)
            sys.stdout.flush()
            if chunk.get("done"):
                break
    sys.stdout.write(RESET + "\n")
    record("thinking", "".join(reasoning).strip())
    return "".join(text)


def unload_unless_shared(model):
    """Frees the model's memory now, unless another chat on this Mac still uses it (Ollama
    would otherwise keep it loaded for 10 minutes)."""
    if PROVIDER not in ("ollama", "lmstudio"):
        return  # A llama.cpp or MLX server holds its one model; Apple's model is the system's.
    try:
        # Other chats on the model (each also has a helper like this one, which counts too).
        others = subprocess.run(["/usr/bin/pgrep", "-f", f"local-chat\\.py .*{re.escape(model)}$"], capture_output=True,
                                text=True, timeout=2).stdout.split()
        if any(int(pid) != os.getpid() for pid in others):
            return
        if PROVIDER == "lmstudio":
            lms = next((path for path in (os.path.expanduser("~/.lmstudio/bin/lms"), os.path.expanduser("~/.cache/lm-studio/bin/lms"))
                        if os.access(path, os.X_OK)), "lms")
            subprocess.run([lms, "unload", model], capture_output=True, timeout=20)
            return
        with post("/api/generate", {"model": model, "keep_alive": 0}, timeout=10) as response:
            response.read()
    except Exception:  # noqa: BLE001 - Ollama frees it on its own after 10 minutes anyway
        pass


def free_on_exit(model):
    """Frees the model when this chat ends, however it ends: /exit, Ctrl-D, or its tab or
    pane closed (which can kill the chat while it waits for input). A small helper process,
    outside the terminal's session, waits for the chat to be gone and then unloads the model."""
    if PROVIDER == "venice":
        return  # Nothing on this Mac to free.
    helper = [sys.executable, os.path.abspath(__file__), "--unload-when-done", "--provider", PROVIDER, "--base", BASE, model]
    try:
        # The chat holds the helper's stdin open until it exits; the helper reads it to the end.
        free_on_exit.helper = subprocess.Popen(helper, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                               stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass


def wait_then_unload(model):
    """The helper's side: wait for the chat to end (its stdin closes), then unload."""
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    try:
        while sys.stdin.buffer.read(1):
            pass
    except OSError:
        pass
    unload_unless_shared(model)


def main():
    args, provider, base = sys.argv[1:], "ollama", None
    helper = bool(args) and args[0] == "--unload-when-done"
    if helper:
        args = args[1:]
    while len(args) > 1 and args[0] in ("--provider", "--base"):
        if args[0] == "--provider":
            provider = args[1]
        else:
            base = args[1]
        args = args[2:]
    if len(args) != 1 or not args[0].strip() or provider not in PROVIDERS:
        print("Usage: tellurion local [--provider ollama|lmstudio|openai|apple|venice] [--base URL] <model>", file=sys.stderr)
        return 2
    model = clean(args[0].strip())
    if helper:
        try:
            configure(provider, base)
        except (OSError, ValueError, KeyError):
            return 0
        wait_then_unload(model)
        return 0
    try:
        configure(provider, base)
    except (OSError, ValueError, KeyError):
        if provider == "venice":
            print(f"{RED}{NOT_SERVING}{RESET}", file=sys.stderr)
        else:
            print(f"{RED}Tellurion isn't serving Apple's model right now. Open it again from Local models.{RESET}", file=sys.stderr)
        return 1
    sys.stdout.write(f"\033]2;{model}\a")  # The tab's title.
    cloud = PROVIDER == "venice"
    print(f"{DIM}{'Connecting to Venice' if cloud else 'Loading ' + model}…{RESET}", flush=True)
    spec = {}
    if cloud:
        problem, spec = venice_check(model)
    else:
        problem = load(model)
    if problem:
        print(f"{RED}{problem}{RESET}", file=sys.stderr)
        return 1
    where = "in the cloud, on Venice" if cloud else f"on this Mac, through {PROVIDERS[PROVIDER] if PROVIDER != 'apple' else 'Apple Intelligence'}"
    print(f"{GOLD}{BOLD}{model}{RESET}{DIM} · {where} · /think shows reasoning · /clear · /exit · Ctrl-C stops a reply{RESET}")
    if cloud and spec.get("privacy") == "anonymized":
        print(f"{DIM}Anonymized: this model's own provider sees what you send, and may store it.{RESET}")
    elif cloud:
        print(f"{DIM}What you type goes to Venice's servers. Venice says it doesn't store it, which can't be verified from here.{RESET}")
    print()
    free_on_exit(model)
    report(model, "session_start")
    # Where the code editor finds this chat's live feed.
    if os.environ.get("GHOSTTY_EXTREME_AGENT_EVENTS") == "1":
        try:
            os.makedirs(os.path.dirname(FEED), exist_ok=True)
            open(FEED, "a").close()
            report(model, "transcript", FEED)
        except OSError:
            pass
    try:
        import readline  # noqa: F401 - arrow keys and history in input()
    except ImportError:
        pass
    messages, show_reasoning, thinks = [], False, True

    try:
        while True:
            try:
                prompt = input(f"{GOLD}›{RESET} ")
            except KeyboardInterrupt:
                print()
                continue
            except EOFError:
                print()
                break
            command = prompt.strip()
            if not command:
                continue
            if command in ("/exit", "/quit", "/bye"):
                break
            if command == "/clear":
                messages = []
                print(f"{DIM}Conversation cleared.{RESET}\n")
                continue
            if command == "/think":
                show_reasoning = not show_reasoning
                print(f"{DIM}{'Showing' if show_reasoning else 'Hiding'} the model's reasoning.{RESET}\n")
                continue
            messages.append({"role": "user", "content": prompt})
            record("prompt", prompt)
            report(model, "prompt_submit", re.sub(r"\s+", " ", prompt))
            print()
            try:
                try:
                    answer = reply(model, messages, show_reasoning, thinks)
                except NoThinking:
                    thinks = False
                    answer = reply(model, messages, show_reasoning, thinks)
                messages.append({"role": "assistant", "content": answer})
                record("message", answer)
                report(model, "stop")
            except KeyboardInterrupt:
                sys.stdout.write(RESET + f"\n{DIM}Stopped.{RESET}\n")
                messages.pop()
                report(model, "stop")
            except Exception as error:  # noqa: BLE001 - shown to the user as is
                print(f"{RESET}\n{RED}{error_text(error)}{RESET}", file=sys.stderr)
                messages.pop()
                report(model, "stop_failure", error_text(error))
            print()
    finally:
        report(model, "session_end")
    return 0


if __name__ == "__main__":
    sys.exit(main())
