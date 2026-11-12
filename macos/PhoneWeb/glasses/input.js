// What a tap, a swipe or a spoken word does: where you are plus an event gives where you
// are next and, sometimes, a message for the Mac. Nothing here touches the glasses or
// the network, and no state is ever changed in place.
//
// You start out browsing: the sidebar, where a swipe moves through the rows. A tap goes
// into the chosen row, which then takes the whole display: a tab's terminal, a project's
// orchestrator, Tools. From there a tap can go further in (an agent from its
// orchestrator, a tool's page), and a double-tap always comes back out one level.
//
// The rules that matter:
// - Nothing is sent without a tap. Speech becomes text on the Mac and comes back here; it
//   goes to an agent or the orchestrator only after "tap send".
// - A permission answer carries the identity of the prompt that was on show, and isn't
//   sent at all if the Mac has since reported another one.
// - A prompt that has just come into view ignores taps for a moment, so a tap already on
//   its way can't allow it. It's only answered from inside its own agent's terminal.
// - Keys go only to a pane with an agent in it, and never while it asks for permission.
// - Anything that changes something on the Mac (a tool's action, opening a window there,
//   stopping the orchestrator) is asked about first, and only the tap that says yes sends it.
// - Double-tap while browsing closes the app the way the glasses' own menu expects.

import { agentById, isAgent, needsYou, pendingPrompts, promptPending, sidebarRows } from "./model.js";
import {
  BOX_LINES, FULL_LINES, FULL_WIDTH, OS_MENU, ORCH_ACTIONS, currentRow, logLines, menuItems, orchestratorRows, outputPages, pageRows,
  shownPrompt, terminalLines, toolList, toolPage, topScreen, visible,
} from "./screens.js";

/// How long a prompt that just came into view ignores taps.
export const PROMPT_GUARD = 1200;
export const FLASH = 3000;
/// Lines of a pane's screen asked for at a time, and of an agent's last answer.
export const SCREEN_LINES = 40;
export const TAIL_LINES = 30;
/// How far back a terminal can be read, in lines.
export const MAX_BEFORE = 2000;
/// A minute of listening at most, and this long for the Mac to answer after it.
export const LISTEN_LIMIT = 60_000;
export const HEARD_PATIENCE = 10_000;
/// The keys an agent's pane can be sent. The Mac has the same list.
export const KEYS = ["enter", "escape", "ctrl-c", "up", "down", "tab", "y", "n"];
/// How deep going in can go.
const DEEPEST = 6;

export function createUI() {
  return {
    /// The chosen row of the sidebar, by id, so it stays put when the rows change; and where it was.
    sel: null,
    at: 0,
    /// Projects folded shut, by id.
    folded: [],
    /// What you've gone into, the last one showing; empty while browsing. Each is one of
    /// { name: "term", id, before, off, trail, menu, later }: a tab's terminal, how far back
    /// it's read, and the prompt put off with a swipe;
    /// { name: "orch", id, sel, menu, confirm }: a project's orchestrator;
    /// { name: "log", id, off }; { name: "tools", sel, confirm };
    /// { name: "tool", id, sel, menu, confirm }; { name: "output", id, back }; { name: "ruler" }.
    stack: [],
    /// The prompt on show and since when: { key, at }.
    seen: null,
    /// Prompts answered from here, by identity, until the Mac stops listing them.
    answered: [],
    /// { phase: "listening" | "waiting" | "heard" | "error", target, via, text, error, at }.
    voice: null,
    flash: null,
  };
}

const terminal = (id) => ({ name: "term", id, before: 0, off: 0, trail: [], menu: null, later: null });
const orchestrator = (id) => ({ name: "orch", id, sel: null, menu: null, confirm: null });

// MARK: Events from the glasses

/// What an event from the Even app means: { type, index } with type "click", "double",
/// "up", "down", "long", "release", "foreground", "background" or "abnormal"; { type:
/// "menu", id } for a row of the glasses' own menu; { type: "audio", pcm }; or null for
/// anything else. A click's type can arrive as 0 or missing.
export function normalizeEvent(event) {
  if (!event || typeof event !== "object") return null;
  if (event.audioEvent?.audioPcm) return { type: "audio", pcm: event.audioEvent.audioPcm };
  if (event.menuItemClickEvent && typeof event.menuItemClickEvent.itemID === "number") return { type: "menu", id: event.menuItemClickEvent.itemID };
  const source = event.listEvent ?? event.textEvent ?? event.sysEvent;
  if (!source || typeof source !== "object") return null;
  // A system event with no type is a click on some hosts, unless it carries something else.
  if (source === event.sysEvent && source.eventType == null && (source.imuData != null || source.systemExitReasonCode != null)) return null;
  const type = EVENT_TYPES[source.eventType ?? 0];
  if (!type) return null;
  const index = typeof source.currentSelectItemIndex === "number" ? source.currentSelectItemIndex : source === event.listEvent ? 0 : null;
  return index == null ? { type } : { type, index };
}

