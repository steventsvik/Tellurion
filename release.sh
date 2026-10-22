#!/bin/zsh
# Builds a Tellurion release, checks it, and creates a draft release on GitHub.
#
#   ./release.sh check 1.5.0    build and check everything; nothing leaves this Mac
#   ./release.sh draft 1.5.0    the same, then a *draft* release (nobody is notified)
#   ./release.sh keys           one-time: the update-signing key, and a check that the
#                               Developer ID certificate and notarization login are set up
#
# Every release publishes appcast.xml, the feed the app's updater reads (signed with the
# update key, so only your builds are ever offered), and SHA256SUMS, which install.sh checks.
# The app is signed with a Developer ID certificate and notarized by Apple, so a downloaded
# zip opens without the "can't be checked for malicious software" warning.
#
# Publish the draft from GitHub once you've looked at it. The notes come from the
# "## 1.5.0" section of CHANGELOG.md. `draft` only runs on `custom`, clean and pushed,
# so a release always matches what's on GitHub.
set -u
setopt pipefail

MODE=${1:-}
VERSION=${2:-}
REPO=steventsvik/Tellurion
# The update key's name in the keychain, the Developer ID certificate, and the notarytool
# profile (saved with: xcrun notarytool store-credentials GhosttyEXTREME --apple-id … --team-id …).
KEY_ACCOUNT=GhosttyEXTREME
TEAM_ID=2N6Q8XFTLZ
SIGN_ID="Developer ID Application: Steven Tsvik ($TEAM_ID)"
NOTARY_PROFILE=GhosttyEXTREME
# Ghostty's own update key: an app that still trusts it would accept official Ghostty builds.
GHOSTTY_ED_KEY="wsNcGf5hirwtdXMVnYoxRIX/SqZQLMOsYlD3q3imeok="
sparkle_tool() {
  find ~/Library/Developer/Xcode/DerivedData -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin/$1" -type f 2>/dev/null | head -1
}
TAG="extreme-$VERSION"
ROOT=${0:A:h}
OUT=/private/tmp/ghostty-extreme-release/$VERSION
ZIG=/opt/homebrew/opt/zig@0.15/bin/zig

step() { print -P "\n%F{yellow}▸ $1%f"; }
pass() { print -P "  %F{green}✓%f $1"; }
fail() { print -P "  %F{red}✗ $1%f"; exit 1; }

cd $ROOT

# ── One-time setup ──────────────────────────────────────────────────────
if [[ $MODE == keys ]]; then
  GENERATE=$(sparkle_tool generate_keys)
  [[ -n $GENERATE ]] || fail "Sparkle's tools aren't built yet; build the app once in Xcode first"
  step "Update-signing key"
  # Creates the key in the login keychain the first time; prints the public key either way.
  $GENERATE --account $KEY_ACCOUNT >/dev/null || fail "couldn't create the update key"
  PUBLIC=$($GENERATE --account $KEY_ACCOUNT -p) || fail "couldn't read the update key"
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUBLIC" macos/Ghostty-Info.plist
  pass "key \"$KEY_ACCOUNT\" in your keychain; its public half is now in Ghostty-Info.plist (commit that)"
  print "  Back the private key up: $GENERATE --account $KEY_ACCOUNT -x ~/ghostty-extreme-update-key.txt"
  print "  (keep that file somewhere safe and offline; without the key, installed copies can't update)"
  step "Developer ID and notarization"
  security find-identity -v -p codesigning | grep -q "\"$SIGN_ID\"" \
    || fail "no \"$SIGN_ID\" certificate; create it in Xcode → Settings → Accounts → Manage Certificates…"
  pass "\"$SIGN_ID\" is in your keychain"
  xcrun notarytool history --keychain-profile $NOTARY_PROFILE >/dev/null 2>&1 \
    || fail "no working notarytool profile \"$NOTARY_PROFILE\"; run xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <Apple ID> --team-id $TEAM_ID"
  pass "notarization login \"$NOTARY_PROFILE\" works"
  exit 0
fi

