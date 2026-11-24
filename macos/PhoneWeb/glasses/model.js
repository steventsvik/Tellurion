// What the glasses know about the Mac: built only from the server's messages and the
// connection's state. Every function here returns a new value and touches nothing else.

export function createModel() {
  return {
    /// "boot", "connecting", "pairing", "unpaired", "ok", "lost", "off" or "nomac".
    link: "boot",
    /// When the connection was lost, and a line about why it isn't paired.
    lostAt: 0,
    linkNote: "",
    pairCode: "",
    mac: "",
    agents: [],
    needs: 0,
    /// The Mac's clock minus this one's, in seconds, as of the last agents message.
    skew: 0,
    projects: [],
    /// The last text the Mac sent for a pane: { id, text, gone, src, before, more }.
    tail: null,
    /// Each pane's screen as last seen, by id, so going back to a tab isn't blank meanwhile.
    screens: {},
    /// The Tools row's numbers: usage, servers, review, checks, budgets, conflicts.
    tools: null,
    /// The page of the tool that's open: { id, title, note, voice, rows }.
    toolpage: null,
    /// Whether the Mac has listed its agents and its orchestrators yet.
    seen: { agents: false, orch: false },
  };
}

/// The connection changed.
export function withLink(model, state, now, extra = {}) {
  const next = { ...model, link: state, linkNote: extra.note ?? "", pairCode: extra.code ?? "" };
  if (extra.mac) next.mac = extra.mac;
  if (state === "lost" || state === "nomac") next.lostAt = model.link === state ? model.lostAt : now;
  return next;
}

/// A message from the server.
export function withMessage(model, message, now) {
  switch (message?.t) {
    case "agents": {
      const agents = Array.isArray(message.agents) ? message.agents.filter((a) => a && typeof a.id === "string") : [];
      const skew = typeof message.now === "number" ? message.now - now / 1000 : model.skew;
      return { ...model, agents, needs: Number(message.needs) || 0, skew, seen: { ...model.seen, agents: true } };
    }
    case "orch":
      return {
        ...model,
        projects: Array.isArray(message.projects) ? message.projects.filter((p) => p && typeof p.id === "string") : [],
        seen: { ...model.seen, orch: true },
      };
    case "tail": {
      const tail = {
        id: message.id, text: String(message.text ?? ""), gone: message.gone === true,
        src: message.src === "screen" ? "screen" : "answer", before: Number(message.before) || 0, more: message.more === true,
        // The agent's own last words, for when its screen is mostly furniture.
        ans: typeof message.ans === "string" ? message.ans : "",
      };
      if (tail.src !== "screen" || tail.before !== 0 || tail.gone) return { ...model, tail };
      // The newest few panes' screens are kept.
      const screens = { ...model.screens };
      delete screens[tail.id];
      screens[tail.id] = tail;
      const ids = Object.keys(screens);
      for (const old of ids.slice(0, Math.max(0, ids.length - KEPT_SCREENS))) delete screens[old];
      return { ...model, tail, screens };
    }
    case "tools":
      return { ...model, tools: message };
    case "toolpage":
      return typeof message.id === "string" ? { ...model, toolpage: message } : model;
    default:
      return model;
  }
}

const KEPT_SCREENS = 12;

/// Whether a pane has an agent in it. A Mac that doesn't say only lists agents.
export function isAgent(pane) {
  return pane.agent !== false;
}

export function needsYou(pane) {
  return isAgent(pane) && (pane.act === "permission" || pane.act === "input");
}

/// The agent's kind as the Mac's sidebar names it.
export function kindName(pane) {
  if (!isAgent(pane)) return "terminal";
  return pane.agentName || { claude: "Claude Code", codex: "Codex", hermes: "Hermes" }[pane.kind] || pane.kind || "agent";
}

export const OTHER = "other";