const EVENT_TYPES = {
  0: "click", 1: "up", 2: "down", 3: "double", 4: "foreground", 5: "background", 6: "abnormal", 7: "abnormal", 9: "long", 10: "release",
  CLICK_EVENT: "click", SCROLL_TOP_EVENT: "up", SCROLL_BOTTOM_EVENT: "down", DOUBLE_CLICK_EVENT: "double",
};

/// Drops repeats: a swipe within the cooldown of the last one, whichever way it went (one
/// swipe can be reported more than once), or one tap delivered on two channels.
export function createDebouncer(scrollGap = 300, tapGap = 150) {
  let last = { kind: "", at: -Infinity };
  return (event, now) => {
    const scroll = event.type === "up" || event.type === "down";
    const gap = scroll ? scrollGap : event.type === "click" || event.type === "double" ? tapGap : 0;
    if (!gap) return true;
    const kind = scroll ? "scroll" : event.type;
    if (kind === last.kind && now - last.at < gap) return false;
    last = { kind, at: now };
    return true;
  };
}

// MARK: Speech at Tools

/// What a few spoken words mean on the sidebar's Tools row, matched whole and nothing
/// looser: "allow", "deny", "next", "back", "orchestrator", "open <name>". Else null.
export function spokenCommand(heard) {
  const words = String(heard ?? "").toLowerCase().replace(/[^a-z0-9 ]+/g, " ").trim().split(/\s+/).filter(Boolean);
  const said = words.join(" ");
  if (["allow", "deny", "next", "back", "orchestrator"].includes(said)) return { command: said };
  if (words[0] === "open" && words.length > 1 && words.length <= 5) return { command: "open", name: words.slice(1).join(" ") };
  return null;
}

function nameKey(name) {
  return String(name).toLowerCase().replace(/[^a-z0-9 ]+/g, " ").trim().replace(/\s+/g, " ");
}

// MARK: Getting around

const flash = (ui, text, now) => ({ ...ui, flash: { text, until: now + FLASH } });
const rowsOf = (ui, model) => sidebarRows(model, ui.folded);
const withTop = (ui, changes) => ({ ...ui, stack: [...ui.stack.slice(0, -1), { ...topScreen(ui), ...changes }] });
const pop = (ui) => ({ ...ui, stack: ui.stack.slice(0, -1) });

/// Goes into a screen. The same one twice in a row is once; too deep starts over from it.
function push(ui, screen) {
  const top = topScreen(ui);
  if (top && top.name === screen.name && top.id === screen.id) return ui;
  const stack = ui.stack.length >= DEEPEST ? [screen] : [...ui.stack, screen];
  return { ...ui, stack };
}

/// Moves through rows by id; from nothing chosen, the first counts as chosen. Rows that
/// only say something (`still`) are stepped over.
function moved(rows, selected, by) {
  const at = Math.max(0, rows.findIndex((row) => row.id === selected));
  let next = at;
  for (let to = at + by; to >= 0 && to < rows.length; to += by) {
    if (!rows[to].still) { next = to; break; }
  }
  return rows[next].id;
}

/// Chooses a pane's row in the sidebar wherever it is, unfolding its project.
function reveal(ui, model, paneID) {
  const project = agentById(model, paneID)?.proj?.id;
  const folded = ui.folded.filter((id) => id !== (project ?? "other"));
  return { ...ui, folded, sel: "p:" + paneID };
}

// MARK: Speech

