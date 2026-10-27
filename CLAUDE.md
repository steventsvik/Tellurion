# Working on Tellurion

Tellurion is a fork of Ghostty for macOS, built for watching coding agents
work. Most of what's ours is Swift in `macos/Sources/Features/` plus the editor's web
code in `macos/EditorWeb/`. `AGENTS.md` and `macos/AGENTS.md` are upstream Ghostty's
files; where they disagree with this one, follow this one.

## Branches and releases

People watch this repo. Keep `custom` (the default branch) release-quality.

- Commit to `dev`, or to a feature branch off `dev`. `custom` only changes through a pull
  request (`gh pr create --base custom --head dev`, then `gh pr merge --merge`); GitHub
  rejects direct pushes, force-pushes and deletion there, and force-pushes or deletion of
  `dev` and of release tags.
- Never rewrite pushed history (there are forks).
- Add every user-visible change to the **Unreleased** section of `CHANGELOG.md` in the
  same commit, written for users.
- Releases only go through `./release.sh check <version>` and then
  `./release.sh draft <version>`. Drafts are reviewed and published by the maintainer;
  never publish a release.
- No "Co-Authored-By" trailers or mentions of AI in commits, code or docs.

## Build and check

```sh
# The core library, only when files outside macos/ changed:
ZIG_GLOBAL_CACHE_DIR=/private/tmp/gx-zig-global ZIG_LOCAL_CACHE_DIR=/private/tmp/gx-zig-local \
  /opt/homebrew/opt/zig@0.15/bin/zig build -Doptimize=ReleaseFast -Dxcframework-target=native -Demit-macos-app=false

# The app:
cd macos && xcodebuild -project Ghostty.xcodeproj -scheme Ghostty -configuration ReleaseLocal \
  SYMROOT="$PWD/build" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build

cd macos && swiftlint lint --quiet          # must report 0 errors
node --check macos/EditorWeb/*.js            # editor scripts
```

New Swift files are picked up automatically (synchronized folders); no project edits needed.

## Testing without disturbing the maintainer

The maintainer runs Tellurion all day with live agent sessions.

- Never quit, restart or replace `/Applications/Tellurion.app` (named `GhosttyEXTREME.app`
  until its first quit after updating to 1.5.9) while it's running.
  Installing happens only after they say they've quit it.
- Test with a copy: change its bundle id to `com.steventsvik.ghostty-extreme.test` and
  ad-hoc sign it. Launch it with a clean environment:
  `env -i HOME=$HOME USER=$USER PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/open -na <copy>`.
- Anything that brings a window to the front, clicks, or records the screen needs the
  maintainer's go-ahead first; they may be using the Mac. Screenshots and recordings
  capture a single window (`screencapture -l <window id>`), never the whole screen.
- Test-only switches: `GHOSTTY_EXTREME_TEST_TABS=N`, `GHOSTTY_EXTREME_DEMO=<script>`
  (see `DemoDirector.swift`), `GHOSTTY_EXTREME_TEST_BOARD=<script>` (see `BoardTest.swift`),
  `GHOSTTY_EXTREME_TEST_LOG=<file>`. They're read through `TestHooks.swift` and exist only
  in builds made with the `TELLURION_TEST_HOOKS` flag: Debug, and ReleaseLocal as built
  above. `release.sh` builds without it and checks that the shipped app has none of them.
- Always set `GHOSTTY_EXTREME_TEST_HOME=<empty folder>` on a test copy: it moves
  `~/.ghostty-extreme` (boards, prompts, hooks) there. It works in every build, the release
  included. Setting `HOME` alone does nothing,
  since an app's `NSHomeDirectory()` ignores it, and the copy would then write into the
  maintainer's boards. The copy's preferences are its own bundle id's domain:
  `defaults write com.steventsvik.ghostty-extreme.test ExtremeEdition board` picks its edition.

## Performance rules

The sidebar and chrome are in every tab's window, so small costs multiply.

- No SwiftUI `repeatForever` animations and no continuous `TimelineView`s in the
  chrome: each one re-lays out the whole window every frame. Endless motion uses Core
  Animation (`ExtremeMotion.swift`, `ExtremeFilm.swift`), capped at `Motion.chromeRate`.
- Gate any remaining timeline on `@Environment(\.extremeMotion)` (false while the
  window or tab is off screen).
- Glows get a `shadowPath`. Hidden pages and windows do no work.
- Measure before and after: `ps -M -p <pid>` (main thread), `/usr/bin/sample`, `footprint`.

## Security

- Agent and localhost events are terminal escape sequences signed with a per-launch
  token (`EventToken.swift`). Any new event must be verified the same way.
- The editor's web view only loads its own `ghostty-editor://` pages.
- Board web tiles may load any http(s) site, sandboxed (`BoardWebTile.swift`): their own website
  data store, no script message handlers, downloads refused, new windows kept in the tile,
  camera and microphone denied. Keep it that way; never add a bridge into the app there.
- The Backend view runs providers' own CLIs, read-only, and never reads credentials or
  env values (names only).
- Never commit paths into the maintainer's home folder, tokens or personal data;
  `release.sh` checks for these, and GitHub push protection is on.
