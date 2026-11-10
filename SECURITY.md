# Security

## Reporting a vulnerability

Please report security problems privately, not in a public issue: use
[Report a vulnerability](https://github.com/steventsvik/Tellurion/security/advisories/new)
on the repository's Security tab. Include what you found, how to reproduce it, and which
version you're on (Tellurion → About).

You'll get a reply within a few days. Fixes ship in a new release, and the advisory is
published once people have had a chance to update.

Problems in Ghostty itself (the terminal emulator, not Tellurion's additions) should
go to the [Ghostty project](https://github.com/ghostty-org/ghostty/security).

## Supported versions

Only the latest release gets security fixes. Tellurion updates itself through
**Check for Updates…**; downloads are checked against a signature built into the app.

## What Tellurion does and doesn't do

- **Nothing leaves your Mac unless you ask.** There's no account of ours, telemetry or server.
  What goes elsewhere is what your agents send through their own sign-ins, and what a feature
  you turned on sends to the service you chose for it: chats and Codex sessions on a Venice
  account you connected, web searches (to Exa, or to a SearXNG of your own), downloads of
  local models, the skills directory when you browse it, web pages you open in a board, and
  your phone over your own Tailscale network if you set that up. The app also checks this
  project's releases on GitHub for updates.
- **Agent activity stays in files on your Mac.** Tracking reads the session files Claude Code
  and Codex already write, and Tellurion keeps a record of each session's activity of its own
  (prompts, tool calls) in its folder, `~/.ghostty-extreme/`, readable only by you. Those
  records are removed after two weeks without use.
- **Only its own hooks can send it events.** Agent status arrives as terminal escape
  sequences; each launch creates a secret that only its own terminals and hooks know, and
  events without it are ignored.
- **The Backend view never reads credentials.** It runs your providers' own CLIs with their
  existing logins, read-only commands only, and reads only the names of env variables.
- **The code editor and Visual Fix stay local.** The editor only shows its own pages, and
  Visual Fix only talks to your local dev server.
- **Releases** are built and checked by `release.sh` (including a scan for keys, tokens and
  personal paths), signed with a Developer ID and notarized by Apple, and every release lists
  SHA-256 checksums. `install.sh` checks the checksum and the signature before it installs.