if [[ ( $MODE != check && $MODE != draft ) || ! $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$' ]]; then
  echo "usage: ./release.sh check|draft <version>   e.g. ./release.sh check 1.5.0"
  echo "       ./release.sh keys                    (once, before the first release with updates)"
  exit 2
fi

# ── Source ──────────────────────────────────────────────────────────────
step "Source"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
[[ -z $(git status --porcelain) ]] || fail "uncommitted changes; commit or stash them first"
pass "working tree clean ($BRANCH @ $(git rev-parse --short HEAD))"
git fetch -q origin --tags || fail "couldn't reach GitHub"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "$TAG already exists"
pass "$TAG is a new version"
if [[ $MODE == draft ]]; then
  [[ $BRANCH == custom ]] || fail "drafts are made from custom (you're on $BRANCH); merge dev into custom with a pull request first"
  [[ $(git rev-parse HEAD) == $(git rev-parse origin/custom) ]] || fail "custom isn't pushed (or is behind origin)"
  pass "custom is pushed"
fi
section() { awk -v v="## $1" '$0==v {on=1; next} on && /^## / {exit} on' CHANGELOG.md; }
NOTES_BODY=$(section $VERSION)
if [[ -z ${NOTES_BODY//[[:space:]]/} && $MODE == check ]]; then
  NOTES_BODY=$(section Unreleased)
  [[ -n ${NOTES_BODY//[[:space:]]/} ]] && pass "release notes: using \"## Unreleased\" (rename it to \"## $VERSION\" before drafting)"
fi
[[ -n ${NOTES_BODY//[[:space:]]/} ]] || fail "CHANGELOG.md has no \"## $VERSION\" section"
[[ $MODE == draft ]] && pass "release notes found in CHANGELOG.md"
PREV=$(git tag --sort=-v:refname | grep '^extreme-' | head -1)

# ── Secrets ─────────────────────────────────────────────────────────────
step "Secrets in changes since $PREV"
PATTERNS='(sk-(ant|proj)-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|xox[baprs]-[A-Za-z0-9-]{10,})'
if git diff "$PREV"..HEAD | grep -E '^\+' | grep -Eq "$PATTERNS"; then
  git diff "$PREV"..HEAD | grep -E '^\+' | grep -En "$PATTERNS" | cut -c1-120
  fail "something that looks like a key or token was added"
fi
pass "no keys or tokens added"
if git diff "$PREV"..HEAD | grep -E '^\+' | grep -v '^+++' | grep -q "/Users/$USER"; then
  git diff "$PREV"..HEAD | grep -E '^\+' | grep -v '^+++' | grep -n "/Users/$USER" | cut -c1-120
  fail "a path inside your home folder was added to the code"
fi
pass "no paths to your home folder added"
# Words that must never appear in the repo or the release notes, one per line, kept
# outside the repo so the list itself isn't published.
BLOCKLIST=~/.ghostty-extreme/release-blocklist
if [[ -s $BLOCKLIST ]]; then
  while IFS= read -r word; do
    [[ -z ${word//[[:space:]]/} ]] && continue
    if git grep -qiF -- "$word" HEAD || git log "$PREV"..HEAD --format=%B | grep -qiF -- "$word" \
      || print -r -- "$NOTES_BODY" | grep -qiF -- "$word"; then
      fail "a blocked word from $BLOCKLIST appears in the code, a commit message or the release notes"
    fi
  done < $BLOCKLIST
  pass "no blocked words"
fi

# ── Build ───────────────────────────────────────────────────────────────
step "Build (a few minutes)"
mkdir -p $OUT
ZIG_GLOBAL_CACHE_DIR=/private/tmp/gx-zig-global ZIG_LOCAL_CACHE_DIR=/private/tmp/gx-zig-local \
  $ZIG build -Doptimize=ReleaseFast -Dxcframework-target=native -Demit-macos-app=false > $OUT/zig.log 2>&1 \
  || { tail -20 $OUT/zig.log; fail "core build failed (log: $OUT/zig.log)"; }
pass "core library"
# Xcode never removes resources a previous build put in the app (an old icon, say), not even
# from its compiled asset catalog, so the release starts from an empty app bundle and catalog.
rm -rf macos/build/ReleaseLocal/Ghostty.app \
  ~/Library/Developer/Xcode/DerivedData/Ghostty-*/Build/Intermediates.noindex/Ghostty.build/ReleaseLocal/Ghostty.build/assetcatalog_output(N)
# The hooks folder is copied into the app whole: Python's caches from running the scripts
# locally (ignored by git) would ship, with home-folder paths in them.
rm -rf agent-hooks/__pycache__
(cd macos && xcodebuild -project Ghostty.xcodeproj -scheme Ghostty -configuration ReleaseLocal \
  SYMROOT="$PWD/build" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build > $OUT/xcode.log 2>&1) \
  || { grep -E "error:" $OUT/xcode.log | head -10; fail "app build failed (log: $OUT/xcode.log)"; }
pass "app"
LINT=$(cd macos && swiftlint lint --quiet 2>/dev/null | grep -c ' error: ')
[[ $LINT == 0 ]] || fail "SwiftLint: $LINT errors"
pass "SwiftLint: 0 errors"
for js in macos/EditorWeb/*.js; do node --check $js || fail "$js has a syntax error"; done
pass "editor scripts parse"

# ── Package ─────────────────────────────────────────────────────────────
step "Package"
APP=$OUT/Tellurion.app
rm -rf $APP $OUT/Tellurion-agent-hooks $OUT/*.zip(N)
ditto macos/build/ReleaseLocal/Ghostty.app $APP
# Files built under ~/Desktop carry com.apple.provenance; dropped here, and the archives below
# are made without extended attributes, so no `._` AppleDouble files ride along.
xattr -cr $APP 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" $APP/Contents/Info.plist
# Only release builds check for updates by themselves (see AppDelegate).
/usr/libexec/PlistBuddy -c "Delete :GhosttyExtremeRelease" $APP/Contents/Info.plist 2>/dev/null
/usr/libexec/PlistBuddy -c "Add :GhosttyExtremeRelease bool true" $APP/Contents/Info.plist
# The menu bar shows CFBundleName, which Xcode sets from the target name ("Ghostty").
/usr/libexec/PlistBuddy -c "Set :CFBundleName Tellurion" $APP/Contents/Info.plist
# Debug info carries the build machine's paths; the release doesn't need it.
find $APP -type f -perm +111 -exec sh -c 'file "$1" | grep -q Mach-O && strip -S -x "$1" 2>/dev/null; true' _ {} \;
LEAKS=$(LC_ALL=C grep -rl -a "/Users/$USER" $APP | wc -l | xargs)
[[ $LEAKS == 0 ]] || { LC_ALL=C grep -rl -a "/Users/$USER" $APP | head -5; fail "$LEAKS files in the app contain your home path"; }
pass "no home-folder paths in the app"
# Ghostty's icons are its trademark; the only icon file in the app is Tellurion's.
ICONS=$(cd $APP/Contents/Resources && ls *.icns(N) | grep -vx Tellurion.icns | xargs)
[[ -z $ICONS ]] || fail "the app contains other icons: $ICONS"
pass "only Tellurion's icon in the app"
[[ -z $(find $APP -name "*.profraw" | head -1) ]] || fail "the app contains a profiling file (*.profraw)"
# Signed inside out with the hardened runtime and a secure timestamp, as notarization requires:
# Sparkle's helpers, the Dock plugin, then the app with its entitlements. The same certificate
# every release, so macOS keeps users' permissions (notifications, folders) across updates.
# Ad hoc only for a local check on a Mac without the certificate.
sign_app() {  # sign_app <app> <identity> <entitlements>
  local a=$1 id=$2 sparkle=$1/Contents/Frameworks/Sparkle.framework
  local opts=(--force --options runtime --sign "$id")
  [[ $id != - ]] && opts+=(--timestamp)
  codesign $opts $sparkle/Versions/B/XPCServices/Installer.xpc \
    && codesign $opts --preserve-metadata=entitlements $sparkle/Versions/B/XPCServices/Downloader.xpc \
    && codesign $opts $sparkle/Versions/B/Autoupdate \
    && codesign $opts $sparkle/Versions/B/Updater.app \
    && codesign $opts $sparkle \
    && codesign $opts $a/Contents/PlugIns/DockTilePlugin.plugin \
    && codesign $opts --entitlements $3 $a \
    && codesign --verify --deep --strict $a
}
if security find-identity -v -p codesigning | grep -q "\"$SIGN_ID\""; then
  sign_app $APP "$SIGN_ID" macos/Ghostty.entitlements 2>$OUT/codesign.log || { tail -5 $OUT/codesign.log; fail "signing failed"; }
  pass "signed with \"$SIGN_ID\" (hardened runtime) and verified"
  SIGNED=1
else
  [[ $MODE == draft ]] && fail "no \"$SIGN_ID\" certificate; run ./release.sh keys"
  sign_app $APP - macos/Ghostty.entitlements 2>$OUT/codesign.log || { tail -5 $OUT/codesign.log; fail "signing failed"; }
  pass "signed ad hoc and verified (not notarized: no \"$SIGN_ID\" certificate on this Mac)"
  SIGNED=0
fi
# The updater must trust this project's key, never Ghostty's.
APP_ED_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" $APP/Contents/Info.plist)
[[ $APP_ED_KEY != $GHOSTTY_ED_KEY ]] || fail "the app still trusts Ghostty's update key; run ./release.sh keys and commit Ghostty-Info.plist"
SIGN_UPDATE=$(sparkle_tool sign_update)
GENERATE=$(sparkle_tool generate_keys)
[[ -n $SIGN_UPDATE && -n $GENERATE ]] || fail "Sparkle's sign_update / generate_keys not found (build the app in Xcode once)"
[[ $($GENERATE --account $KEY_ACCOUNT -p 2>/dev/null) == $APP_ED_KEY ]] \
  || fail "the app's SUPublicEDKey isn't the key in your keychain (\"$KEY_ACCOUNT\"); updates would be rejected"
pass "updates signed with your key ($KEY_ACCOUNT) will be accepted"
[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $APP/Contents/Info.plist) == $VERSION ]] || fail "version not set"
pass "version $VERSION"

HOOKS=$OUT/Tellurion-agent-hooks
mkdir -p $HOOKS
for f in agent-hook.sh ghostty-extreme.zsh tellurion ghostty-extreme install.sh localhost localhost-run codex-hook.py memory_context.py install-codex.py agent-event.py opencode-plugin.js; do
  git show HEAD:agent-hooks/$f > $HOOKS/$f || fail "agent-hooks/$f missing"
done
chmod +x $HOOKS/{agent-hook.sh,tellurion,ghostty-extreme,install.sh,localhost,localhost-run,codex-hook.py,install-codex.py,agent-event.py}
grep -rqE "/Users/|$USER" $HOOKS && fail "the hooks contain a personal path or name"
for f in $HOOKS/*.sh $HOOKS/localhost $HOOKS/localhost-run $HOOKS/tellurion $HOOKS/ghostty-extreme; do bash -n $f || fail "$f has a syntax error"; done
# The app installs these itself (welcome window, Check Setup).
for f in agent-hook.sh ghostty-extreme.zsh tellurion ghostty-extreme codex-hook.py memory_context.py localhost localhost-run agent-event.py opencode-plugin.js; do
  cmp -s $HOOKS/$f $APP/Contents/Resources/agent-hooks/$f || fail "the app's bundled agent-hooks/$f doesn't match the repo"
done
# Parse only: py_compile would leave a __pycache__ folder in the release.
for f in $HOOKS/*.py; do python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' $f || fail "$f has a syntax error"; done
pass "agent hooks (checked, no personal paths)"

# ── Launch test ─────────────────────────────────────────────────────────
step "Launch test"
TEST=$OUT/LaunchTest.app
rm -rf $TEST && ditto $APP $TEST
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.steventsvik.ghostty-extreme.releasetest" $TEST/Contents/Info.plist
# Signed like the release (hardened runtime, library validation), so the test catches what
# that would break. Ad hoc can't pass library validation, so without the certificate it's off.
if [[ $SIGNED == 1 ]]; then
  sign_app $TEST "$SIGN_ID" macos/Ghostty.entitlements 2>/dev/null || fail "couldn't sign the test copy"
else
  sign_app $TEST - macos/GhosttyReleaseLocal.entitlements 2>/dev/null || fail "couldn't sign the test copy"
fi
CRASHES_BEFORE=$(ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -ci ghostty)
# In the background: it starts without taking focus or opening a window in front of you.
env -i HOME=$HOME USER=$USER PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/open -gna $TEST --args --window-save-state=never
sleep 12
PID=$(pgrep -f "^$TEST/Contents/MacOS/ghostty" | head -1)
[[ -n $PID ]] || fail "the app quit or crashed on launch"
CPU=$(ps -o %cpu= -p $PID | xargs)
pkill -f "^$TEST/Contents/MacOS/ghostty"; sleep 1; rm -rf $TEST
[[ $(ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -ci ghostty) == $CRASHES_BEFORE ]] || fail "a crash report appeared"
pass "launched and stayed up (idle CPU ${CPU}%%), no crash report"

# ── Notarize ────────────────────────────────────────────────────────────
if [[ $SIGNED == 1 ]]; then
  step "Notarize (Apple scans the app; usually a few minutes)"
  ditto -c -k --keepParent --norsrc --noextattr $APP $OUT/notarize.zip
  xcrun notarytool submit $OUT/notarize.zip --keychain-profile $NOTARY_PROFILE --wait --timeout 30m > $OUT/notarize.log 2>&1
  SUBMISSION=$(awk '/^  id:/ {print $2; exit}' $OUT/notarize.log)
  rm -f $OUT/notarize.zip
  if ! grep -q 'status: Accepted' $OUT/notarize.log; then
    tail -5 $OUT/notarize.log
    [[ -n $SUBMISSION ]] && xcrun notarytool log $SUBMISSION --keychain-profile $NOTARY_PROFILE $OUT/notarize-issues.json >/dev/null 2>&1 \
      && print "  Apple's report: $OUT/notarize-issues.json"
    fail "Apple didn't accept the app"
  fi
  pass "accepted by Apple"
  xcrun stapler staple $APP > $OUT/staple.log 2>&1 || { cat $OUT/staple.log; fail "couldn't attach the notarization ticket"; }
  pass "ticket attached, so it opens even offline"
  # What a downloaded copy goes through: quarantined, then judged by Gatekeeper.
  GK=$OUT/gatekeeper && rm -rf $GK && mkdir -p $GK && ditto $APP $GK/Tellurion.app
  xattr -w com.apple.quarantine "0081;$(printf %x $(date +%s));Safari;" $GK/Tellurion.app
  spctl --assess --type execute -vv $GK/Tellurion.app 2>&1 | grep -q 'source=Notarized Developer ID' \
    || { spctl --assess --type execute -vv $GK/Tellurion.app; fail "Gatekeeper wouldn't open a downloaded copy"; }
  rm -rf $GK
  pass "Gatekeeper opens a downloaded copy (Notarized Developer ID)"
else
  [[ $MODE == draft ]] && fail "drafts must be notarized"
fi

# ── Archives and notes ──────────────────────────────────────────────────
step "Archives"
APPZIP=Tellurion-$VERSION-macos-arm64.zip
HOOKZIP=Tellurion-$VERSION-agent-hooks.zip
# --norsrc --noextattr: a zip with AppleDouble (`._`) entries opens fine in Archive Utility, but
# other unarchivers (The Unarchiver, Keka, unzip) leave them inside the bundle, which breaks the
# signature, and macOS then refuses the app as unverifiable. 1.7.1 shipped that way.
(cd $OUT && ditto -c -k --keepParent --norsrc --noextattr Tellurion.app $APPZIP && ditto -c -k --keepParent --norsrc --noextattr Tellurion-agent-hooks $HOOKZIP)
! unzip -l $OUT/$APPZIP | grep -q '/\._' || fail "the app zip carries AppleDouble files; third-party unarchivers would break the signature"
if [[ $SIGNED == 1 ]]; then
  # What a third-party unarchiver produces: a plain unzip, quarantined, judged by Gatekeeper.
  GK=$OUT/gatekeeper-unzip && rm -rf $GK && mkdir -p $GK && (cd $GK && unzip -q $OUT/$APPZIP)
  xattr -w com.apple.quarantine "0081;$(printf %x $(date +%s));Safari;" $GK/Tellurion.app
  codesign --verify --deep --strict $GK/Tellurion.app 2>/dev/null || fail "the app zip, unpacked with unzip, has a broken signature"
  spctl --assess --type execute -vv $GK/Tellurion.app 2>&1 | grep -q 'source=Notarized Developer ID' \
    || { spctl --assess --type execute -vv $GK/Tellurion.app; fail "Gatekeeper wouldn't open the zip as a third-party unarchiver unpacks it"; }
  rm -rf $GK
  pass "the zip opens whichever unarchiver unpacks it (no AppleDouble files, Notarized Developer ID)"
fi
APPSHA=$(shasum -a 256 $OUT/$APPZIP | cut -d' ' -f1)
HOOKSHA=$(shasum -a 256 $OUT/$HOOKZIP | cut -d' ' -f1)
(cd $OUT && shasum -a 256 $APPZIP $HOOKZIP > SHA256SUMS)
pass "SHA256SUMS (install.sh checks downloads against it)"
# The update feed: one item, this release, its zip signed with the update key.
SIGNATURE=$($SIGN_UPDATE --account $KEY_ACCOUNT $OUT/$APPZIP) || fail "couldn't sign the update"
[[ $SIGNATURE == *edSignature=* ]] || fail "sign_update returned no signature"
cat > $OUT/appcast.xml <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Tellurion</title>
    <link>https://github.com/$REPO/releases</link>
    <item>
      <title>Tellurion $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:releaseNotesLink>
      <description><![CDATA[$NOTES_BODY]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/$APPZIP" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
APPCAST
# The update window shows the changelog section from the feed (UpdateWindow.swift).
[[ $NOTES_BODY != *']]>'* ]] || fail "the release notes contain ]]>, which would break the feed"
xmllint --noout $OUT/appcast.xml || fail "appcast.xml isn't valid XML"
pass "appcast.xml (the updater's feed, signed)"
UPSTREAM=$(git tag --merged HEAD --sort=-v:refname | grep -E '^v[0-9]' | head -1 | sed 's/^v//')
cat > $OUT/notes.md <<NOTES
$NOTES_BODY

## Install

Apple silicon Macs only, macOS 13 or newer. Based on **Ghostty $UPSTREAM**.

**Already on 1.5.0 or later?** Check for Updates… in the app menu installs it.

**New install, or updating from 1.4.x** (whose updater can't reach this release), in Terminal:

\`\`\`sh
curl -fsSL https://raw.githubusercontent.com/$REPO/custom/install.sh | bash
\`\`\`

It downloads \`$APPZIP\`, checks it against \`SHA256SUMS\`, and puts it in \`/Applications\`. Or by hand: download the zip, open it, and move \`Tellurion.app\` to \`/Applications\`. The app is notarized by Apple, so it opens like any other download.

Then open it. The welcome window connects Claude Code and Codex and runs a live test (the hooks are inside the app). \`$HOOKZIP\` has the same hooks for setting up by hand; see the [README](https://github.com/$REPO#agent-status-setup).

Your existing Ghostty configuration (\`~/.config/ghostty/config\`) works as-is.

SHA-256:
- \`$APPZIP\`: \`$APPSHA\`
- \`$HOOKZIP\`: \`$HOOKSHA\`

---

Not affiliated with or endorsed by the Ghostty project. AGPL-3.0; Ghostty's code is MIT. See [NOTICE.md](https://github.com/$REPO/blob/custom/NOTICE.md) for credits.
NOTES
pass "$APPZIP ($(du -h $OUT/$APPZIP | cut -f1 | xargs))"
pass "$HOOKZIP"
pass "notes: $OUT/notes.md"

if [[ $MODE == check ]]; then
  print -P "\n%F{green}All checks passed.%f Nothing was published. Files are in $OUT"
  print "When it's merged into custom and pushed: ./release.sh draft $VERSION"
  exit 0
fi

# ── Draft ───────────────────────────────────────────────────────────────
step "Draft release"
URL=$(gh release create $TAG -R $REPO --draft --target $(git rev-parse HEAD) --title "Tellurion $VERSION" \
  --notes-file $OUT/notes.md $OUT/$APPZIP $OUT/$HOOKZIP $OUT/SHA256SUMS $OUT/appcast.xml) || fail "couldn't create the draft"
pass "draft created (not visible to anyone else yet)"
print -P "\n%F{green}Review it here, then press Publish:%f\n  $URL"
