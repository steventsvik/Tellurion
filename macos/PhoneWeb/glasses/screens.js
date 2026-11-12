// What's on the glasses for a given state: a plain description of the page (containers,
// their place, their text), which glass.js turns into calls. Nothing here talks to the
// glasses, so every screen can be checked without them.
//
// The page is always the same two text containers: a line on top and a body under it that
// takes the input. Text in place can be changed without a flicker; a native list can't be
// changed at all without rebuilding the page, and comes back with its highlight on the
// first item. So menus are drawn as text with a ">" before the chosen row, and the choice
// is kept here. `MENU_STYLE = "native"` draws them as the glasses' own lists instead.

import { LINE_CHARS, MAX_ITEM_BYTES, MAX_TEXT_BYTES, clip, clipBytes, head, paginate, safe } from "./fit.js";
import { agentAge, agentById, marks, pendingPrompts, stateWords, summary } from "./model.js";

export const MENU_STYLE = "cursor";

export const HEAD = { id: 1, name: "head", x: 0, y: 0, w: 576, h: 44 };
export const BODY = { id: 2, name: "body", x: 0, y: 44, w: 576, h: 244 };
export const LIST = { id: 3, name: "list", x: 0, y: 44, w: 576, h: 244 };
/// Lines that fit in the body, on the careful side: more would make the glasses scroll
/// the text themselves and keep the swipes.
export const BODY_LINES = 7;
/// How long the last screen stays up, dimmed, before "Can't reach your Mac".
export const LOST_GRACE = 10_000;
export const HINT_PROMPT = "tap = allow · double-tap = deny\nscroll = later";
export const HINT_SEND = "tap = send · double-tap = cancel";

const GLYPH = { permission: "●", input: "○", failed: "▲", done: "★", working: "▶", ready: "□" };

// MARK: Rows and pages

/// One agent in a line: "● Ada: needs permission", "▶ Otto: working 3m", "★ Cy: done · check failed".
export function agentLine(model, agent, now) {
  const glyph = agent.act === "done" && !agent.unseen ? "☆" : GLYPH[agent.act] ?? GLYPH.ready;
  const time = agent.act === "working" || agent.act === "permission" || agent.act === "input" ? agentAge(model, agent, now) : "";
  const words = [stateWords(agent) + (time ? " " + time : ""), ...marks(agent)].join(" · ");
  return glyph + " " + clip(agent.name, 18) + ": " + words;
}

/// Home's rows: the agents as the server ordered them, then each project's orchestrator.
export function homeItems(model, now) {
  const rows = model.agents.slice(0, 17).map((agent) => ({ id: "a:" + agent.id, text: agentLine(model, agent, now) }));
  for (const project of model.projects.slice(0, 3)) {
    rows.push({ id: "o:" + project.id, text: "■ Orchestrator · " + clip(project.name, 16) + ": " + clip(project.status ?? "", 24) });
  }
  return rows;
}

/// What can be done with an agent. Allow and Deny only while it shows a prompt.
export function actionItems(agent) {
  const rows = [];
  if (agent?.act === "permission" && agent.prompt) {
    rows.push({ id: "allow", text: "Allow" }, { id: "deny", text: "Deny" });
  }
  rows.push({ id: "talk", text: "Talk to it" }, { id: "output", text: "Latest output" }, { id: "back", text: "Back" });
  return rows;
}

function tailFor(model, id) {
  return model.tail && model.tail.id === id ? model.tail.text : "";
}

/// An agent's screen as pages: its task, what it's waiting on, then its latest lines.
export function agentPages(model, agent) {
  const parts = [];
  if (agent.task) parts.push(head(agent.task, 2));
  if ((agent.act === "permission" || agent.act === "input") && agent.detail) parts.push("Waiting on: " + agent.detail);
  const extra = marks(agent);
  if (extra.length) parts.push(extra.join(" · "));
  const tail = tailFor(model, agent.id);
  if (tail) parts.push(tail);
  return paginate(parts.join("\n\n") || "Nothing yet.", BODY_LINES);
}

export function outputPages(model, id) {
  return paginate(tailFor(model, id) || "Nothing yet.", BODY_LINES);
}

export function orchestratorPages(project) {
  const parts = [];
  if (project.goal) parts.push("Goal: " + project.goal);
  parts.push(project.status || "Not started");
  for (const line of project.log ?? []) parts.push(line);
  return paginate(parts.join("\n"), BODY_LINES - 1).map((page) => page + "\ntap = talk");
}

/// A menu's rows as text, a ">" before the chosen one, showing the rows around it.
export function menuText(rows, selected) {
  if (!rows.length) return "";
  const at = Math.max(0, rows.findIndex((row) => row.id === selected));
  const first = Math.min(Math.max(0, at - Math.floor(BODY_LINES / 2)), Math.max(0, rows.length - BODY_LINES));
  return rows.slice(first, first + BODY_LINES)
    .map((row, index) => (first + index === at ? "> " : "   ") + clip(row.text, LINE_CHARS - 4))
    .join("\n");
}

// MARK: The page

function text(place, content, color = 4, capture = false) {
  return { ...place, type: "text", text: clipBytes(safe(content), MAX_TEXT_BYTES), color, capture };
}

function page(key, top, body, options = {}) {
  const color = options.dim ? 1 : 4;
  return { key, containers: [text(HEAD, clip(top, LINE_CHARS), color), text(BODY, body, color, true)] };
}

function menu(key, top, rows, selected, options = {}) {
  if (MENU_STYLE !== "native" || !rows.length) return page(key, top, menuText(rows, selected), options);
  const at = Math.max(0, rows.findIndex((row) => row.id === selected));
  return {
    key,
    containers: [
      text(HEAD, clip(top, LINE_CHARS), options.dim ? 1 : 4),
      { ...LIST, type: "list", items: rows.slice(0, 20).map((row) => clip(row.text, 60, MAX_ITEM_BYTES)), selected: at, capture: true },
    ],
  };
}