/// Who speech is for with a sidebar row chosen; a line to show instead when it's nobody.
function rowTarget(row) {
  switch (row.kind) {
    case "tools": return { target: { kind: "home", id: "", name: "Tellurion" } };
    case "orch": return { target: { kind: "orch", id: row.project.id, name: "the orchestrator" } };
    case "group":
      // The Mac lists a project's orchestrator when it has one, or agents one could run.
      return row.group.orch ? { target: { kind: "orch", id: row.group.orch.id, name: "the orchestrator" } } : { refusal: "No agents in this project" };
    default:
      // Never into a pane with no agent: there it would run as a command.
      return isAgent(row.pane) ? { target: { kind: "agent", id: row.pane.id, name: row.pane.name } } : { refusal: "No agent there to talk to" };
  }
}

/// Who speech is for on the screen that's showing.
function voiceTarget(ui, model) {
  const screen = topScreen(ui);
  switch (screen?.name) {
    case undefined: return rowTarget(currentRow(ui, model));
    case "term": {
      const pane = agentById(model, screen.id);
      return pane && isAgent(pane) ? { target: { kind: "agent", id: pane.id, name: pane.name } } : { refusal: "No agent there to talk to" };
    }
    case "orch":
    case "log":
      return model.projects.some((project) => project.id === screen.id)
        ? { target: { kind: "orch", id: screen.id, name: "the orchestrator" } } : { refusal: "No orchestrator here now" };
    case "tool": {
      // A page that takes speech says so: a search, say.
      const voice = toolPage(model, screen.id)?.voice;
      return voice ? { target: { kind: "tool", tool: screen.id, row: "", action: String(voice.action), name: String(voice.name ?? "this") } } : { refusal: "Nothing to say here" };
    }
    default: return { refusal: "Nothing to say here" };
  }
}

function startVoice(ui, model, via, now, fx, given) {
  if (model.link !== "ok") return flash(ui, "Not connected", now);
  const { target, refusal } = given ? { target: given } : voiceTarget(ui, model);
  if (!target) return flash(ui, refusal, now);
  fx.push({ fx: "listen" });
  const closed = topScreen(ui)?.menu ? withTop(ui, { menu: null }) : ui;
  return { ...closed, voice: { phase: "listening", target, via, text: "", error: "", at: now } };
}

function endVoice(ui, fx) {
  if (ui.voice && (ui.voice.phase === "listening" || ui.voice.phase === "waiting")) fx.push({ fx: "cancel" });
  return { ...ui, voice: null };
}

/// A few words said on the sidebar's Tools row. They move around; the two about prompts
/// only bring the one waiting prompt into view, where a tap still has to answer it.
function runSpoken(ui, model, heard, now) {
  const spoken = spokenCommand(heard);
  if (!spoken) return flash(ui, "Say it on an agent's row", now);
  switch (spoken.command) {
    case "allow":
    case "deny": {
      const waiting = pendingPrompts(model);
      if (waiting.length !== 1) return flash(ui, waiting.length ? "More than one is waiting" : "Nothing is waiting", now);
      const shown = reveal(ui, model, waiting[0].id);
      return push({ ...shown, stack: [], answered: shown.answered.filter((p) => p !== waiting[0].prompt) }, terminal(waiting[0].id));
    }
    case "next": {
      // The next one that needs you, or else the next row.
      const waiting = model.agents.filter(needsYou);
      if (!waiting.length) return { ...ui, sel: moved(rowsOf(ui, model), ui.sel, 1) };
      const at = waiting.findIndex((pane) => "p:" + pane.id === ui.sel);
      return reveal(ui, model, waiting[(at + 1) % waiting.length].id);
    }
    case "back":
      return ui.stack.length ? pop(ui) : ui;
    case "orchestrator": {
      const project = model.projects[0];
      if (!project) return flash(ui, "No orchestrator yet", now);
      return push({ ...ui, folded: ui.folded.filter((id) => id !== project.id), sel: "o:" + project.id, stack: [] }, orchestrator(project.id));
    }
    default: {
      const wanted = nameKey(spoken.name);
      const exact = model.agents.filter((agent) => nameKey(agent.name) === wanted);
      const starts = exact.length ? exact : model.agents.filter((agent) => nameKey(agent.name).startsWith(wanted));
      if (starts.length !== 1) return flash(ui, starts.length ? "More than one " + spoken.name : "Nothing called " + spoken.name, now);
      return push({ ...reveal(ui, model, starts[0].id), stack: [] }, terminal(starts[0].id));
    }
  }
}

