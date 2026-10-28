#if os(macOS)
import AppKit
import SwiftUI

/// Isolated sessions: a new tab running a throwaway Docker container. Only the tab's folder
/// (or nothing) is shared with it, and the container is deleted when the session exits.
enum DockerSessionKind: String, CaseIterable, Identifiable {
    case ubuntu
    case python
    case node
    case claude
    case codex

    var id: Self { self }

    var title: String {
        switch self {
        case .ubuntu: return "Ubuntu"
        case .python: return "Python"
        case .node: return "Node.js"
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var detail: String {
        switch self {
        case .ubuntu: return "Plain Ubuntu 24.04 shell"
        case .python: return "Python 3.13 with pip"
        case .node: return "Node.js 22 with npm"
        case .claude: return "Claude Code, sandboxed"
        case .codex: return "Codex, sandboxed"
        }
    }

    var agent: VerticalTabAgentKind? {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        default: return nil
        }
    }

    var symbol: String {
        switch self {
        case .ubuntu: return "shippingbox"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .node: return "hexagon"
        case .claude, .codex: return "shippingbox"
        }
    }
}

enum DockerSessions {
    /// Whether isolated sessions get the tab's folder at /workspace (otherwise they start empty).
    static let shareFolderKey = "GhosttyExtremeDockerShareFolder"

    static var sharesFolder: Bool {
        UserDefaults.standard.object(forKey: shareFolderKey) as? Bool ?? true
    }

    /// Opens a new tab whose command starts the container. Output (image downloads, errors)
    /// stays visible, and when the container exits the tab drops into a normal shell.
    static func open(_ kind: DockerSessionKind, from owner: BaseTerminalController) {
        guard let script = installSupportFiles() else { return }
        let folder = owner.focusedSurface?.pwd
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = folder
        config.command = "/bin/zsh -lc \(shellQuote("\(shellQuote(script)) \(kind.rawValue) \(sharedArgument(folder))"))"
        guard let surface = TerminalWindows.newTerminal(owner.ghostty, from: owner, config: config,
                                                        title: "\(kind.title) · Docker") else { return }
        if let agent = kind.agent {
            VerticalTabsAgents.shared.setStaticAgent(agent, task: "Isolated in Docker", on: surface)
        }
    }

    /// The folder to share, "-" for none, or "-home" when the tab is in the home folder (or
    /// somewhere unknown), which is never shared: that would expose nearly everything.
    private static func sharedArgument(_ folder: String?) -> String {
        guard sharesFolder else { return "-" }
        guard let folder else { return "-home" }
        let path = (folder as NSString).standardizingPath
        if path == "/" || path == (NSHomeDirectory() as NSString).standardizingPath { return "-home" }
        return shellQuote(path)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Writes the launcher script and the agent image's Dockerfile to Application Support,
    /// refreshing them on every use so app updates take effect. Returns the script path.
    private static func installSupportFiles() -> String? {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("GhosttyEXTREME/docker", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let script = dir.appendingPathComponent("sandbox.sh")
            try launcherScript.write(to: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            try agentDockerfile.write(to: dir.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
            return script.path
        } catch {
            return nil
        }
    }

    /// Image for the sandboxed agents. Bump the tag when this changes so it's rebuilt.
    private static let agentImage = "ghostty-extreme/agent:1"

    private static let agentDockerfile = """
    # Tellurion: image for sandboxed Claude Code and Codex sessions.
    FROM node:22-bookworm
    RUN apt-get update \\
     && apt-get install -y --no-install-recommends git ripgrep python3 python3-pip less curl ca-certificates \\
     && rm -rf /var/lib/apt/lists/*
    RUN npm install -g @anthropic-ai/claude-code @openai/codex && npm cache clean --force
    RUN mkdir -p /workspace /home/node/.claude /home/node/.codex \\
     && chown -R node:node /workspace /home/node
    USER node
    ENV CLAUDE_CONFIG_DIR=/home/node/.claude
    WORKDIR /workspace
    """

    private static let launcherScript = """
    #!/bin/bash
    # Tellurion: starts an isolated Docker session.
    # Usage: sandbox.sh <ubuntu|python|node|claude|codex> <folder to share | - | -home>
    # Always ends in a normal shell on the Mac, so errors stay readable.
    kind="$1"
    folder="$2"
    here="$(cd "$(dirname "$0")" && pwd)"

    back_to_mac() {
      printf '\n\033[1;36m▣ Back on your Mac\033[0m\n\n'
      exec "${SHELL:-/bin/zsh}" -l
    }

    if ! docker info >/dev/null 2>&1; then
      if command -v colima >/dev/null 2>&1; then
        echo "Starting Docker (Colima)…"
        colima start || back_to_mac
        # Remember that this session started it, so it's stopped again afterwards.
        started_colima=1
        mkdir -p "$HOME/.ghostty-extreme" && date +%s > "$HOME/.ghostty-extreme/colima-started"
      else
        echo "Docker isn't running. Start Docker Desktop, OrbStack or Colima, then try again."
        back_to_mac
      fi
    fi

    args=(--rm -it --hostname "$kind-sandbox" --name "ghostty-$kind-$(date +%s)"
          -e TERM=xterm-256color -e COLORTERM=truecolor)
    case "$kind" in
      ubuntu) image=ubuntu:24.04; cmd=(bash) ;;
      python) image=python:3.13; cmd=(bash) ;;
      node)   image=node:22; cmd=(bash) ;;
      claude|codex)
        image=\(agentImage)
        if ! docker image inspect "$image" >/dev/null 2>&1; then
          echo "Building the agent image (first time only, a few minutes)…"
          docker build -t "$image" "$here" || back_to_mac
        fi
        # Logins live in Docker volumes, so you sign in once and your Mac's
        # credentials are never shared with the container.
        args+=(-v ghostty-extreme-claude:/home/node/.claude -v ghostty-extreme-codex:/home/node/.codex)
        cmd=("$kind") ;;
      *) echo "Unknown session type: $kind"; back_to_mac ;;
    esac

    if [ "$folder" = "-home" ]; then
      args+=(-w /workspace)
      shared="Nothing from your Mac is shared (your home folder never is; start from a project folder to share it)."
    elif [ "$folder" != "-" ]; then
      args+=(-v "$folder:/workspace" -w /workspace)
      shared="$folder is shared at /workspace; nothing else on your Mac is visible."
      case "$folder" in
        "$HOME"/*) ;;
        *) shared="$shared
      Note: Colima only shares folders inside your home folder, so /workspace may look empty." ;;
      esac
    else
      args+=(-w /workspace)
      shared="Nothing from your Mac is shared."
    fi

    printf '\\033[1;36m▣ Isolated %s session\\033[0m  %s\\n  Type exit to leave; the container is deleted.\\n\\n' "$kind" "$shared"
    docker run "${args[@]}" "$image" "${cmd[@]}"
    # The VM uses gigabytes of memory: if a Tellurion session started it and no
    # containers are left running, stop it.
    if [ -f "$HOME/.ghostty-extreme/colima-started" ] && [ -z "$(docker ps -q 2>/dev/null)" ]; then
      echo "Stopping Docker (Colima); nothing else is using it…"
      colima stop >/dev/null 2>&1 && rm -f "$HOME/.ghostty-extreme/colima-started"
    fi
    back_to_mac
    """
}

#endif