function counted(title, index, count) {
  return count > 1 ? clip(title, LINE_CHARS - 6) + " " + (index + 1) + "/" + count : title;
}

function clampPage(index, pages) {
  return Math.min(Math.max(0, index), pages.length - 1);
}

function connection(model, now) {
  switch (model.link) {
    case "boot": return page("boot", "Tellurion", "Starting...");
    case "connecting": return page("connecting", "Tellurion", "Connecting to your Mac...");
    case "pairing":
      return page("pairing", "Pair with your Mac", "Code  " + model.pairCode + "\n\nOn your Mac: Tellurion > Phone.\nApprove it if the number there is the same.");
    case "unpaired":
      return page("unpaired", "Not paired", (model.linkNote ? model.linkNote + "\n\n" : "")
        + "On your Mac: Tellurion > Phone > Glasses > Pair glasses.\nOr scan the QR there with the Even app.");
    case "off": return page("off", "Glasses are off", "Turn on Glasses in Tellurion's settings on your Mac.");
    case "nomac": return page("nomac", "No Mac set", "This build wasn't made for a Mac's address.\nMake it again from Tellurion > Phone > Glasses.");
    case "lost":
      if (now - model.lostAt < LOST_GRACE) return null;
      return page("unreachable", "Can't reach your Mac", "It's asleep or offline, or Tailscale is off on this phone.\n\nTrying again by itself.");
    default: return null;
  }
}

function voicePage(voice) {
  const who = voice.target.kind === "home" ? "Tellurion" : voice.target.name;
  switch (voice.phase) {
    case "listening":
      return page("voice", "Listening... → " + who,
        (voice.text ? head(voice.text, BODY_LINES - 2) : "Speak now.") + "\n\n"
        + (voice.via === "hold" ? "release = done" : "tap = done · double-tap = cancel"));
    case "waiting":
      return page("voice", "One moment... → " + who, voice.text ? head(voice.text, BODY_LINES - 1) : "");
    case "heard":
      return page("voice", "Send to " + who + "?", "Heard: " + head(voice.text, BODY_LINES - 2) + "\n\n" + HINT_SEND);
    default:
      return page("voice", "Not heard", head(voice.error || "Didn't catch that.", BODY_LINES - 2) + "\n\ntap = back");
  }
}

function promptPage(ui, model) {
  const agent = agentById(model, ui.prompt.id);
  const waiting = pendingPrompts(model).length;
  const top = "● " + clip(agent?.name ?? "Agent", 20) + " needs permission" + (waiting > 1 ? " (+" + (waiting - 1) + ")" : "");
  return page("prompt", top, head(agent?.detail || "It didn't say what for. Look on your Mac.", BODY_LINES - 3) + "\n\n" + HINT_PROMPT);
}

function basePage(ui, model, now, options) {
  const top = ui.stack[ui.stack.length - 1];
  const flash = ui.flash && now < ui.flash.until ? ui.flash.text : null;
  const agent = top.id ? agentById(model, top.id) : null;
  switch (top.name) {
    case "agent": {
      if (!agent) break;
      const pages = agentPages(model, agent);
      const index = clampPage(top.page, pages);
      const time = agentAge(model, agent, now);
      return page("agent", flash ?? counted(clip(agent.name, 18) + " · " + stateWords(agent) + (time ? " " + time : ""), index, pages.length),
        pages[index], options);
    }
    case "actions":
      if (!agent) break;
      return menu("actions", flash ?? clip(agent.name, 18) + " · " + stateWords(agent), actionItems(agent), top.sel, options);
    case "output": {
      if (!agent) break;
      const pages = outputPages(model, top.id);
      const index = clampPage(pages.length - 1 - top.back, pages);
      return page("output", flash ?? counted(clip(agent.name, 18) + " · output", index, pages.length), pages[index], options);
    }
    case "orch": {
      const project = model.projects.find((p) => p.id === top.id);
      if (!project) break;
      const pages = orchestratorPages(project);
      const index = clampPage(top.page, pages);
      return page("orch", flash ?? counted("Orchestrator · " + clip(project.name, 16), index, pages.length), pages[index], options);
    }
    default: break;
  }
  const rows = homeItems(model, now);
  if (!rows.length) return page("home", flash ?? summary(model), "Start an agent on your Mac and it shows here.\n\ndouble-tap = close", options);
  return menu("home", flash ?? summary(model), rows, ui.sel, options);
}

/// The page for a state. `ui` is input.js's state, `model` what the server said.
export function render(ui, model, now) {
  const blocked = connection(model, now);
  if (blocked) return blocked;
  // Lost a moment ago: what was there stays, dimmed, while it reconnects.
  const options = { dim: model.link !== "ok" };
  if (options.dim) {
    const shown = ui.voice ? voicePage(ui.voice) : ui.prompt ? promptPage(ui, model) : basePage(ui, model, now, options);
    const dimmed = shown.containers.map((container) => (container.type === "text" ? { ...container, color: 1 } : container));
    dimmed[0] = { ...dimmed[0], text: "Reconnecting..." };
    return { key: shown.key, containers: dimmed };
  }
  if (ui.voice) return voicePage(ui.voice);
  if (ui.prompt) return promptPage(ui, model);
  return basePage(ui, model, now, options);
}

/// The page as plain text, for the phone's screen and for reading in tests.
export function plain(description) {
  return description.containers.map((container) => (container.type === "list"
    ? container.items.map((item, index) => (index === container.selected ? "> " : "  ") + item).join("\n")
    : container.text)).join("\n");
}
