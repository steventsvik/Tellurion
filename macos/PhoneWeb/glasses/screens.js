// What's on the glasses for a given state: a plain description of the page (containers,
// their place, their text), which glass.js turns into calls. Nothing here talks to the
// glasses, so every screen can be checked without them.
//
// There are two shapes. Browsing is Tellurion's window through the lens: the sidebar on
// the left (the projects with their tabs, the orchestrators, Tools) and a short look at
// the chosen row on the right. Going into a row takes the whole display: a title line,
// a body, a line of hints. Every such screen (a tab's terminal, the orchestrator, Tools
// and its pages) has that one shape, so moving between them only changes text.
//
// The input goes to a container nobody sees: one space, as big as the display. Text that
// fits its container bounces on every swipe, and a container that takes the input would
// bounce with what it shows; this one has nothing to show. (The glasses' own list keeps
// its highlight to itself until a tap, so nothing could follow it.)
//
// Text has one brightness per container, so a list is two containers on top of each
// other: the rows that need you and the cursor in a bright one, the rest in a dimmer one.

import { readable, cleanScreen } from "./clean.js";
import {
  LINE_PX, MAX_TEXT_BYTES, clip, clipBytes, elided, expectedFit, fitLine, head, inner, paginate, rule, rulerRows, safe, textWidth, wrap,
} from "./fit.js";
import { agentAge, agentById, groups, isAgent, kindName, marks, needsYou, sidebarRows, stateWords, summary } from "./model.js";

/// Takes every tap and swipe; shows nothing.
export const EVT = { id: 1, name: "evt", x: 0, y: 0, w: 576, h: 288, pad: 0 };
// Browsing.
export const SIDE = { id: 2, name: "side", x: 0, y: 0, w: 176, h: 288, border: 1, borderColor: 5 };
export const SIDE_HI = { id: 3, name: "sidehi", x: 1, y: 1, w: 174, h: 286 };
export const HEAD = { id: 4, name: "head", x: 175, y: 0, w: 401, h: 38, border: 1, borderColor: 5 };
export const PANE = { id: 5, name: "pane", x: 175, y: 37, w: 401, h: 214, border: 1, borderColor: 5 };
export const FOOT = { id: 7, name: "foot", x: 175, y: 250, w: 401, h: 38, border: 1, borderColor: 5 };
/// Lines in a body, and how many of them the box at its bottom takes.
export const PANE_LINES = 7;
export const BOX_LINES = 3;
/// Over the body's last lines, which are left empty while it has something to say.
export const BOX = { id: 6, name: "box", x: 176, y: PANE.y + 1 + (PANE_LINES - BOX_LINES) * LINE_PX, w: 399, h: BOX_LINES * LINE_PX + 8 };
// Inside a row: the whole display.
export const TOP = { id: 2, name: "top", x: 0, y: 0, w: 576, h: 38, border: 1, borderColor: 5 };
export const BODY_HI = { id: 3, name: "bodyhi", x: 1, y: 38, w: 574, h: 212 };
export const BODY = { id: 4, name: "body", x: 0, y: 37, w: 576, h: 214, border: 1, borderColor: 5 };
export const FULL_BOX = { id: 5, name: "box", x: 1, y: BOX.y, w: 574, h: BOX.h };
export const HINTS = { id: 6, name: "foot", x: 0, y: 250, w: 576, h: 38, border: 1, borderColor: 5 };
export const FULL_LINES = PANE_LINES;
/// The sidebar's lines: the name on top, the rows, the usage meters at the bottom.
export const SIDE_ROWS = 8;
const SIDE_WIDTH = inner(SIDE.w, 4, 1);
const PANE_WIDTH = inner(PANE.w, 4, 1);
export const FULL_WIDTH = inner(BODY.w, 4, 1);
/// How long the last screen stays up, dimmed, before "Can't reach your Mac".
export const LOST_GRACE = 10_000;

export const HINT_PROMPT = "tap allow · 2×tap deny · swipe later";
export const HINT_SEND = "tap send · 2×tap cancel";
export const HINT_CONFIRM = "tap yes · 2×tap no";

const GLYPH = { permission: "●", input: "○", failed: "▲", done: "★", working: "▶", ready: "□" };
const CURSOR = "> ";
/// As wide as the cursor.
const NO_CURSOR = "   ";

/// What the glasses' own menu (tap, then hold) offers, for the tab you're on or in.
export const OS_MENU = [
  { id: 1, name: "Talk", action: "talk" },
  { id: 2, name: "Press Enter", action: "key:enter" },
  { id: 3, name: "Press Esc", action: "key:escape" },
  { id: 4, name: "Press Ctrl-C", action: "key:ctrl-c" },
  { id: 5, name: "Latest output", action: "output" },
  { id: 6, name: "Display check", action: "ruler" },
];

