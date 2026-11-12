// What a tap, a swipe or a spoken word does: the screen you're on plus an event gives the
// next screen and, sometimes, a message for the Mac. Nothing here touches the glasses or
// the network, and no state is ever changed in place.
//
// The rules that matter:
// - Nothing is sent without a tap. Speech becomes text on the Mac and comes back here; it
//   goes to an agent or the orchestrator only after "tap = send".
// - A permission answer carries the identity of the prompt that was on screen, and isn't
//   sent at all if the Mac has since reported another one.
// - A prompt that pops up ignores taps for a moment, so a tap already on its way to the
//   screen underneath can't allow it.
// - Double-tap on Home closes the app the way the glasses' own menu expects.

import { agentById, pendingPrompts, promptPending } from "./model.js";
import { actionItems, agentPages, homeItems, orchestratorPages, outputPages } from "./screens.js";

/// How long a prompt that just appeared ignores taps.
export const PROMPT_GUARD = 1200;
export const FLASH = 3000;
export const TAIL_LINES = 30;
/// A minute of listening at most, and this long for the Mac to answer after it.
export const LISTEN_LIMIT = 60_000;
export const HEARD_PATIENCE = 10_000;

export function createUI() {
  return {
    /// Home at the bottom; the top one is what's shown.
    stack: [{ name: "home" }],
    /// The chosen row on Home, by id, so it stays put when the rows change.
    sel: null,
    /// The permission prompt shown over everything: { id, prompt, at }.
    prompt: null,
    /// Prompts put off with a swipe, and ones answered, by identity.
    later: [],
    answered: [],
    /// { phase: "listening" | "waiting" | "heard" | "error", target, via, text, error, at }.
    voice: null,
    flash: null,
  };
}

// MARK: Events from the glasses