function stepVoice(ui, model, event, now, out, fx) {
  const voice = ui.voice;
  switch (voice.phase) {
    case "listening":
      if ((event.type === "release" && voice.via === "hold") || (event.type === "click" && voice.via === "tap")) {
        fx.push({ fx: "stop" });
        return { ...ui, voice: { ...voice, phase: "waiting", at: now } };
      }
      if (event.type === "double") return flash(endVoice(ui, fx), "Cancelled", now);
      return ui;
    case "waiting":
      return event.type === "double" ? flash(endVoice(ui, fx), "Cancelled", now) : ui;
    case "heard": {
      if (event.type === "double") return flash({ ...ui, voice: null }, "Cancelled", now);
      if (event.type !== "click") return ui;
      if (model.link !== "ok") return flash(ui, "Not connected", now);
      const target = voice.target;
      if (target.kind === "orch") out.push({ t: "orchcmd", id: target.id, text: voice.text });
      else if (target.kind === "tool") out.push({ t: "toolact", tool: target.tool, row: target.row, action: target.action, text: voice.text });
      else out.push({ t: "say", id: target.id, text: voice.text });
      return flash({ ...ui, voice: null }, "Sending...", now);
    }
    default:
      return event.type === "click" || event.type === "double" ? { ...ui, voice: null } : ui;
  }
}

// MARK: A tab's terminal

function answer(ui, model, id, prompt, allow, now, out) {
  if (model.link !== "ok") return flash(ui, "Not connected", now);
  // The Mac has to still be reporting this very prompt.
  if (!promptPending(model, id, prompt)) return flash(ui, "That prompt is gone", now);
  out.push({ t: "answer", id, allow, prompt });
  return flash({ ...ui, answered: [...ui.answered, prompt] }, allow ? "Allowing..." : "Denying...", now);
}

/// One of a tab's actions, from its menu or the glasses' own.
function act(ui, model, pane, action, now, out, fx) {
  if (action === "ruler") return push(ui, { name: "ruler" });
  if (!pane || !isAgent(pane)) return flash(ui, "Choose an agent first", now);
  if (action === "talk") return startVoice(ui, model, "tap", now, fx, { kind: "agent", id: pane.id, name: pane.name });
  if (action === "output") return push(topScreen(ui)?.menu ? withTop(ui, { menu: null }) : ui, { name: "output", id: pane.id, back: 0 });
  if (action.startsWith("key:")) {
    const key = action.slice(4);
    if (!KEYS.includes(key)) return ui;
    if (model.link !== "ok") return flash(ui, "Not connected", now);
    // A prompt is answered as that prompt, with its identity, never with a bare key.
    if (pane.act === "permission") return flash(topScreen(ui)?.menu ? withTop(ui, { menu: null }) : ui, "Answer its prompt instead", now);
    out.push({ t: "key", id: pane.id, key });
    return ui;
  }
  return ui;
}

/// A swipe in a terminal: a page of what's there, then further back from the Mac.
function scroll(ui, model, screen, up) {
  const found = terminalLines(model, screen.id, screen.before, FULL_WIDTH);
  const lines = shownPrompt(ui, model) ? FULL_LINES - BOX_LINES : FULL_LINES;
  const { most, at } = visible(found.lines, screen.off, lines);
  const page = Math.max(1, lines - 1);
  const here = at === screen.off ? ui : withTop(ui, { off: at });
  if (up) {
    if (at < most) return withTop(ui, { off: Math.min(most, at + page) });
    if (!found.more || !found.raw || screen.before + found.raw > MAX_BEFORE) return here;
    return withTop(ui, { before: screen.before + found.raw, off: 0, trail: [...screen.trail, screen.before] });
  }
  if (at > 0) return withTop(ui, { off: Math.max(0, at - page) });
  if (!screen.trail.length) return here;
  // Down into the newer lines: from their top, where the older ones left off.
  return withTop(ui, { before: screen.trail[screen.trail.length - 1], off: Infinity, trail: screen.trail.slice(0, -1) });
}