/// What the orchestrator's screen offers without a word said.
export const ORCH_ACTIONS = [
  { id: "stop", text: "Stop", ask: "Stop the orchestrator?" },
  { id: "go", text: "Carry on", ask: "Carry on with the goal?" },
  { id: "wire", text: "Wire all", ask: "Wire every agent in this project?" },
  { id: "clear", text: "Clear", ask: "Clear its goal and log?" },
];

export const topScreen = (ui) => ui.stack[ui.stack.length - 1] ?? null;

// MARK: Rows

export function currentRow(ui, model) {
  const rows = sidebarRows(model, ui.folded);
  return rows.find((row) => row.id === ui.sel) ?? rows[0];
}

function groupNeeds(group) {
  return group.panes.filter(needsYou).length;
}

function glyphOf(pane) {
  if (!isAgent(pane)) return "$";
  return pane.act === "done" && !pane.unseen ? "☆" : GLYPH[pane.act] ?? GLYPH.ready;
}

/// A row's words, without its place in the list: "● Ada 1m", "▽ shop", "◆ Orchestrator".
export function rowLabel(row, model, now) {
  switch (row.kind) {
    case "group": {
      const needs = groupNeeds(row.group);
      return (row.folded ? "▷ " : "▽ ") + clip(row.group.name, 24) + (row.folded && needs ? " ●" + needs : "");
    }
    case "orch": return "◆ Orchestrator";
    case "tools": return "◇ Tools";
    default: {
      const pane = row.pane;
      const time = pane.act === "working" || needsYou(pane) ? agentAge(model, pane, now) : "";
      return glyphOf(pane) + " " + clip(pane.name, 24) + (time ? " " + time : "");
    }
  }
}

/// Whether a row is drawn bright: it needs you, or it's folded over one that does.
export function rowNeedsYou(row) {
  if (row.kind === "pane") return needsYou(row.pane);
  return row.kind === "group" && row.folded && groupNeeds(row.group) > 0;
}

function resetIn(seconds) {
  if (!(seconds > 0)) return "";
  if (seconds < 3600) return Math.max(1, Math.round(seconds / 60)) + "m";
  if (seconds < 86400) return Math.floor(seconds / 3600) + "h " + Math.floor((seconds % 3600) / 60) + "m";
  return Math.floor(seconds / 86400) + "d";
}

/// "5h 42% · Wk 61%": the first subscription's meters, for the sidebar's last line.
export function usageLine(model) {
  const entry = model.tools?.usage?.[0];
  if (!entry || !Array.isArray(entry.windows)) return "";
  return entry.windows.map((window) => window.label + " " + window.pct + "%").join(" · ");
}

/// A list as two layers of text, `count` lines of it around the chosen row. `rows`:
/// [{ text, hi }]; `at`: the chosen one. Returns { bright, dim, first } as lines.
function layers(rows, at, count, width) {
  const first = Math.min(Math.max(0, at - Math.floor(count / 2)), Math.max(0, rows.length - count));
  const bright = [];
  const dim = [];
  rows.slice(first, first + count).forEach((row, index) => {
    const indent = row.indent ? "  " : "";
    const words = indent + fitLine(row.text, width - 15 - (indent ? 10 : 0));
    const chosen = first + index === at;
    bright.push(row.hi ? (chosen ? CURSOR : NO_CURSOR) + words : chosen ? CURSOR.trimEnd() : "");
    dim.push(row.hi ? "" : NO_CURSOR + words);
  });
  return { bright, dim, first };
}

const joined = (lines) => { const kept = [...lines]; while (kept.length > 1 && kept[kept.length - 1] === "") kept.pop(); return kept.join("\n"); };

/// The sidebar's two layers of text: { bright, dim, first } with the rows around the
/// chosen one when there are more than fit.
export function sidebarText(ui, model, now) {
  const rows = sidebarRows(model, ui.folded);
  const at = Math.max(0, rows.findIndex((row) => row.id === ui.sel));
  const list = layers(rows.map((row) => ({
    text: rowLabel(row, model, now), hi: rowNeedsYou(row), indent: row.kind !== "group" && row.kind !== "tools",
  })), at, SIDE_ROWS, SIDE_WIDTH);
  // Arrows after the name say there are rows above or below the ones showing.
  const beyond = (list.first > 0 ? "↑" : "") + (list.first + SIDE_ROWS < rows.length ? "↓" : "");
  const bright = ["TELLURION" + (model.needs > 0 ? " ●" + model.needs : "") + (beyond ? " " + beyond : ""), ...list.bright];
  const dim = ["", ...list.dim];
  const usage = fitLine(usageLine(model), SIDE_WIDTH);
  if (usage) {
    while (dim.length < SIDE_ROWS + 1) dim.push("");
    dim.push(usage);
  }
  return { bright: joined(bright), dim: joined(dim), first: list.first };
}

