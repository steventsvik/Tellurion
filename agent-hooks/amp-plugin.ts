// Tellurion: live status for Amp in the sidebar. Installed by Tellurion as
// ~/.config/amp/plugins/tellurion.ts; does nothing outside Tellurion.
//
// Amp has no command hooks, so this plugin listens to its events and writes the same
// OSC 777 notification the other agents' hooks send to the terminal. It only observes:
// it never allows, rejects or changes a tool call.
import { appendFileSync, chmodSync, closeSync, mkdirSync, openSync, writeSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"

const ACTIVE = process.env.GHOSTTY_EXTREME_AGENT_EVENTS === "1"
const TOKEN = process.env.GHOSTTY_EXTREME_EVENT_TOKEN || ""

function clip(text: unknown): string {
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
const FEED = join(process.env.TELLURION_TEST_HOME || homedir(), ".ghostty-extreme", "feeds", `amp-${process.pid}.jsonl`)
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
      sendRaw({ agent: "amp", event: "transcript", detail: FEED, t: TOKEN })
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

function send(event: string, detail: unknown) {
  if (!ACTIVE) return
  let text = clip(detail)
  let body = JSON.stringify({ agent: "amp", event, detail: text, t: TOKEN })
  // The terminal caps notification bodies at 255 bytes; emoji take four each.
  while (Buffer.byteLength(body) > 250 && text) {
    text = Array.from(text).slice(0, -1).join("")
    body = JSON.stringify({ agent: "amp", event, detail: text, t: TOKEN })
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

function toolDetail(tool: unknown, input: any): string {
  const a = input && typeof input === "object" ? input : {}
  const arg = a.command || a.cmd || a.filePath || a.file_path || a.path || a.url || a.pattern || ""
  const name = typeof tool === "string" ? tool : (tool as any)?.name || ""
  return arg ? `${name}: ${arg}` : name
}

function promptText(message: any): string {
  if (typeof message === "string") return message
  const content = message?.content
  if (typeof content === "string") return content
  if (Array.isArray(content)) return content.filter((p: any) => p?.type === "text").map((p: any) => p.text).join(" ")
  return ""
}

export default (amp: any) => {
  if (!ACTIVE) return
  // Observers only: nothing here returns a decision.
  amp.on("session.start", async () => { send("session_start", "") })
  amp.on("agent.start", async (e: any) => { send("prompt_submit", promptText(e?.message)); recordPrompt(promptText(e?.message)) })
  amp.on("tool.result", async (e: any) => { send("tool_complete", toolDetail(e?.tool, e?.input)); recordTool(e?.tool?.name ?? e?.tool, e?.input) })
  amp.on("agent.end", async (e: any) => { send(e?.status === "error" ? "stop_failure" : "stop", "") })
}