function stepTerminal(ui, model, screen, event, now, out, fx) {
  const pane = agentById(model, screen.id);
  if (screen.menu) {
    const items = menuItems(pane);
    if (!items.length) return withTop(ui, { menu: null });
    const at = Math.max(0, items.findIndex((item) => item.id === screen.menu.sel));
    switch (event.type) {
      case "up": return withTop(ui, { menu: { sel: items[Math.max(0, at - 1)].id } });
      case "down": return withTop(ui, { menu: { sel: items[Math.min(items.length - 1, at + 1)].id } });
      case "double": return withTop(ui, { menu: null });
      case "long": return startVoice(ui, model, "hold", now, fx);
      case "click": return act(ui, model, pane, items[at].id, now, out, fx);
      default: return ui;
    }
  }
  const asking = shownPrompt(ui, model);
  if (asking && (event.type === "click" || event.type === "double")) {
    // Not before it has been on show a moment, and only the one that was.
    if (!ui.seen || ui.seen.key !== asking.id + "\n" + asking.prompt || now - ui.seen.at < PROMPT_GUARD) return ui;
    return answer(ui, model, asking.id, asking.prompt, event.type === "click", now, out);
  }
  switch (event.type) {
    // A swipe at a prompt puts it off, whether or not there's anything to read back.
    case "up": return scroll(asking ? withTop(ui, { later: asking.prompt }) : ui, model, asking ? { ...screen, later: asking.prompt } : screen, true);
    case "down": {
      const read = scroll(ui, model, screen, false);
      // At the end again: a prompt put off is back in view.
      const after = topScreen(read);
      return after.later && after.off === 0 && !after.before ? withTop(read, { later: null }) : read;
    }
    case "double": return pop(ui);
    case "long": return startVoice(ui, model, "hold", now, fx);
    case "click": {
      const items = menuItems(pane);
      return items.length ? withTop(ui, { menu: { sel: items[0].id } }) : ui;
    }
    default: return ui;
  }
}

// MARK: The orchestrator

const ORCH_MESSAGES = { stop: "orchstop", go: "orchgo", wire: "orchwire", clear: "orchclear" };

function stepOrchestrator(ui, model, screen, event, now, out, fx) {
  const project = model.projects.find((entry) => entry.id === screen.id);
  if (!project) return event.type === "double" ? pop(ui) : ui;
  if (screen.confirm) {
    // Only this tap sends it.
    if (event.type === "double") return withTop(ui, { confirm: null });
    if (event.type !== "click") return ui;
    if (model.link !== "ok") return flash(ui, "Not connected", now);
    const message = ORCH_MESSAGES[screen.confirm];
    if (message) out.push({ t: message, id: project.id });
    return flash(withTop(ui, { confirm: null, menu: null }), "Sending...", now);
  }
  if (screen.menu) {
    const at = Math.max(0, ORCH_ACTIONS.findIndex((item) => item.id === screen.menu.sel));
    switch (event.type) {
      case "up": return withTop(ui, { menu: { sel: ORCH_ACTIONS[Math.max(0, at - 1)].id } });
      case "down": return withTop(ui, { menu: { sel: ORCH_ACTIONS[Math.min(ORCH_ACTIONS.length - 1, at + 1)].id } });
      case "double": return withTop(ui, { menu: null });
      case "long": return startVoice(ui, model, "hold", now, fx);
      case "click": return withTop(ui, { confirm: ORCH_ACTIONS[at].id });
      default: return ui;
    }
  }
  const rows = orchestratorRows(model, project);
  const row = rows.find((entry) => entry.id === screen.sel) ?? rows.find((entry) => !entry.still);
  switch (event.type) {
    case "up": return withTop(ui, { sel: moved(rows, row.id, -1) });
    case "down": return withTop(ui, { sel: moved(rows, row.id, 1) });
    case "double": return pop(ui);
    case "long": return startVoice(ui, model, "hold", now, fx);
    case "click":
      if (row.id === "goal") return withTop(ui, { sel: row.id, menu: { sel: ORCH_ACTIONS[0].id } });
      if (row.id === "latest") return push(withTop(ui, { sel: row.id }), { name: "log", id: project.id, off: 0 });
      // An agent of the team, or the one asking: its own terminal, where a prompt is answered.
      if (row.id.startsWith("m:") || row.id.startsWith("ask:")) {
        const pane = row.id.slice(row.id.indexOf(":") + 1);
        return agentById(model, pane) ? push(withTop(ui, { sel: row.id }), terminal(pane)) : flash(ui, "That tab has closed", now);
      }
      return ui;
    default: return ui;
  }
}

function stepLog(ui, model, screen, event, now, fx) {
  const project = model.projects.find((entry) => entry.id === screen.id);
  const { most, at } = visible(project ? logLines(project) : [], screen.off, FULL_LINES);
  switch (event.type) {
    case "up": return withTop(ui, { off: Math.min(most, at + FULL_LINES - 1) });
    case "down": return withTop(ui, { off: Math.max(0, at - FULL_LINES + 1) });
    case "double": return pop(ui);
    case "long": return startVoice(ui, model, "hold", now, fx);
    default: return ui;
  }
}