// MARK: A tab's terminal

/// The Mac's text for a pane's screen, `before` lines back; null while it's on its way.
function screenFor(model, id, before) {
  const tail = model.tail;
  if (tail && tail.id === id && (tail.gone || (tail.src === "screen" && tail.before === before))) return tail;
  return before === 0 ? model.screens[id] ?? null : null;
}

export function paneTitle(model, pane, now) {
  if (!isAgent(pane)) return [pane.name, "terminal"].join(" · ");
  const time = pane.act === "working" || needsYou(pane) ? agentAge(model, pane, now) : "";
  // Its kind goes last: when the line is too long, that's what's cut.
  return [pane.name, stateWords(pane) + (time ? " " + time : ""), ...marks(pane), kindName(pane)].join(" · ");
}

/// A pane's screen as lines to read, `width` wide: cleaned of a terminal's furniture and
/// wrapped. { lines, more, raw } with `raw` the lines the Mac sent, for asking further back.
export function terminalLines(model, id, before, width) {
  const screen = screenFor(model, id, before);
  if (!screen) return { lines: ["..."], more: false, raw: 0 };
  if (screen.gone) return { lines: ["This tab has closed."], more: false, raw: 0 };
  // At its end, an agent's own last words stand in for a screen that's mostly furniture.
  const clean = before === 0 ? readable(screen.text, screen.ans) : cleanScreen(screen.text);
  const lines = clean.flatMap((line) => wrap(line, width));
  const empty = before > 0 ? "Nothing further back." : "Nothing on its screen yet.";
  return { lines: lines.length ? lines : [empty], more: screen.more === true, raw: screen.text ? screen.text.split("\n").length : 0 };
}

/// The lines showing of `lines` when `off` back from the end (or down from the start).
export function visible(lines, off, shown, fromEnd = true) {
  const most = Math.max(0, lines.length - shown);
  const at = Math.min(Math.max(0, off), most);
  const from = fromEnd ? Math.max(0, lines.length - shown - at) : at;
  return { most, at, lines: lines.slice(from, from + shown) };
}

/// The agent whose permission prompt is on show: the one whose terminal you're in, while
/// it's at its end and the prompt hasn't been put off or just been answered from here.
export function shownPrompt(ui, model) {
  const screen = topScreen(ui);
  if (!screen || screen.name !== "term" || screen.before > 0 || screen.off > 0) return null;
  const pane = agentById(model, screen.id);
  if (!pane || !isAgent(pane) || pane.act !== "permission" || typeof pane.prompt !== "string" || !pane.prompt) return null;
  return ui.answered.includes(pane.prompt) || screen.later === pane.prompt ? null : pane;
}

/// What a tap in a tab's terminal offers: [{ id, text }].
export function menuItems(pane) {
  if (!pane || !isAgent(pane)) return [];
  const items = [{ id: "talk", text: "Talk" }];
  // Keys are for an agent that isn't asking permission: that's answered as a prompt.
  if (pane.act !== "permission") {
    for (const [key, text] of [["enter", "Enter"], ["escape", "Esc"], ["ctrl-c", "Ctrl-C"], ["up", "Up"], ["down", "Down"], ["tab", "Tab"], ["y", "y"], ["n", "n"]]) {
      items.push({ id: "key:" + key, text });
    }
  }
  items.push({ id: "output", text: "Latest output" });
  return items;
}

/// A menu as lines of words, the chosen one in brackets, showing the line it's on.
function menuLines(items, chosen, lines, width) {
  const packed = [""];
  let line = 0;
  let chosenLine = 0;
  for (const item of items) {
    const word = item.id === chosen ? "[" + item.text + "]" : item.text;
    const together = packed[line] ? packed[line] + "   " + word : word;
    // Room is kept for the brackets wherever they are, so the words don't move with them.
    if (packed[line] && textWidth(together) + (item.id === chosen ? 0 : textWidth("[]")) > width) { line += 1; packed.push(word); } else { packed[line] = together; }
    if (item.id === chosen) chosenLine = line;
  }
  const first = Math.min(Math.max(0, chosenLine - lines + 1), Math.max(0, packed.length - lines));
  return packed.slice(first, first + lines);
}

function voiceBox(voice, width) {
  const who = voice.target.kind === "home" ? "Tellurion" : voice.target.name;
  const lines = BOX_LINES - 1;
  switch (voice.phase) {
    case "listening":
      return { lines: ["Listening... → " + who, ...wrap(voice.text || "Speak now.", width).slice(-(lines - 1))], hint: voice.via === "hold" ? "let go when you're done" : "tap done · 2×tap cancel" };
    case "waiting":
      return { lines: ["One moment... → " + who, ...wrap(voice.text, width).slice(-(lines - 1))], hint: "2×tap cancel" };
    case "heard":
      return { lines: head("Heard, for " + who + ": " + voice.text, lines, width).split("\n"), hint: HINT_SEND };
    default:
      return { lines: head("Not heard: " + (voice.error || "didn't catch that."), lines, width).split("\n"), hint: "tap back" };
  }
}

