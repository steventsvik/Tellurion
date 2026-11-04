#!/usr/bin/env python3
"""Shared memory for Tellurion: what one agent remembers about a project, for the other.

    memory_context.py <claude|codex> <folder>

Prints the context to add at the start of a session of the named agent: for Codex, Claude
Code's notes about the project and its CLAUDE.md; for Claude Code, Codex's memories about
the project and its AGENTS.md. Prints nothing when there's nothing to share or sharing is
turned off in Tellurion's Settings. Only reads files; never fails a session.

The app reads the same places (macos/Sources/Features/Memory/ProjectMemory.swift).
"""
import os
from pathlib import Path
import re
import subprocess
import sys

LIMIT = 6000


def home():
    return Path(os.environ.get("TELLURION_TEST_HOME") or Path.home())


def repo_root(folder):
    try:
        out = subprocess.run(["/usr/bin/git", "-C", folder, "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, timeout=2)
        return out.stdout.strip() if out.returncode == 0 and out.stdout.strip() else folder
    except (OSError, subprocess.SubprocessError):
        return folder


def read(path):
    try:
        return Path(path).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None


def claude_memory_folder(root):
    """Claude Code's folder for a project: the path with everything but letters and digits
    turned into dashes. Matched without case (`~/Projects/App` and `~/projects/app`)."""
    projects = home() / ".claude" / "projects"
    wanted = re.sub(r"[^A-Za-z0-9]", "-", root).lower()
    try:
        names = [n for n in os.listdir(projects) if n.lower() == wanted]
    except OSError:
        return None
    folders = [projects / n / "memory" for n in names if (projects / n / "memory").is_dir()]
    return max(folders, key=lambda f: len(list(f.glob("*.md"))), default=None)


def claude_notes(root):
    folder = claude_memory_folder(root)
    if not folder:
        return []
    notes = []
    for path in sorted(folder.glob("*.md"), key=lambda p: p.stat().st_mtime, reverse=True):
        if path.name == "MEMORY.md":
            continue
        text = read(path) or ""
        fields, body = {}, text
        if text.startswith("---\n") and "\n---" in text[4:]:
            header, _, body = text[4:].partition("\n---")
            body = body.split("\n", 1)[1] if "\n" in body else ""
            for line in header.split("\n"):
                key, sep, value = line.partition(":")
                if sep and key.strip() and value.strip() and key.strip() not in fields:
                    fields[key.strip()] = value.strip().strip("\"'")
        title = fields.get("name", path.stem)
        notes.append(f"### {title} ({fields.get('type', 'note')})\n\n{body.strip()}")
    return notes


def codex_groups(root):
    text = read(home() / ".codex" / "memories" / "MEMORY.md")
    if not text:
        return []
    wanted = root.lower().strip("/")
    groups = []
    for group in ("\n" + text).split("\n# Task Group: ")[1:]:
        match = re.search(r"^applies_to:.*?cwd=([^;\n]+)", group, re.M)
        if not match:
            continue
        cwd = match.group(1).strip().lower().strip("/")
        if cwd == wanted or cwd.startswith(wanted + "/"):
            heading, _, body = group.partition("\n")
            groups.append(f"### {heading.strip()}\n\n{strip_codex_bookkeeping(body).strip()}")
    return groups


def strip_codex_bookkeeping(body):
    """Codex's own file lists and search keywords mean nothing to another agent."""
    return re.sub(r"\n### (rollout_summary_files|keywords)\n.*?(?=\n#{1,3} |\Z)", "", "\n" + body, flags=re.S)


def same(a, b):
    return a is not None and b is not None and a.strip() == b.strip()


def context(agent, folder):
    if (home() / ".ghostty-extreme" / "features" / "shared-memory-off").exists():
        return None
    root = repo_root(folder)
    claude_md = read(os.path.join(root, "CLAUDE.md"))
    agents_md = read(os.path.join(root, "AGENTS.md"))
    if agent == "codex":
        parts = claude_notes(root)
        if claude_md and not same(claude_md, agents_md):
            parts.append(f"### CLAUDE.md\n\n{claude_md.strip()}")
        source = "Claude Code"
    elif agent == "claude":
        parts = codex_groups(root)
        if agents_md and not same(agents_md, claude_md):
            parts.append(f"### AGENTS.md\n\n{agents_md.strip()}")
        source = "Codex"
    else:
        return None
    if not parts:
        return None
    text = "\n\n".join(parts)
    if len(text) > LIMIT:
        text = text[:LIMIT] + "\n…(cut; the rest is in Tellurion → Project Memory)"
    return (f"## What {source} remembers about this project\n\n"
            f"Shared by Tellurion from {source}'s own memory of {root}. Treat these as notes "
            f"from a colleague who worked here: they can be out of date, so check before relying "
            f"on one, and follow the user if they disagree.\n\n{text}")


def main():
    if len(sys.argv) != 3:
        return
    try:
        text = context(sys.argv[1], sys.argv[2])
    except Exception:  # noqa: BLE001 - never fail a session start
        return
    if text:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