// MARK: Tools

function stepTools(ui, model, screen, event, now, out) {
  const tools = toolList(model);
  if (!tools.length) return event.type === "double" ? pop(ui) : ui;
  const tool = tools.find((entry) => entry.id === screen.sel) ?? tools[0];
  if (screen.confirm) {
    if (event.type === "double") return withTop(ui, { confirm: false });
    if (event.type !== "click") return ui;
    if (model.link !== "ok") return flash(ui, "Not connected", now);
    // Opens the tool's window on the Mac, for when you sit down.
    out.push({ t: "tool", id: tool.id });
    return flash(withTop(ui, { confirm: false }), "Opening on your Mac...", now);
  }
  switch (event.type) {
    case "up": return withTop(ui, { sel: moved(tools, tool.id, -1) });
    case "down": return withTop(ui, { sel: moved(tools, tool.id, 1) });
    case "double": return pop(ui);
    case "click":
      if (tool.id === "ruler") return push(withTop(ui, { sel: tool.id }), { name: "ruler" });
      if (tool.page) return push(withTop(ui, { sel: tool.id }), { name: "tool", id: tool.id, sel: null, menu: null, confirm: null });
      return withTop(ui, { sel: tool.id, confirm: true });
    default: return ui;
  }
}

/// Where a row of a tool's page leads on the glasses: a tab, an orchestrator, a page.
function follow(ui, model, open, now) {
  const [kind, id] = [open.slice(0, open.indexOf(":")), open.slice(open.indexOf(":") + 1)];
  if (kind === "p") return agentById(model, id) ? push(ui, terminal(id)) : flash(ui, "That tab has closed", now);
  if (kind === "o") return model.projects.some((project) => project.id === id) ? push(ui, orchestrator(id)) : flash(ui, "No orchestrator there now", now);
  if (kind === "t" && toolList(model).some((tool) => tool.id === id && tool.page)) return push(ui, { name: "tool", id, sel: null, menu: null, confirm: null });
  return ui;
}

function stepTool(ui, model, screen, event, now, out, fx) {
  const rows = pageRows(toolPage(model, screen.id));
  const row = rows.find((entry) => entry.id === screen.sel) ?? rows[0];
  const actions = Array.isArray(row?.actions) ? row.actions.filter((action) => action && typeof action.id === "string") : [];
  if (screen.confirm) {
    if (event.type === "double") return withTop(ui, { confirm: null });
    if (event.type !== "click") return ui;
    if (model.link !== "ok") return flash(ui, "Not connected", now);
    // Only if the page still offers it, for the very row it was asked about.
    if (!row || row.id !== screen.sel || !actions.some((action) => action.id === screen.confirm)) return flash(withTop(ui, { confirm: null, menu: null }), "That's gone", now);
    out.push({ t: "toolact", tool: screen.id, row: row.id, action: screen.confirm });
    return flash(withTop(ui, { confirm: null, menu: null }), "Sending...", now);
  }
  if (screen.menu) {
    if (!actions.length) return withTop(ui, { menu: null });
    const at = Math.max(0, actions.findIndex((action) => action.id === screen.menu.sel));
    switch (event.type) {
      case "up": return withTop(ui, { menu: { sel: actions[Math.max(0, at - 1)].id } });
      case "down": return withTop(ui, { menu: { sel: actions[Math.min(actions.length - 1, at + 1)].id } });
      case "double": return withTop(ui, { menu: null });
      case "click": {
        const action = actions[at];
        // Said rather than tapped: what's heard is shown, and its own tap sends it.
        if (action.voice) return startVoice(ui, model, "tap", now, fx, { kind: "tool", tool: screen.id, row: row.id, action: action.id, name: String(action.name ?? row.text) });
        return withTop(ui, { confirm: action.id });
      }
      default: return ui;
    }
  }
  switch (event.type) {
    case "up": return row ? withTop(ui, { sel: moved(rows, row.id, -1) }) : ui;
    case "down": return row ? withTop(ui, { sel: moved(rows, row.id, 1) }) : ui;
    case "double": return pop(ui);
    case "long": return startVoice(ui, model, "hold", now, fx);
    case "click":
      if (!row) return ui;
      if (typeof row.open === "string") return follow(withTop(ui, { sel: row.id }), model, row.open, now);
      return actions.length ? withTop(ui, { sel: row.id, menu: { sel: actions[0].id } }) : ui;
    default: return ui;
  }
}