/// A permission prompt or a question, as the box shows it.
function askingBox(pane, width, inside) {
  if (pane.act === "permission") {
    const lines = head("● Allow?  " + (pane.detail || "It didn't say what for. Look on your Mac."), BOX_LINES - 1, width).split("\n");
    return { lines, hint: inside ? HINT_PROMPT : null };
  }
  return { lines: head("○ Asks: " + pane.detail, BOX_LINES - 1, width).split("\n"), hint: null };
}

// MARK: Browsing: a short look at the chosen row

function count(n, one, many) {
  return n + " " + (n === 1 ? one : many);
}

/// A project at a glance: where it is, who's in it, its orchestrator, checks and servers.
export function groupLines(model, group, width = PANE_WIDTH) {
  const path = group.path ? elided(group.path, width) ?? group.path : group.panes.length ? "No folder yet" : "No tabs open";
  const lines = [path];
  const agents = group.panes.filter(isAgent);
  const needs = groupNeeds(group);
  const terminals = group.panes.length - agents.length;
  const who = [count(agents.length, "agent", "agents")];
  if (needs) who.push(needs === 1 ? "1 needs you" : needs + " need you");
  if (terminals) who.push(count(terminals, "terminal", "terminals"));
  lines.push(who.join(" · "));
  if (group.orch) {
    lines.push("Orchestrator: " + (group.orch.status || "Not started"));
    if (group.orch.goal) lines.push("Goal: " + group.orch.goal);
  }
  const failed = group.panes.filter((pane) => pane.check?.s === "failed");
  const running = group.panes.filter((pane) => pane.check?.s === "running");
  if (failed.length) lines.push("Check failed: " + failed.map((pane) => pane.name + (pane.check.sum ? " (" + pane.check.sum + ")" : "")).join(", "));
  else if (running.length) lines.push("Checking: " + running.map((pane) => pane.name).join(", "));
  else if (group.panes.some((pane) => pane.check?.s === "passed")) lines.push("Checks passed");
  for (const server of model.tools?.servers ?? []) {
    if (server.proj === group.id) lines.push("Server: " + server.url);
  }
  return lines;
}

/// Tools at a glance: what the Mac's sidebar and tools have to say, the ones with something first.
export function toolsLines(model, now) {
  const tools = model.tools;
  if (!tools) return ["..."];
  const said = [];
  const quiet = [];
  for (const entry of tools.usage ?? []) {
    const windows = (entry.windows ?? []).map((window) => {
      const left = typeof window.resets === "number" ? resetIn(window.resets - (now / 1000 + model.skew)) : "";
      return window.label + " " + window.pct + "%" + (left ? " (" + left + ")" : "");
    });
    said.push(entry.name + ": " + windows.join(" · "));
  }
  if (!(tools.usage ?? []).length) quiet.push("No usage numbers yet");
  for (const server of tools.servers ?? []) said.push("Server: " + server.url + (server.name ? " · " + server.name : ""));
  if (!(tools.servers ?? []).length) quiet.push("No servers running");
  if (tools.review > 0) said.push("Review: " + tools.review + " waiting"); else quiet.push("Nothing to review");
  if ((tools.checks ?? []).length) said.push("Check failed: " + tools.checks.join(", ")); else quiet.push("No failed checks");
  for (const budget of tools.budgets ?? []) said.push("Budget: " + budget.name + " at " + budget.pct + "%");
  if (tools.conflicts > 0) said.push(count(tools.conflicts, "conflict", "conflicts") + " between agents"); else quiet.push("No conflicts");
  return [...said, ...quiet];
}

/// The orchestrator's state in a few words: who it waits on, or what the Mac says.
export function orchestratorStatus(project) {
  const waiting = (project.members ?? []).filter((member) => member.act === "permission" || member.act === "input");
  if (waiting.length) return "Waiting on you: " + waiting.map((member) => member.name).join(", ");
  return project.status || "Not started";
}

