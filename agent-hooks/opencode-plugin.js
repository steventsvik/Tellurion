// Tellurion: live status for OpenCode in the sidebar. Installed by Tellurion as
// ~/.config/opencode/plugins/ghostty-extreme.js; does nothing outside Tellurion.
//
// OpenCode has no command hooks, so this plugin listens to its events and writes the
// same OSC 777 notification the other agents' hooks send to the terminal. It only
// observes: it never answers a permission, changes a tool's input, or edits a message.
import { appendFileSync, chmodSync, closeSync, mkdirSync, openSync, writeSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"

const ACTIVE = process.env.GHOSTTY_EXTREME_AGENT_EVENTS === "1"
const TOKEN = process.env.GHOSTTY_EXTREME_EVENT_TOKEN || ""

function clip(text) {
  return String(text || "").replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim().slice(0, 48)
}

function sendRaw(body) {
  for (const path of [process.env.GHOSTTY_EXTREME_AGENT_TTY, "/dev/tty"]) {
    if (!path) continue
    try {
      const fd = openSync(path, "a")
      writeSync(fd, `\x1b]777;notify;ghostty-extreme://agent;${JSON.stringify(body)}\x07`)
      closeSync(fd)
      return
    } catch {}
  }
}

// The code editor's live feed: Claude Code's transcript format, which the editor reads,
// under ~/.ghostty-extreme/feeds/ (see agent-event.py).
const FEED = join(process.env.TELLURION_TEST_HOME || homedir(), ".ghostty-extreme", "feeds", `opencode-${process.pid}.jsonl`)
let fed = false

function record(entry) {
  if (!ACTIVE) return
  try {
    // Prompts and tool calls: for this user only, like the agents' own transcripts.
    mkdirSync(dirname(FEED), { recursive: true, mode: 0o700 })
    appendFileSync(FEED, JSON.stringify({ timestamp: new Date().toISOString(), ...entry }) + "\n", { mode: 0o600 })
    if (!fed) {
      fed = true
      chmodSync(dirname(FEED), 0o700)
      chmodSync(FEED, 0o600)
      sendRaw({ agent: "opencode", event: "transcript", detail: FEED, t: TOKEN })
    }
  } catch {}
}

function claudeTool(tool, args) {
  const a = args || {}
  const name = String(tool || "").toLowerCase()
  const input = {}
  const path = a.filePath || a.file_path || a.path
  if (path) input.file_path = path
  for (const [from, to] of [["command", "command"], ["cmd", "command"], ["pattern", "pattern"], ["url", "url"],
                            ["oldString", "old_string"], ["newString", "new_string"], ["old_string", "old_string"],
                            ["new_string", "new_string"], ["old_str", "old_string"], ["new_str", "new_string"], ["content", "content"]]) {
    if (typeof a[from] === "string" && !(to in input)) input[to] = a[from].slice(0, 4000)
  }
  const rules = [["TodoWrite", ["todo"]], ["Edit", ["edit", "patch", "replace"]], ["Write", ["write", "create"]],
                 ["Read", ["read", "view"]], ["Bash", ["bash", "shell", "exec", "run"]],
                 ["Grep", ["grep", "glob", "search", "find", "list"]], ["WebFetch", ["web", "fetch"]]]
  for (const [claude, words] of rules) if (words.some((w) => name.includes(w))) return [claude, input]
  return [String(tool || "Tool"), input]
}

function recordTool(tool, args) {
  const [name, input] = claudeTool(tool, args)
  const id = "tool_" + Math.random().toString(16).slice(2, 14)
  record({ type: "assistant", message: { role: "assistant", content: [{ type: "tool_use", id, name, input }] } })
  record({ type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: id, content: "" }] } })
}

function recordPrompt(text) {
  if (text) record({ type: "user", message: { role: "user", content: String(text).slice(0, 8000) } })
}

function send(event, detail) {
  if (!ACTIVE) return
  let text = clip(detail)
  let body = JSON.stringify({ agent: "opencode", event, detail: text, t: TOKEN })
  // The terminal caps notification bodies at 255 bytes; emoji take four each.
  while (Buffer.byteLength(body) > 250 && text) {
    text = Array.from(text).slice(0, -1).join("")
    body = JSON.stringify({ agent: "opencode", event, detail: text, t: TOKEN })
  }
  for (const path of [process.env.GHOSTTY_EXTREME_AGENT_TTY, "/dev/tty"]) {
    if (!path) continue
    try {
      const fd = openSync(path, "a")
      writeSync(fd, `\x1b]777;notify;ghostty-extreme://agent;${body}\x07`)
      closeSync(fd)
      return
    } catch {}
  }
}

function toolDetail(tool, args) {
  const a = args || {}
  const arg = a.command || a.filePath || a.file_path || a.path || a.url || a.pattern || ""
  return arg ? `${tool}: ${arg}` : tool
}

export const GhosttyExtreme = async () => {
  if (!ACTIVE) return {}
  send("session_start", "")
  return {
    event: async ({ event }) => {
      const p = event.properties || {}
      switch (event.type) {
        case "session.idle":
          send("stop", "")
          break
        case "session.status":
          if (p.status && p.status.type === "busy") send("tool_complete", "")
          break
        case "session.error":
          send("stop_failure", (p.error && (p.error.message || p.error.name)) || "")
          break
        case "permission.asked":
        case "permission.updated":
          send("permission_request", p.title || p.permission || p.type || "")
          break
        case "question.asked":
          send("input_needed", "Waiting for your answer")
          break
      }
    },
    "chat.message": async (input, output) => {
      const parts = (output && output.parts) || []
      const text = parts.filter((part) => part.type === "text" && !part.synthetic).map((part) => part.text).join(" ")
      if (text) { send("prompt_submit", text); recordPrompt(text) }
    },
    "tool.execute.after": async (input) => {
      send("tool_complete", toolDetail(input.tool, input.args))
      recordTool(input.tool, input.args)
    },
  }
}