/// The panes by project, as the Mac's sidebar brackets them: projects in the order their
/// first pane comes, each with its orchestrator if the Mac lists one; a project that only
/// has an orchestrator after those; panes with no project folder yet last, under "Other".
export function groups(model) {
  const found = new Map();
  const loose = [];
  for (const pane of model.agents) {
    const project = pane.proj && typeof pane.proj.id === "string" && pane.proj.id ? pane.proj : null;
    if (!project) { loose.push(pane); continue; }
    if (!found.has(project.id)) found.set(project.id, { id: project.id, name: String(project.name ?? ""), path: String(project.path ?? ""), panes: [], orch: null });
    found.get(project.id).panes.push(pane);
  }
  for (const project of model.projects) {
    if (!found.has(project.id)) found.set(project.id, { id: project.id, name: String(project.name ?? ""), path: "", panes: [], orch: null });
    found.get(project.id).orch = project;
  }
  const list = [...found.values()];
  if (loose.length) list.push({ id: OTHER, name: "Other", path: "", panes: loose, orch: null });
  return list;
}

/// The sidebar's rows, top to bottom: each project's header, then (unless it's folded)
/// its orchestrator and its panes, and Tools last. `folded`: project ids.
export function sidebarRows(model, folded = []) {
  const rows = [];
  for (const group of groups(model)) {
    const isFolded = folded.includes(group.id);
    rows.push({ id: "g:" + group.id, kind: "group", group, folded: isFolded });
    if (isFolded) continue;
    if (group.orch) rows.push({ id: "o:" + group.id, kind: "orch", group, project: group.orch });
    for (const pane of group.panes) rows.push({ id: "p:" + pane.id, kind: "pane", group, pane });
  }
  rows.push({ id: "tools", kind: "tools" });
  return rows;
}

export function agentById(model, id) {
  return model.agents.find((agent) => agent.id === id) ?? null;
}

/// The permission prompts waiting, in the order the server lists them.
export function pendingPrompts(model) {
  return model.agents.filter((agent) => isAgent(agent) && agent.act === "permission" && typeof agent.prompt === "string" && agent.prompt);
}

/// Whether this very prompt is still the one the agent shows.
export function promptPending(model, id, prompt) {
  return pendingPrompts(model).some((agent) => agent.id === id && agent.prompt === prompt);
}

const WORDS = {
  permission: "needs permission", input: "needs input", failed: "failed", done: "done", working: "working", ready: "ready",
};

export function stateWords(agent) {
  if (!isAgent(agent)) return "terminal";
  return WORDS[agent.act] ?? "ready";
}

/// "45s" is noise at a glance: nothing under a minute, then "3m", "2h", "4d".
export function age(seconds) {
  if (!(seconds >= 60)) return "";
  if (seconds < 3600) return Math.floor(seconds / 60) + "m";
  if (seconds < 86400) return Math.floor(seconds / 3600) + "h";
  return Math.floor(seconds / 86400) + "d";
}

export function agentAge(model, agent, now) {
  return typeof agent.since === "number" ? age(now / 1000 + model.skew - agent.since) : "";
}

/// "2 need you · 3 working", or what else there is to say.
export function summary(model) {
  const working = model.agents.filter((agent) => isAgent(agent) && agent.act === "working").length;
  const parts = [];
  if (model.needs > 0) parts.push(model.needs === 1 ? "1 needs you" : model.needs + " need you");
  if (working > 0) parts.push(working + " working");
  if (parts.length) return parts.join(" · ");
  return model.agents.some(isAgent) ? "All quiet" : "No agents running";
}

/// The marks worth a word on an agent's line: a failed check, a budget, conflicts.
export function marks(agent) {
  const found = [];
  if (agent.check?.s === "failed") found.push("check failed");
  else if (agent.check?.s === "running") found.push("checking");
  if (agent.budget?.s === "paused") found.push("budget reached");
  else if (agent.budget?.s === "warning" || agent.budget?.s === "reached") found.push("budget " + Math.round((agent.budget.f || 0) * 100) + "%");
  if (agent.conflicts > 0) found.push(agent.conflicts === 1 ? "1 conflict" : agent.conflicts + " conflicts");
  return found;
}