/// The chosen row in a few lines: { title, lines, pane } with `lines` already wrapped.
/// For a tab that's what it was asked to do and the last clean lines of its screen.
export function preview(ui, model, now) {
  const row = currentRow(ui, model);
  const wrapped = (lines) => lines.flatMap((line) => wrap(line, PANE_WIDTH));
  switch (row.kind) {
    case "group":
      return { row, title: row.group.name + " · project", lines: wrapped(groupLines(model, row.group)) };
    case "orch": {
      const project = row.project;
      const lines = [orchestratorStatus(project)];
      if (project.goal) lines.push("Goal: " + project.goal);
      if (project.says) lines.push("Says: " + project.says);
      const team = (project.members ?? []).map((member) => member.name).join(", ");
      if (team) lines.push("Team: " + team);
      return { row, title: "Orchestrator · " + row.group.name, lines: wrapped(lines) };
    }
    case "tools":
      return { row, title: "Tools · " + summary(model), lines: wrapped(toolsLines(model, now)) };
    default: {
      const pane = row.pane;
      const found = terminalLines(model, pane.id, 0, PANE_WIDTH).lines;
      const task = isAgent(pane) && pane.task ? [fitLine("Task: " + pane.task, PANE_WIDTH), ""] : [];
      return { row, title: paneTitle(model, pane, now), lines: found, lead: task, pane };
    }
  }
}

// MARK: The orchestrator's screen

/// Its rows, top to bottom: whoever asks for permission, the goal, the team, the latest.
/// [{ id, text, hi }].
export function orchestratorRows(model, project) {
  const rows = [];
  const members = project.members ?? [];
  const live = (member) => agentById(model, member.id);
  for (const member of members) {
    const pane = live(member);
    if (pane && pane.act === "permission" && pane.prompt) rows.push({ id: "ask:" + member.id, text: "● " + member.name + " asks: " + (pane.detail || "permission") + " - tap to open", hi: true });
  }
  rows.push({ id: "goal", text: project.goal ? "Goal: " + project.goal : "No goal yet. Hold to give it one.", hi: false });
  for (const member of members) {
    const pane = live(member) ?? { act: member.act, agent: true };
    const doing = member.detail || pane.detail || pane.task || stateWords(pane);
    rows.push({ id: "m:" + member.id, text: [glyphOf(pane) + " " + member.name, member.role, doing].filter(Boolean).join(" · "), hi: needsYou(pane) });
  }
  if (!members.length) rows.push({ id: "none", text: "Nobody is wired yet.", hi: false, still: true });
  rows.push({ id: "latest", text: project.says ? "Says: " + project.says : project.last ? "Last: " + project.last : "Nothing in its log yet.", hi: Boolean(project.says) });
  if (project.says && project.last) rows.push({ id: "last", text: "Last: " + project.last, hi: false, still: true });
  return rows;
}

/// The orchestrator's log, oldest first, wrapped.
export function logLines(project) {
  const lines = (project.log ?? []).flatMap((entry) => wrap(entry, FULL_WIDTH));
  return lines.length ? lines : ["Nothing in its log yet."];
}

// MARK: Tools

/// The Mac's tools, in its order: [{ id, name, section, page, sum }].
export function toolList(model) {
  return Array.isArray(model.tools?.list) ? model.tools.list.filter((tool) => tool && typeof tool.id === "string") : [];
}

/// The page the Mac sent for a tool, or null while it's on its way.
export function toolPage(model, id) {
  return model.toolpage && model.toolpage.id === id ? model.toolpage : null;
}

export function pageRows(page) {
  return Array.isArray(page?.rows) ? page.rows.filter((row) => row && typeof row.id === "string") : [];
}

// MARK: The page

function text(place, content, color = 4, extra = {}) {
  return { ...place, type: "text", text: clipBytes(safe(content), MAX_TEXT_BYTES), color, capture: false, ...extra };
}

const catcher = () => ({ ...EVT, type: "text", text: " ", color: 0, capture: true });

/// A screen that takes the whole display. `bright` and `dim` are the body's two layers
/// (lines), `box` what its last lines say instead ({ lines }), `hint` the gestures.
function full(key, { title, bright = [], dim = [], box = null, hint = "" }, options = {}) {
  const low = options.dim;
  const room = box ? FULL_LINES - BOX_LINES : FULL_LINES;
  const boxText = box ? [rule(FULL_WIDTH), ...box.lines].slice(0, BOX_LINES).join("\n") : "";
  return {
    key,
    scene: (low ? "dim " : "") + key,
    menu: OS_MENU.map(({ id, name }) => ({ id, name })),
    containers: [
      catcher(),
      text(TOP, fitLine(low ? "Reconnecting..." : title, FULL_WIDTH), low ? 1 : 4, { rank: 1 }),
      text(BODY_HI, joined(bright.slice(0, room)), low ? 1 : 4, { rank: 0 }),
      text(BODY, joined(dim.slice(0, room)), low ? 1 : 3, { rank: 3 }),
      text(FULL_BOX, boxText, low ? 1 : 4, { rank: 2 }),
      text(HINTS, fitLine(hint, FULL_WIDTH), low ? 1 : 2, { rank: 4 }),
    ],
  };
}

