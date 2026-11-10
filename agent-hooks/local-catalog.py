#!/usr/bin/env python3
"""Tells Codex about the models on this Mac, so they get the tools its own models get.

Usage: local-catalog.py --provider ollama|lmstudio --codex CODEX --out FOLDER [--model NAME] [--base URL]
       (`tellurion local codex` runs it)

Codex treats a model it doesn't know with fallback settings, which leave out apply_patch and take
its context to be what Codex's own models have. So this writes FOLDER/codex-catalog.json for
`-c model_catalog_json`: one entry per model here that can call tools, built from an entry of the
Codex that's installed, as venice-catalog.py does for Venice. The model to run is the one asked
for, which has to be here and able to call tools, or else one that's loaded, or else the first that
can; FOLDER/default-model records it.

In Ollama the model is loaded first, so the context it's really served with is known: Ollama gives
a model a smaller context than it allows (its settings, or a default from the Mac's memory), and
Codex has to compact before that is full, or the start of the conversation is silently cut off.
One line of JSON on stdout says what was found: {"model": …, "context": …, "tools": …, "base": …},
"base" being the server's address, so Codex can be sent to the server that was checked.

Exit 0: written. 1: the catalog couldn't be made (Codex still runs, with the fallback; the JSON
line is still printed). 2: the model asked for isn't here or can't call tools, said on stderr.
3: the server isn't running. Only the standard library, so it runs wherever Python does.
"""
import argparse
import importlib.util
import json
import os
import re
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
# Ollama and LM Studio names: "publisher/model:tag", "org/Model-7B-GGUF".
NAME = re.compile(r"^[A-Za-z0-9_.][A-Za-z0-9_.:/-]{0,199}$")
TIMEOUT = 20
# Loading a big model from disk can take a while.
LOAD_TIMEOUT = 600
LMSTUDIO = "http://127.0.0.1:1234"
APPS = {"ollama": "Ollama", "lmstudio": "LM Studio"}


