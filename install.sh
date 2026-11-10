#!/bin/bash
# Installs or updates Tellurion (formerly GhosttyEXTREME) from the latest release on GitHub:
#
#   curl -fsSL https://raw.githubusercontent.com/steventsvik/Tellurion/custom/install.sh | bash
#
# Downloads the app, checks it against the release's SHA-256 checksum, checks that it's signed
# by Tellurion's developer and notarized by Apple, and puts it in /Applications (keeping the old
# copy until the new one is in place). Downloaded this way, macOS doesn't quarantine it, so
# there's no "can't be opened" step. Nothing else on the Mac is changed: the app's welcome
# window sets up agent status when it first opens.

set -euo pipefail

REPO=steventsvik/Tellurion
# The Developer ID team every release is signed by (release.sh).
TEAM_ID=2N6Q8XFTLZ
DIR=${GHOSTTY_EXTREME_INSTALL_TO:-/Applications}
DEST=$DIR/Tellurion.app
# The app's name before the rebrand; an existing copy is replaced, not kept beside it.
OLD=$DIR/GhosttyEXTREME.app

# What the exit trap tidies up, wherever the script stops.
work=""
staged=""
aside=""
previous=""
installed=0

say() { printf '%s\n' "$*"; }
die() { printf 'Tellurion: %s\n' "$*" >&2; exit 1; }

cleanup() {
  # Stopped in the middle of the swap: the old copy goes back where it was. It only waits
  # beside its own place, never in the download folder that's deleted here.
  if [ -n "$aside" ] && [ -d "$aside" ]; then
    if [ "$installed" = 1 ]; then rm -rf "$aside"; else mv "$aside" "$previous" 2>/dev/null || true; fi
  fi
  [ -n "$staged" ] && rm -rf "$staged"
  [ -n "$work" ] && rm -rf "$work"
  return 0
}

# Everything runs from this function, called on the last line: a download of this script cut
# off part-way then runs nothing, instead of the first half of an install.
main() {
  [ "$(uname -s)" = Darwin ] || die "this is a macOS app."
  [ "$(uname -m)" = arm64 ] || die "only Apple silicon Macs are supported for now (https://github.com/$REPO/issues/7)."
  local major
  major=$(sw_vers -productVersion | cut -d. -f1)
  [ "$major" -ge 13 ] || die "macOS 13 or newer is needed (this Mac has $(sw_vers -productVersion))."

  local running
  for running in "$DEST" "$OLD"; do
    if pgrep -qf "$running/Contents/MacOS/"; then
      die "$(basename "$running" .app) is running. Quit it (⌘Q), then run this again."
    fi
  done

  work=$(mktemp -d /tmp/ghostty-extreme-install.XXXXXX)
  trap cleanup EXIT

  say "Finding the latest release…"
  curl -fsSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$REPO/releases/latest" -o "$work/release.json" \
    || die "couldn't reach GitHub."
  json() { plutil -extract "$1" raw -o - "$work/release.json" 2>/dev/null; }
  local tag version
  tag=$(json tag_name) || die "no published release found."
  version=${tag#extreme-}

  local zip_url="" zip_name="" sums_url="" name url i=0
  while name=$(json "assets.$i.name"); do
    url=$(json "assets.$i.browser_download_url")
    case "$name" in
      *-macos-arm64.zip) zip_url=$url; zip_name=$name ;;
      SHA256SUMS) sums_url=$url ;;
    esac
    i=$((i + 1))
  done
  [ -n "$zip_url" ] || die "release $tag has no app download."

  say "Downloading Tellurion ${version}…"
  curl -fL --progress-bar "$zip_url" -o "$work/$zip_name" || die "download failed."

  # The checksum comes from the release's SHA256SUMS file, or its notes for older releases.
  local expected actual
  if [ -n "$sums_url" ]; then
    curl -fsSL "$sums_url" -o "$work/SHA256SUMS" || die "couldn't download the checksums."
    expected=$(awk -v f="$zip_name" '$2 == f || $2 == "*" f {print $1; exit}' "$work/SHA256SUMS")
  else
    expected=$(json body | grep -F "$zip_name" | grep -oE '[0-9a-f]{64}' | head -1 || true)
  fi
  [ -n "$expected" ] || die "release $tag doesn't list a checksum for $zip_name; not installing it."
  actual=$(shasum -a 256 "$work/$zip_name" | awk '{print $1}')
  [ "$actual" = "$expected" ] || die "the download doesn't match its checksum; not installing it."
  say "Checksum verified."

  ditto -x -k "$work/$zip_name" "$work/unpacked" || die "couldn't unpack the download."
  # Releases before the rebrand contain GhosttyEXTREME.app.
  local app="$work/unpacked/Tellurion.app"
  [ -d "$app" ] || app="$work/unpacked/GhosttyEXTREME.app"
  [ -d "$app" ] || die "the download doesn't contain Tellurion.app."

  # The checksum came from the same place as the download, so it only shows the download
  # arrived whole. The signature is what shows who made it: Tellurion's Developer ID, nothing
  # changed since it was signed, and Apple's notarization. Checked before anything is touched.
  codesign --verify --deep --strict \
    -R="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$TEAM_ID\"" \
    "$app" 2>/dev/null \
    || die "the download isn't signed by Tellurion's developer (or was changed afterwards); not installing it."
  spctl --assess --type execute "$app" 2>/dev/null \
    || die "macOS wouldn't open the download (it isn't notarized by Apple); not installing it."
  say "Signature verified."
  xattr -dr com.apple.quarantine "$app" 2>/dev/null || true

  # Swap in the new copy. It's brought next to its place first, so the swap itself is two
  # renames, and the old copy is put back if either fails or the script is stopped between them.
  staged="$DIR/.Tellurion-installing-$$.app"
  rm -rf "$staged"
  mv "$app" "$staged" || die "couldn't put the app in $DIR (is it writable?)."
  local old
  for old in "$DEST" "$OLD"; do
    if [ -d "$old" ]; then
      previous=$old
      aside="$DIR/.Tellurion-previous-$$.app"
      rm -rf "$aside"
      mv "$old" "$aside" || { aside=""; die "couldn't move the old copy aside (is $DIR writable?)."; }
      break
    fi
  done
  mv "$staged" "$DEST" || die "couldn't put the app in $DIR."
  installed=1
  # An old-named copy left beside the new one would be a second, outdated app.
  if [ "$previous" = "$DEST" ] && [ -d "$OLD" ]; then
    rm -rf "$OLD"
  fi

  say "Installed Tellurion ${version} in $DIR."
  say "Opening it: the welcome window connects Claude Code and Codex. Later versions arrive"
  say "through Tellurion > Check for Updates…"
  [ -n "${GHOSTTY_EXTREME_INSTALL_TO:-}" ] || open "$DEST"
}

main "$@"