function counted(title, index, total) {
  return total > 1 ? fitLine(title, FULL_WIDTH - 60) + " " + (index + 1) + "/" + total : title;
}

function connection(model, now) {
  const plainPage = (key, title, body) => full(key, { title, dim: wrap(body, FULL_WIDTH) });
  switch (model.link) {
    case "boot": return plainPage("boot", "Tellurion", "Starting...");
    case "connecting": return plainPage("connecting", "Tellurion", "Connecting to your Mac...");
    case "pairing":
      return plainPage("pairing", "Pair with your Mac", "Code  " + model.pairCode + "\n\nOn your Mac: Tellurion > Phone.\nApprove it if the number there is the same.");
    case "unpaired":
      return plainPage("unpaired", "Not paired", (model.linkNote ? model.linkNote + "\n\n" : "")
        + "On your Mac: Tellurion > Phone > Glasses > Pair glasses.\nOr scan the QR there with the Even app.");
    case "off": return plainPage("off", "Glasses are off", "Turn on Glasses in Tellurion's settings on your Mac.");
    case "nomac": return plainPage("nomac", "No Mac set", "This build wasn't made for a Mac's address.\nMake it again from Tellurion > Phone > Glasses.");
    case "lost":
      if (now - model.lostAt < LOST_GRACE) return null;
      return plainPage("unreachable", "Can't reach your Mac", "It's asleep or offline, or Tailscale is off on this phone.\n\nTrying again by itself.");
    default: return null;
  }
}

/// An agent's last answer, a page at a time.
export function outputPages(model, id) {
  const tail = model.tail && model.tail.id === id && model.tail.src !== "screen" ? model.tail.text : "";
  return paginate(cleanScreen(tail).join("\n") || "Nothing yet.", FULL_LINES, FULL_WIDTH);
}

/// Lines without the empty ones they start with.
function fromFirstWord(lines) {
  const first = lines.findIndex((line) => line.trim());
  return first > 0 ? lines.slice(first) : lines;
}

/// The hints for a screen: only the gestures that do something there.
function hints(parts) {
  return parts.filter(Boolean).join(" · ");
}

function terminalScreen(ui, model, now, screen, options) {
  const pane = agentById(model, screen.id);
  const flash = ui.flash?.text;
  if (!pane) return full("term", { title: "Closed", dim: ["This tab has closed."], hint: "2×tap back" }, options);
  const agent = isAgent(pane);
  let box = null;
  if (ui.voice) box = voiceBox(ui.voice, FULL_WIDTH);
  else if (screen.menu) box = { lines: menuLines(menuItems(pane), screen.menu.sel, BOX_LINES - 1, FULL_WIDTH), hint: "swipe choose · tap do · 2×tap close" };
  else if (shownPrompt(ui, model)) box = askingBox(pane, FULL_WIDTH, true);
  else if (agent && pane.act === "input" && pane.detail && screen.before === 0 && screen.off === 0) box = askingBox(pane, FULL_WIDTH, true);
  const found = terminalLines(model, screen.id, screen.before, FULL_WIDTH);
  const shown = visible(found.lines, screen.off, box ? FULL_LINES - BOX_LINES : FULL_LINES);
  const back = screen.before > 0 || shown.at > 0;
  const canScroll = shown.most > 0 || found.more || back || Boolean(screen.later);
  const hint = flash ?? box?.hint ?? hints([canScroll && "swipe read", agent && "tap menu", agent && "hold talk", "2×tap back"]);
  return full("term", { title: (back ? "↑ " : "") + paneTitle(model, pane, now), dim: fromFirstWord(shown.lines), box, hint }, options);
}

function orchestratorScreen(ui, model, screen, options) {
  const group = groups(model).find((entry) => entry.id === screen.id);
  const project = group?.orch;
  if (!project) return full("orch", { title: "Orchestrator", dim: ["This project has no orchestrator now."], hint: "2×tap back" }, options);
  const rows = orchestratorRows(model, project);
  const at = Math.max(0, rows.findIndex((row) => row.id === screen.sel));
  const chosen = rows[at];
  const flash = ui.flash?.text;
  let box = null;
  if (ui.voice) box = voiceBox(ui.voice, FULL_WIDTH);
  else if (screen.confirm) box = { lines: [ORCH_ACTIONS.find((action) => action.id === screen.confirm)?.ask ?? "Sure?"], hint: HINT_CONFIRM };
  else if (screen.menu) box = { lines: menuLines(ORCH_ACTIONS, screen.menu.sel, BOX_LINES - 1, FULL_WIDTH), hint: "swipe choose · tap do · 2×tap close" };
  const list = layers(rows, at, box ? FULL_LINES - BOX_LINES : FULL_LINES, FULL_WIDTH);
  const tap = chosen.id === "goal" ? "tap actions" : chosen.id === "latest" ? "tap log" : chosen.still ? "" : "tap open";
  const hint = flash ?? box?.hint ?? hints(["swipe move", tap, "hold command", "2×tap back"]);
  return full("orch", { title: group.name + " · " + orchestratorStatus(project), bright: list.bright, dim: list.dim, box, hint }, options);
}

