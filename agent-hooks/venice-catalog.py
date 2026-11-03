#!/usr/bin/env python3
"""Tells Codex about Venice's models, so they get the tools its own models get.

Usage: venice-catalog.py --port PORT --codex CODEX --out FOLDER
       (`tellurion venice codex` runs it; the proxy's token is in TELLURION_VENICE_TOKEN)

Codex treats a model it doesn't know with fallback settings, which among other things leave out
apply_patch. So this writes FOLDER/codex-catalog.json for `-c model_catalog_json`: one entry per
Venice model that can call tools, from Venice's live list, each built from an entry of the Codex
that's installed, so its prompts and format always match that version. FOLDER/default-model is
the model used when none is chosen. Nothing here touches Codex's own config.

It's kept for a few hours, and written again when Codex changes. If it can't be made, an earlier
one stays, and if there's none it says so and exits 1: Codex still runs, without apply_patch.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request

MAX_AGE = 6 * 60 * 60
SLUG = re.compile(r"^[A-Za-z0-9_.:][A-Za-z0-9_.:-]{0,199}$")
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")
LEVELS = {"none": "No extra reasoning", "minimal": "Very little reasoning", "low": "Fast responses with lighter reasoning",
          "medium": "Balances speed and reasoning depth", "high": "Greater reasoning depth", "xhigh": "Extra high reasoning depth",
          "max": "Maximum reasoning depth"}


def text(value, fallback=""):
    return CONTROL.sub("", value) if isinstance(value, str) else fallback


def is_plain_entry(entry):
    """An entry that uses the ordinary tools: not code mode, nor the lighter request format."""
    return not entry.get("tool_mode") and not entry.get("use_responses_lite") and entry.get("apply_patch_tool_type") == "freeform" \
        and bool(entry.get("base_instructions"))


def base_entry(bundled):
    """The entry to build from. By what it does rather than its name, since names change: the
    newest plain one, which has the most current prompts."""
    plain = [entry for entry in bundled.get("models", []) if is_plain_entry(entry)]
    if not plain:
        raise ValueError("this Codex has no plain model entry to build from")
    return min(plain, key=lambda entry: entry.get("priority", 10 ** 6))


def usable(row):
    """A model Codex can drive: tool calls, and Venice's Responses API, which isn't for E2EE models."""
    spec = row.get("model_spec") or {}
    capabilities = spec.get("capabilities") or {}
    return bool(SLUG.match(str(row.get("id", "")))) and capabilities.get("supportsFunctionCalling") is True \
        and capabilities.get("supportsE2EE") is not True and spec.get("offline") is not True


def rank(row):
    spec = row.get("model_spec") or {}
    capabilities = spec.get("capabilities") or {}
    traits = spec.get("traits") or []
    return (0 if spec.get("uncensored") and spec.get("privacy") == "private" else 1 if spec.get("uncensored") else 2,
            0 if capabilities.get("optimizedForCode") else 1,
            0 if "function_calling_default" in traits else 1,
            row["id"])


def venice_entry(base, row, priority):
    spec = row.get("model_spec") or {}
    capabilities = spec.get("capabilities") or {}
    entry = dict(base)
    entry.pop("tool_mode", None)
    context = spec.get("availableContextTokens") or row.get("context_length") or base.get("context_window")
    entry.update(
        slug=row["id"],
        display_name=text(spec.get("name"), row["id"]) or row["id"],
        description=("Abliterated or uncensored, on Venice" if spec.get("uncensored") else "On Venice"),
        priority=priority,
        visibility="list",
        context_window=context,
        max_context_window=context,
        effective_context_window_percent=90,
        apply_patch_tool_type="freeform",
        web_search_tool_type="text",
        upgrade=None,
        availability_nux=None,
        additional_speed_tiers=[],
        service_tiers=[],
        support_verbosity=False,
        supports_search_tool=False,
        supports_image_detail_original=False,
        use_responses_lite=False,
        supports_reasoning_effort_updates=False,
        default_reasoning_summary="none",
        input_modalities=["text", "image"] if capabilities.get("supportsVision") else ["text"],
    )
    # Venice's own list of efforts, among those this Codex knows. A model without any still has
    # to name one for the format, and Venice ignores it there.
    options = [o for o in capabilities.get("reasoningEffortOptions") or [] if o in LEVELS]
    if capabilities.get("supportsReasoning") and not options:
        options = ["low", "medium", "high"]
    default = capabilities.get("defaultReasoningEffort")
    if not options:
        options, default = ["medium"], "medium"
    entry["supported_reasoning_levels"] = [{"effort": o, "description": LEVELS[o]} for o in options]
    entry["default_reasoning_level"] = default if default in options else ("medium" if "medium" in options else options[0])
    return entry


def build(bundled, rows):
    """The catalog, and the model to use when none is chosen. Models that can't be driven are left out."""
    base = base_entry(bundled)
    chosen = sorted((row for row in rows if usable(row)), key=rank)
    if not chosen:
        raise ValueError("Venice lists no models that can call tools")
    return {"models": [venice_entry(base, row, index + 1) for index, row in enumerate(chosen)]}, chosen[0]["id"]


def write(path, content):
    """Whole or not at all: a Codex starting beside this never reads half a file."""
    with tempfile.NamedTemporaryFile("w", dir=os.path.dirname(path), delete=False, encoding="utf-8") as handle:
        handle.write(content)
    os.chmod(handle.name, 0o600)
    os.replace(handle.name, path)


def run_codex(codex, *args):
    return subprocess.run([codex, *args], capture_output=True, text=True, timeout=30, check=True, stdin=subprocess.DEVNULL).stdout


def venice_models(port):
    request = urllib.request.Request(f"http://127.0.0.1:{port}/api/v1/models?type=text",
                                     headers={"Authorization": "Bearer " + os.environ.get("TELLURION_VENICE_TOKEN", "")})
    # Direct, whatever proxy the environment names: this is a server on this Mac.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=20) as response:
        return json.load(response)["data"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--codex", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    catalog = os.path.join(args.out, "codex-catalog.json")
    stamp = os.path.join(args.out, "codex-version")
    try:
        os.makedirs(args.out, mode=0o700, exist_ok=True)
        version = run_codex(args.codex, "--version").strip()
        current = os.path.exists(catalog) and time.time() - os.path.getmtime(catalog) < MAX_AGE
        if current:
            with open(stamp, encoding="utf-8") as handle:
                current = handle.read().strip() == version
        if current:
            return 0
        made, default = build(json.loads(run_codex(args.codex, "debug", "models", "--bundled")), venice_models(args.port))
        write(catalog, json.dumps(made))
        write(stamp, version + "\n")
        write(os.path.join(args.out, "default-model"), default + "\n")
        return 0
    except Exception as error:  # noqa: BLE001 - Codex still runs; the caller says what's lost
        if os.path.exists(catalog):
            return 0
        print(CONTROL.sub("", str(error))[:200], file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
