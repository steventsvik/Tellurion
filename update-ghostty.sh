#!/usr/bin/env bash
# Merge the newest official Ghostty release into a new branch off `dev`.
# Usage: ./update-ghostty.sh          (check, then merge)
#        ./update-ghostty.sh --check  (only report whether an update exists)
#
# It merges and never rebases: this history is public, with forks. It doesn't build, install
# or push; the branch goes through a pull request like any other change.
set -euo pipefail
cd "$(dirname "$0")"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Uncommitted changes present. Commit or stash them first." >&2
  exit 1
fi

git fetch origin dev --quiet
git fetch upstream --tags --quiet

latest=$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)
echo "Latest official release: $latest"

if git merge-base --is-ancestor "$latest" origin/dev; then
  echo "dev already has it."
  exit 0
fi
[[ "${1:-}" == "--check" ]] && exit 0

branch="ghostty-${latest#v}"
git switch --quiet -c "$branch" origin/dev
if ! git merge --no-ff --no-edit "$latest"; then
  echo
  echo "$latest conflicts with Tellurion on $branch. Resolve the conflicts, then: git commit"
  echo "To give up: git merge --abort"
  exit 1
fi

zig_version=$(grep -o 'minimum_zig_version = "[^"]*"' build.zig.zon | cut -d'"' -f2)
echo "Merged $latest into $branch. It needs Zig $zig_version."
echo "Next: build it (see CLAUDE.md), test it, and open a pull request into dev."