// MARK: Browsing

function stepBrowse(ui, model, event, now, fx) {
  const rows = rowsOf(ui, model);
  const row = currentRow(ui, model);
  switch (event.type) {
    case "up": return { ...ui, sel: moved(rows, ui.sel, -1) };
    case "down": return { ...ui, sel: moved(rows, ui.sel, 1) };
    case "double": fx.push({ fx: "exit" }); return ui;
    case "long": return startVoice({ ...ui, sel: row.id }, model, "hold", now, fx);
    case "click": {
      const chosen = { ...ui, sel: row.id };
      if (row.kind === "pane") return push(chosen, terminal(row.pane.id));
      if (row.kind === "orch") return push(chosen, orchestrator(row.project.id));
      if (row.kind === "tools") return push(chosen, { name: "tools", sel: null, confirm: false });
      // A project's header folds and unfolds it.
      return { ...chosen, folded: row.folded ? ui.folded.filter((id) => id !== row.group.id) : [...ui.folded, row.group.id] };
    }
    default: return ui;
  }
}

function stepPage(ui, model, screen, event) {
  if (screen.name === "output") {
    const last = outputPages(model, screen.id).length - 1;
    const back = Math.min(screen.back, last);
    if (event.type === "up") return withTop(ui, { back: Math.min(last, back + 1) });
    if (event.type === "down") return withTop(ui, { back: Math.max(0, back - 1) });
  }
  return event.type === "click" || event.type === "double" ? pop(ui) : ui;
}

/// Whether what a screen is about is still there.
function stands(screen, model) {
  switch (screen.name) {
    case "term":
    case "output": return agentById(model, screen.id) != null;
    case "orch":
    case "log": return model.projects.some((project) => project.id === screen.id);
    default: return true;
  }
}

/// Keeps the state true to what the Mac reports: a row that's gone hands the choice to
/// its neighbour, a screen about something that's gone closes, answered prompts are
/// forgotten once the Mac stops listing them, and a prompt coming into view starts its wait.
function settle(ui, model, now) {
  let next = ui;
  // Not before the Mac has said who's there: a choice kept from last time waits for that.
  if (model.link === "ok" && model.seen.agents && model.seen.orch) {
    const rows = rowsOf(next, model);
    const at = rows.findIndex((row) => row.id === next.sel);
    if (at < 0) {
      const row = rows[Math.min(Math.max(0, next.at), rows.length - 1)];
      next = { ...next, sel: row.id, at: rows.indexOf(row) };
    } else if (at !== next.at) {
      next = { ...next, at };
    }
    const gone = next.stack.findIndex((screen) => !stands(screen, model));
    if (gone >= 0) next = { ...next, stack: next.stack.slice(0, gone) };
    // On the orchestrator's screen, an agent that starts asking takes the cursor: a tap
    // there only opens its terminal.
    const top = topScreen(next);
    if (top?.name === "orch" && !top.menu && !top.confirm) {
      const project = model.projects.find((entry) => entry.id === top.id);
      const asking = orchestratorRows(model, project).filter((row) => row.id.startsWith("ask:")).map((row) => row.id);
      const known = top.asked ?? [];
      const fresh = asking.find((id) => !known.includes(id));
      if (fresh) next = withTop(next, { sel: fresh, asked: asking });
      else if (known.length !== asking.length) next = withTop(next, { asked: asking });
    }
  }
  // Speech doesn't outlive the connection it was going over.
  if (next.voice && model.link !== "ok") next = { ...next, voice: null };
  const identities = pendingPrompts(model).map((agent) => agent.prompt);
  const answered = next.answered.filter((p) => identities.includes(p));
  if (answered.length !== next.answered.length) next = { ...next, answered };
  // The prompt in view, from inside its terminal and with nothing else taking the taps.
  const asking = !next.voice && model.link === "ok" ? shownPrompt(next, model) : null;
  const key = asking ? asking.id + "\n" + asking.prompt : null;
  if (key && topScreen(next).menu) next = withTop(next, { menu: null });
  if (key !== (next.seen?.key ?? null)) next = { ...next, seen: key ? { key, at: now } : null };
  if (next.flash && now >= next.flash.until) next = { ...next, flash: null };
  return next;
}