/// What an event from the Even app means: { type, index } with type "click", "double",
/// "up", "down", "long", "release", "foreground", "background" or "abnormal"; { type:
/// "audio", pcm }; or null for anything else. A click's type can arrive as 0 or missing.
export function normalizeEvent(event) {
  if (!event || typeof event !== "object") return null;
  if (event.audioEvent?.audioPcm) return { type: "audio", pcm: event.audioEvent.audioPcm };
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

/// Drops repeats: a swipe reported twice in a row, or one tap delivered on two channels.
export function createDebouncer(scrollGap = 300, tapGap = 150) {
  let last = { type: "", at: -Infinity };
  return (event, now) => {
    const gap = event.type === "up" || event.type === "down" ? scrollGap : event.type === "click" || event.type === "double" ? tapGap : 0;
    if (gap && event.type === last.type && now - last.at < gap) return false;
    if (gap) last = { type: event.type, at: now };
    return true;
  };
}

// MARK: Speech on Home

/// What a few spoken words mean on Home, matched whole and nothing looser: "allow",
/// "deny", "next", "back", "orchestrator", "open <name>". Anything else is null.
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

// MARK: Steps

const top = (ui) => ui.stack[ui.stack.length - 1];
const withTop = (ui, changes) => ({ ...ui, stack: [...ui.stack.slice(0, -1), { ...top(ui), ...changes }] });
const push = (ui, screen) => ({ ...ui, stack: [...ui.stack, screen] });
const pop = (ui) => (ui.stack.length > 1 ? { ...ui, stack: ui.stack.slice(0, -1) } : ui);
const flash = (ui, text, now) => ({ ...ui, flash: { text, until: now + FLASH } });

/// Moves through rows by id; from nothing chosen, the first counts as chosen.
function moved(rows, selected, by) {
  if (!rows.length) return null;
  const at = Math.max(0, rows.findIndex((row) => row.id === selected));
  return rows[Math.min(rows.length - 1, Math.max(0, at + by))].id;
}

function chosen(rows, selected, index) {
  if (typeof index === "number" && rows[index]) return rows[index];
  return rows.find((row) => row.id === selected) ?? rows[0] ?? null;
}

function open(ui, id) {
  if (id.startsWith("a:")) return push(ui, { name: "agent", id: id.slice(2), page: 0 });
  if (id.startsWith("o:")) return push(ui, { name: "orch", id: id.slice(2), page: 0 });
  return ui;
}

/// Who speech on this screen is for.
function voiceTarget(ui, model) {
  const screen = top(ui);
  if (screen.name === "orch") {
    const project = model.projects.find((p) => p.id === screen.id);
    return project ? { kind: "orch", id: project.id, name: "the orchestrator" } : null;
  }
  if (screen.name === "home") return { kind: "home", id: "", name: "Tellurion" };
  const agent = agentById(model, screen.id);
  return agent ? { kind: "agent", id: agent.id, name: agent.name } : null;
}

function startVoice(ui, model, via, now, fx) {
  if (model.link !== "ok") return flash(ui, "Not connected", now);
  const target = voiceTarget(ui, model);
  if (!target) return ui;
  fx.push({ fx: "listen" });
  return { ...ui, voice: { phase: "listening", target, via, text: "", error: "", at: now } };
}

function endVoice(ui, fx) {
  if (ui.voice && (ui.voice.phase === "listening" || ui.voice.phase === "waiting")) fx.push({ fx: "cancel" });
  return { ...ui, voice: null };
}

/// A few words said on Home. They move around; the two about prompts only bring the one
/// waiting prompt up, where a tap still has to answer it.
function runSpoken(ui, model, heard, now) {
  const spoken = spokenCommand(heard);
  if (!spoken) return flash(ui, "Say it on an agent's screen", now);
  switch (spoken.command) {
    case "allow":
    case "deny": {
      const waiting = pendingPrompts(model);
      if (waiting.length !== 1) return flash(ui, waiting.length ? "More than one is waiting" : "Nothing is waiting", now);
      return { ...ui, later: ui.later.filter((p) => p !== waiting[0].prompt), answered: ui.answered.filter((p) => p !== waiting[0].prompt), prompt: { id: waiting[0].id, prompt: waiting[0].prompt, at: now } };
    }
    case "next":
      return { ...ui, sel: moved(homeItems(model, now), ui.sel, 1) };
    case "back":
      return pop(ui);
    case "orchestrator":
      return model.projects.length ? open(ui, "o:" + model.projects[0].id) : flash(ui, "No orchestrator yet", now);
    default: {
      const wanted = nameKey(spoken.name);
      const exact = model.agents.filter((agent) => nameKey(agent.name) === wanted);
      const starts = exact.length ? exact : model.agents.filter((agent) => nameKey(agent.name).startsWith(wanted));
      if (starts.length !== 1) return flash(ui, starts.length ? "More than one " + spoken.name : "No agent called " + spoken.name, now);
      return open({ ...ui, stack: [ui.stack[0]] }, "a:" + starts[0].id);
    }
  }
}

function answer(ui, model, id, prompt, allow, now, out) {
  if (model.link !== "ok") return flash(ui, "Not connected", now);
  // The Mac has to still be reporting this very prompt.
  if (!promptPending(model, id, prompt)) return flash(ui, "That prompt is gone", now);
  out.push({ t: "answer", id, allow, prompt });
  return flash({ ...ui, answered: [...ui.answered, prompt] }, allow ? "Allowing..." : "Denying...", now);
}

function stepPrompt(ui, model, event, now, out) {
  const { id, prompt, at } = ui.prompt;
  switch (event.type) {
    case "click":
      if (now - at < PROMPT_GUARD) return ui;
      return { ...answer(ui, model, id, prompt, true, now, out), prompt: null };
    case "double":
      if (now - at < PROMPT_GUARD) return ui;
      return { ...answer(ui, model, id, prompt, false, now, out), prompt: null };
    case "up":
    case "down":
      return { ...ui, prompt: null, later: [...ui.later, prompt] };
    default:
      return ui;
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
    case "heard":
      if (event.type === "double") return flash({ ...ui, voice: null }, "Cancelled", now);
      if (event.type !== "click") return ui;
      if (model.link !== "ok") return flash(ui, "Not connected", now);
      out.push(voice.target.kind === "orch"
        ? { t: "orchcmd", id: voice.target.id, text: voice.text }
        : { t: "say", id: voice.target.id, text: voice.text });
      return flash({ ...ui, voice: null }, "Sending...", now);
    default:
      return event.type === "click" || event.type === "double" ? { ...ui, voice: null } : ui;
  }
}

function stepScreen(ui, model, event, now, out, fx) {
  const screen = top(ui);
  const agent = screen.id ? agentById(model, screen.id) : null;
  if (event.type === "long") return startVoice(ui, model, "hold", now, fx);
  switch (screen.name) {
    case "home": {
      const rows = homeItems(model, now);
      if (event.type === "up") return { ...ui, sel: moved(rows, ui.sel, -1) };
      if (event.type === "down") return { ...ui, sel: moved(rows, ui.sel, 1) };
      if (event.type === "double") { fx.push({ fx: "exit" }); return ui; }
      if (event.type === "click") {
        const row = chosen(rows, ui.sel, event.index);
        return row ? open({ ...ui, sel: row.id }, row.id) : ui;
      }
      return ui;
    }
    case "agent": {
      if (!agent) return pop(ui);
      const last = agentPages(model, agent).length - 1;
      if (event.type === "up") return withTop(ui, { page: Math.max(0, Math.min(screen.page, last) - 1) });
      if (event.type === "down") return withTop(ui, { page: Math.min(last, screen.page + 1) });
      if (event.type === "double") return pop(ui);
      if (event.type === "click") return push(ui, { name: "actions", id: agent.id, sel: actionItems(agent)[0].id, prompt: agent.prompt ?? null });
      return ui;
    }
    case "actions": {
      if (!agent) return pop(ui);
      const rows = actionItems(agent);
      if (event.type === "up") return withTop(ui, { sel: moved(rows, screen.sel, -1) });
      if (event.type === "down") return withTop(ui, { sel: moved(rows, screen.sel, 1) });
      if (event.type === "double") return pop(ui);
      if (event.type !== "click") return ui;
      const row = chosen(rows, screen.sel, event.index);
      switch (row?.id) {
        case "allow":
        case "deny":
          // Only the prompt this menu was opened for.
          if (!screen.prompt || agent.prompt !== screen.prompt) return flash(pop(ui), "That prompt is gone", now);
          return answer(pop(ui), model, agent.id, screen.prompt, row.id === "allow", now, out);
        case "talk": return startVoice(pop(ui), model, "tap", now, fx);
        case "output": return push(pop(ui), { name: "output", id: agent.id, back: 0 });
        default: return pop(ui);
      }
    }
    case "output": {
      if (!agent) return pop(ui);
      const last = outputPages(model, agent.id).length - 1;
      if (event.type === "up") return withTop(ui, { back: Math.min(last, screen.back + 1) });
      if (event.type === "down") return withTop(ui, { back: Math.max(0, Math.min(screen.back, last) - 1) });
      if (event.type === "double" || event.type === "click") return pop(ui);
      return ui;
    }
    case "orch": {
      const project = model.projects.find((p) => p.id === screen.id);
      if (!project) return pop(ui);
      const last = orchestratorPages(project).length - 1;
      if (event.type === "up") return withTop(ui, { page: Math.max(0, Math.min(screen.page, last) - 1) });
      if (event.type === "down") return withTop(ui, { page: Math.min(last, screen.page + 1) });
      if (event.type === "double") return pop(ui);
      if (event.type === "click") return startVoice(ui, model, "tap", now, fx);
      return ui;
    }
    default:
      return { ...ui, stack: [{ name: "home" }] };
  }
}

/// Keeps the state true to what the Mac reports: screens of agents that are gone close,
/// prompts that were answered elsewhere go away, and a new one comes up over what's there
/// (never over speech in progress, where a tap means something else).
function settle(ui, model, now) {
  let next = ui;
  while (next.stack.length > 1) {
    const screen = top(next);
    // Not before the Mac has said who's there: a screen kept from last time waits for that.
    const there = screen.name === "orch"
      ? !model.seen.orch || model.projects.some((p) => p.id === screen.id)
      : !model.seen.agents || agentById(model, screen.id) != null;
    if (there || model.link !== "ok") break;
    next = pop(next);
  }
  // Speech doesn't outlive the connection it was going over.
  if (next.voice && model.link !== "ok") next = { ...next, voice: null };
  const waiting = pendingPrompts(model);
  const identities = waiting.map((agent) => agent.prompt);
  const later = next.later.filter((p) => identities.includes(p));
  const answered = next.answered.filter((p) => identities.includes(p));
  if (later.length !== next.later.length || answered.length !== next.answered.length) next = { ...next, later, answered };
  if (next.prompt && !identities.includes(next.prompt.prompt)) next = { ...next, prompt: null };
  if (!next.prompt && !next.voice && model.link === "ok") {
    const fresh = waiting.find((agent) => !later.includes(agent.prompt) && !answered.includes(agent.prompt));
    if (fresh) next = { ...next, prompt: { id: fresh.id, prompt: fresh.prompt, at: now } };
  }
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
    default:
      if (model.link !== "ok") break;
      if (ui.voice) next = stepVoice(ui, model, event, now, out, fx);
      else if (ui.prompt) next = stepPrompt(ui, model, event, now, out);
      else next = stepScreen(ui, model, event, now, out, fx);
  }
  return { ui: settle(next, model, now), out, fx };
}

/// What the Mac should keep sending for this screen. The link sends these again after a
/// reconnect, and tells the Mac when one stops.
export function subscriptions(ui) {
  const wanted = [{ t: "glance" }, { t: "orch" }];
  const screen = top(ui);
  if (screen.name === "agent" || screen.name === "actions" || screen.name === "output") {
    wanted.push({ t: "tail", id: screen.id, lines: TAIL_LINES });
  }
  return wanted;
}