def shared():
    """venice-catalog.py's entry building, so both catalogs come out the same."""
    spec = importlib.util.spec_from_file_location("venice_catalog", os.path.join(HERE, "venice-catalog.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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


def fetch(url, body=None, timeout=TIMEOUT):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"} if data else {})
    # Direct, whatever proxy the environment names: this is a server on this Mac.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=timeout) as response:
        return json.load(response)


def ollama_models(base):
    """Every model Ollama has: whether it can call tools and see images, its own context size,
    and whether it's loaded now."""
    loaded = {row.get("name") for row in fetch(base + "/api/ps").get("models") or []}
    models = []
    for tag in fetch(base + "/api/tags").get("models") or []:
        name = tag.get("name")
        if not isinstance(name, str) or not NAME.match(name):
            continue
        shown = fetch(base + "/api/show", {"model": name})
        capabilities = shown.get("capabilities") or []
        info = shown.get("model_info") or {}
        context = next((v for k, v in info.items() if k.endswith(".context_length") and isinstance(v, int)), None)
        models.append({"name": name, "tools": "tools" in capabilities, "vision": "vision" in capabilities,
                       "context": context, "loaded": name in loaded, "served": None})
    return models


def ollama_load(base, name):
    """Loads the model and returns the context Ollama serves it with."""
    fetch(base + "/api/generate", {"model": name}, timeout=LOAD_TIMEOUT)
    for row in fetch(base + "/api/ps").get("models") or []:
        if row.get("name") == name and isinstance(row.get("context_length"), int):
            return row["context_length"]
    return None


def lmstudio_models(base):
    """LM Studio's language models. It doesn't say which can call tools, so all are offered."""
    models = []
    for row in fetch(base + "/api/v0/models").get("data") or []:
        name = row.get("id")
        if row.get("type") not in ("llm", "vlm") or not isinstance(name, str) or not NAME.match(name):
            continue
        models.append({"name": name, "tools": None, "vision": row.get("type") == "vlm",
                       "context": row.get("max_context_length"), "loaded": row.get("state") == "loaded",
                       "served": row.get("loaded_context_length")})
    return models


def drivable(model):
    """Can call tools, or isn't known not to."""
    return model["tools"] is not False


def choose(models, wanted, provider):
    """The model to run. ValueError says why there's none."""
    app = APPS[provider]
    able = sorted((m for m in models if drivable(m)), key=lambda m: (not m["loaded"], m["name"]))
    if wanted:
        found = next((m for m in models if m["name"] == wanted), None)
        if found is None and ":" not in wanted:
            found = next((m for m in models if m["name"] == wanted + ":latest"), None)
        if found is None:
            names = ", ".join(m["name"] for m in models)
            raise ValueError(f"{app} has no model named {wanted}." + (f" It has: {names}." if names else ""))
        if not drivable(found):
            others = ", ".join(sorted(m["name"] for m in able))
            raise ValueError(f"{wanted} can't call tools, which Codex needs." + (f" Models here that can: {others}." if others else ""))
        return found
    if not able:
        raise ValueError(f"None of the models in {app} can call tools, which Codex needs. "
                         "Download one that can, such as qwen3, in Tools → Local models.")
    return able[0]


def build(venice, bundled, models, chosen, served, provider):
    """The catalog: the chosen model first, then the others that can call tools. In Ollama the
    context the chosen one is served with is the server's setting, so it caps the others too."""
    base = venice.base_entry(bundled)
    cap = served if provider == "ollama" else None
    rows = [chosen] + sorted((m for m in models if drivable(m) and m is not chosen), key=lambda m: m["name"])
    entries = []
    for priority, model in enumerate(rows, 1):
        context = served if model is chosen else model["served"] or model["context"]
        if cap and context:
            context = min(context, cap)
        context = context or cap or base.get("context_window")
        entries.append(venice.codex_entry(base, slug=model["name"], display_name=model["name"],
                                          description="On this Mac, in " + APPS[provider], priority=priority,
                                          context=context, vision=model["vision"], levels=["medium"], default="medium"))
    return {"models": entries}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--provider", choices=tuple(APPS), required=True)
    parser.add_argument("--codex", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--model", default="")
    parser.add_argument("--base", default="")
    args = parser.parse_args()
    venice = shared()
    clean = venice.CONTROL.sub
    app = APPS[args.provider]
    base = args.base.rstrip("/") or (ollama_base() if args.provider == "ollama" else LMSTUDIO)
    if args.model and not NAME.match(args.model):
        print(clean("", f"That model name can't be right: {args.model}")[:200], file=sys.stderr)
        return 2
    try:
        models = ollama_models(base) if args.provider == "ollama" else lmstudio_models(base)
    except (urllib.error.URLError, OSError, ValueError):
        print(f"{app} isn't running, so Codex can't use its models. Start it in Tools → Local models.", file=sys.stderr)
        return 3
    try:
        chosen = choose(models, args.model, args.provider)
    except ValueError as error:
        print(clean("", str(error))[:400], file=sys.stderr)
        return 2
    served = chosen["served"] or chosen["context"]
    if args.provider == "ollama":
        try:
            served = ollama_load(base, chosen["name"]) or served
        except (urllib.error.URLError, OSError, ValueError):
            pass  # Codex loads it itself; the context stays the model's own
    print(json.dumps({"model": chosen["name"], "context": served, "tools": chosen["tools"], "base": base}), flush=True)
    try:
        os.makedirs(args.out, mode=0o700, exist_ok=True)
        bundled = json.loads(venice.run_codex(args.codex, "debug", "models", "--bundled"))
        venice.write(os.path.join(args.out, "codex-catalog.json"), json.dumps(build(venice, bundled, models, chosen, served, args.provider)))
        venice.write(os.path.join(args.out, "default-model"), chosen["name"] + "\n")
        return 0
    except Exception as error:  # noqa: BLE001 - Codex still runs; the caller says what's lost
        print(clean("", str(error))[:200], file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