/// One step. `event` is from the glasses (see `normalizeEvent`), or one of ours:
/// { type: "model" } after the Mac said something, { type: "tick" } as time passes,
/// { type: "heard", text, final, error }, { type: "reply", ok, message }.
/// Returns the next state, messages for the Mac (`out`) and things for the glasses to
/// do (`fx`: "listen", "stop", "cancel", "exit").
export function step(ui, model, event, now) {
  const out = [];
  const fx = [];
  let next = ui;
  const screen = topScreen(ui);
  switch (event.type) {
    case "model":
      break;
    case "tick":
      if (ui.voice?.phase === "listening" && now - ui.voice.at > LISTEN_LIMIT) {
        fx.push({ fx: "stop" });
        next = { ...ui, voice: { ...ui.voice, phase: "waiting", at: now } };
      } else if (ui.voice?.phase === "waiting" && now - ui.voice.at > HEARD_PATIENCE) {
        fx.push({ fx: "cancel" });
        next = { ...ui, voice: { ...ui.voice, phase: "error", error: "Your Mac didn't answer." } };
      }
      break;
    case "heard":
      if (!ui.voice || ui.voice.phase === "heard" || ui.voice.phase === "error") break;
      if (event.error) {
        next = { ...ui, voice: { ...ui.voice, phase: "error", error: String(event.error) } };
      } else if (!event.final) {
        next = { ...ui, voice: { ...ui.voice, text: String(event.text ?? "") } };
      } else if (ui.voice.target.kind === "home") {
        next = runSpoken({ ...ui, voice: null }, model, event.text, now);
      } else {
        next = { ...ui, voice: { ...ui.voice, phase: "heard", text: String(event.text ?? "") } };
      }
      break;
    case "reply":
      next = flash(ui, String(event.message || (event.ok ? "Done" : "Not done")), now);
      break;
    case "background":
    case "abnormal":
      next = endVoice(ui, fx);
      break;
    case "foreground":
      break;
    case "menu": {
      // The glasses' own menu, for the tab you're in or on. Not while something else has the taps.
      const item = OS_MENU.find((entry) => entry.id === event.id);
      if (model.link !== "ok" || !item || ui.voice) break;
      if (screen && screen.name !== "term") { if (item.action === "ruler" && screen.name !== "ruler") next = push(ui, { name: "ruler" }); break; }
      const row = screen ? null : currentRow(ui, model);
      const pane = screen ? agentById(model, screen.id) : row.kind === "pane" ? row.pane : null;
      next = act(ui, model, pane, item.action, now, out, fx);
      break;
    }
    default:
      if (model.link !== "ok") break;
      if (ui.voice) next = stepVoice(ui, model, event, now, out, fx);
      else if (!screen) next = stepBrowse(ui, model, event, now, fx);
      else if (screen.name === "term") next = stepTerminal(ui, model, screen, event, now, out, fx);
      else if (screen.name === "orch") next = stepOrchestrator(ui, model, screen, event, now, out, fx);
      else if (screen.name === "log") next = stepLog(ui, model, screen, event, now, fx);
      else if (screen.name === "tools") next = stepTools(ui, model, screen, event, now, out);
      else if (screen.name === "tool") next = stepTool(ui, model, screen, event, now, out, fx);
      else next = stepPage(ui, model, screen, event);
  }
  return { ui: settle(next, model, now), out, fx };
}

/// What the Mac should keep sending for this state. The link sends these again after a
/// reconnect, and tells the Mac when one stops.
export function subscriptions(ui) {
  const wanted = [{ t: "glance" }, { t: "orch" }, { t: "tools" }];
  const screen = topScreen(ui);
  if (screen?.name === "output") wanted.push({ t: "tail", id: screen.id, lines: TAIL_LINES });
  else if (screen?.name === "term") wanted.push({ t: "tail", id: screen.id, lines: SCREEN_LINES, src: "screen", before: screen.before });
  else if (!screen && typeof ui.sel === "string" && ui.sel.startsWith("p:")) wanted.push({ t: "tail", id: ui.sel.slice(2), lines: SCREEN_LINES, src: "screen", before: 0 });
  if (screen?.name === "tool") wanted.push({ t: "toolpage", id: screen.id });
  return wanted;
}