function logScreen(ui, model, screen, options) {
  const project = model.projects.find((entry) => entry.id === screen.id);
  const lines = project ? logLines(project) : ["This project has no orchestrator now."];
  const shown = visible(lines, screen.off, ui.voice ? FULL_LINES - BOX_LINES : FULL_LINES);
  const box = ui.voice ? voiceBox(ui.voice, FULL_WIDTH) : null;
  const hint = ui.flash?.text ?? box?.hint ?? hints([shown.most > 0 && "swipe read", project && "hold command", "2×tap back"]);
  return full("log", { title: (shown.at > 0 ? "↑ " : "") + "Orchestrator log", dim: shown.lines, box, hint }, options);
}

function toolsScreen(ui, model, screen, options) {
  const tools = toolList(model);
  if (!tools.length) return full("tools", { title: "Tools", dim: [model.tools ? "No tools are turned on." : "..."], hint: "2×tap back" }, options);
  const at = Math.max(0, tools.findIndex((tool) => tool.id === screen.sel));
  const tool = tools[at];
  const list = layers(tools.map((entry) => ({ text: entry.name + (entry.page ? "" : " → Mac"), hi: entry.hi === true })), at, FULL_LINES - BOX_LINES, FULL_WIDTH);
  const about = [tool.section, tool.sum || (tool.page ? "" : "Opens on your Mac")].filter(Boolean).join(" · ");
  const box = screen.confirm
    ? { lines: wrap("Open " + tool.name + " on your Mac?", FULL_WIDTH).slice(0, BOX_LINES - 1), hint: HINT_CONFIRM }
    : { lines: wrap(about, FULL_WIDTH).slice(0, BOX_LINES - 1), hint: null };
  const hint = ui.flash?.text ?? box.hint ?? hints(["swipe move", tool.page ? "tap open" : "tap open on Mac", "2×tap back"]);
  return full("tools", { title: counted("Tools", at, tools.length), bright: list.bright, dim: list.dim, box, hint }, options);
}

function toolScreen(ui, model, screen, options) {
  const tool = toolList(model).find((entry) => entry.id === screen.id);
  const page = toolPage(model, screen.id);
  const title = page?.title || tool?.name || "Tool";
  const flash = ui.flash?.text;
  if (!page) return full("tool", { title, dim: ["..."], hint: flash ?? "2×tap back" }, options);
  const rows = pageRows(page);
  const voice = page.voice ? "hold " + page.voice.hint : "";
  if (!rows.length) {
    const box = ui.voice ? voiceBox(ui.voice, FULL_WIDTH) : null;
    return full("tool", { title, dim: wrap(page.note || "Nothing here.", FULL_WIDTH), box, hint: flash ?? box?.hint ?? hints([voice, "2×tap back"]) }, options);
  }
  const at = Math.max(0, rows.findIndex((row) => row.id === screen.sel));
  const row = rows[at];
  const actions = Array.isArray(row.actions) ? row.actions : [];
  let box;
  if (ui.voice) box = voiceBox(ui.voice, FULL_WIDTH);
  else if (screen.confirm) box = { lines: wrap(actions.find((action) => action.id === screen.confirm)?.ask || "Sure?", FULL_WIDTH).slice(0, BOX_LINES - 1), hint: HINT_CONFIRM };
  else if (screen.menu) box = { lines: menuLines(actions.map((action) => ({ id: action.id, text: action.label })), screen.menu.sel, BOX_LINES - 1, FULL_WIDTH), hint: "swipe choose · tap do · 2×tap close" };
  else box = { lines: wrap(row.sub || page.note || "", FULL_WIDTH).slice(0, BOX_LINES - 1), hint: null };
  const list = layers(rows.map((entry) => ({ text: entry.text, hi: entry.hi === true })), at, FULL_LINES - BOX_LINES, FULL_WIDTH);
  const tap = row.open ? "tap open" : actions.length ? "tap actions" : "";
  const hint = flash ?? box.hint ?? hints([rows.length > 1 && "swipe move", tap, voice, "2×tap back"]);
  return full("tool", { title: counted(title, at, rows.length), bright: list.bright, dim: list.dim, box, hint }, options);
}

function outputScreen(ui, model, screen, options) {
  const agent = agentById(model, screen.id);
  const pages = outputPages(model, screen.id);
  const index = Math.min(Math.max(0, pages.length - 1 - screen.back), pages.length - 1);
  const hint = ui.flash?.text ?? hints([pages.length > 1 && "swipe read", "tap or 2×tap back"]);
  return full("output", { title: counted((agent?.name ?? "Agent") + " · latest output", index, pages.length), dim: pages[index].split("\n"), hint }, options);
}

/// The display check: rows that count their own characters, and what's expected to fit.
function rulerScreen(options) {
  const expected = "Expected to fit: n " + expectedFit("n") + " · M " + expectedFit("M") + " · i " + expectedFit("i");
  return full("ruler", { title: "Display check", dim: [...rulerRows(), expected], hint: "tap or 2×tap back" }, options);
}

/// Browsing: the sidebar, and a short look at the chosen row beside it.
function browse(ui, model, now, options) {
  const dim = options.dim;
  const sidebar = sidebarText(ui, model, now);
  const view = preview(ui, model, now);
  const row = view.row;
  const pane = view.pane;
  let box = null;
  if (ui.voice) box = voiceBox(ui.voice, PANE_WIDTH);
  else if (pane && isAgent(pane) && ((pane.act === "permission" && pane.prompt) || (pane.act === "input" && pane.detail))) box = askingBox(pane, PANE_WIDTH, false);
  const room = (box ? PANE_LINES - BOX_LINES : PANE_LINES) - (view.lead?.length ?? 0);
  // A tab shows the end of its screen; the rest read from the top.
  const lines = pane ? [...(view.lead ?? []), ...fromFirstWord(view.lines.slice(-Math.max(1, room)))] : view.lines.slice(0, room);
  const agent = pane && isAgent(pane);
  const tap = row.kind === "group" ? "tap " + (row.folded ? "unfold" : "fold") : "tap open";
  const hold = row.kind === "tools" ? "hold say" : row.kind === "pane" ? agent && "hold talk" : (row.kind === "orch" || row.group?.orch) && "hold talk";
  const hint = ui.flash?.text ?? box?.hint ?? hints(["swipe", tap, hold, "2×tap exit"]);
  const boxText = box ? [rule(PANE_WIDTH), ...box.lines].slice(0, BOX_LINES).join("\n") : "";
  return {
    key: "main",
    scene: (dim ? "dim " : "") + "main",
    menu: OS_MENU.map(({ id, name }) => ({ id, name })),
    containers: [
      catcher(),
      text(SIDE_HI, sidebar.bright, dim ? 1 : 4, { rank: 0 }),
      text(SIDE, sidebar.dim, dim ? 1 : 2, { rank: 5 }),
      text(HEAD, fitLine(dim ? "Reconnecting..." : view.title, PANE_WIDTH), dim ? 1 : 4, { rank: 1 }),
      text(BOX, boxText, dim ? 1 : 4, { rank: 2 }),
      text(PANE, joined(lines), dim ? 1 : 3, { rank: 3 }),
      text(FOOT, fitLine(hint, PANE_WIDTH), dim ? 1 : 2, { rank: 4 }),
    ],
  };
}

/// The page for a state. `ui` is input.js's state, `model` what the server said.
export function render(ui, model, now) {
  const blocked = connection(model, now);
  if (blocked) return blocked;
  // Lost a moment ago: what was there stays, dimmed, while it reconnects.
  const options = { dim: model.link !== "ok" };
  const screen = topScreen(ui);
  switch (screen?.name) {
    case "term": return terminalScreen(ui, model, now, screen, options);
    case "orch": return orchestratorScreen(ui, model, screen, options);
    case "log": return logScreen(ui, model, screen, options);
    case "tools": return toolsScreen(ui, model, screen, options);
    case "tool": return toolScreen(ui, model, screen, options);
    case "output": return outputScreen(ui, model, screen, options);
    case "ruler": return rulerScreen(options);
    default: return browse(ui, model, now, options);
  }
}

/// A list's two layers laid over each other, as lines.
function overlaid(bright, dim) {
  const [a, b] = [bright.split("\n"), dim.split("\n")];
  return Array.from({ length: Math.max(a.length, b.length) }, (_, i) => {
    const [top, under] = [a[i] ?? "", b[i] ?? ""];
    return top.trim() === ">" ? "> " + under.trimStart() : top || under;
  });
}

/// The page as plain text, for the phone's screen and for reading in tests.
export function plain(description) {
  const by = (name) => description.containers.find((container) => container.name === name)?.text ?? "";
  if (description.key === "main") {
    const side = overlaid(by("sidehi"), by("side"));
    return [...side, "", by("head"), by("pane"), by("box"), by("foot")].filter((part, index) => part || index <= side.length).join("\n");
  }
  return [by("top"), ...overlaid(by("bodyhi"), by("body")), by("box"), by("foot")].filter(Boolean).join("\n");
}
